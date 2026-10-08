import AppKit
import ApplicationServices
import SQLite3

/// Reads Warp's accessibility tree to figure out which tab the user is looking
/// at. Warp exposes its focused window's title, which is the cwd folder name
/// (e.g. "Apps") — we match that to a detected claude session's cwd basename so
/// the composer can auto-select the session for the tab you're viewing.
///
/// Read-only and best-effort: if Warp isn't running, exposes nothing, or shows
/// a non-cwd title, this returns nil and the caller falls back to its heuristic.
enum WarpInspector {
    private static let warpBundleIDs = [
        "dev.warp.Warp-Stable", "dev.warp.Warp", "dev.warp.Warp-Preview",
    ]

    /// Whether this process is trusted for the Accessibility API (required to
    /// read another app's AX tree).
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The title of Warp's focused window — its cwd folder name — or nil.
    static func focusedWindowTitle() -> String? {
        guard let warp = warpBundleIDs
            .compactMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).first })
            .first else { return nil }

        let app = AXUIElementCreateApplication(warp.processIdentifier)
        guard let window = element(app, kAXFocusedWindowAttribute),
              let title = string(window, kAXTitleAttribute)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }
        return title
    }

    /// The active tab of Warp's front window, read from Warp's own session
    /// database: the user's custom tab name (what the vertical tab list shows)
    /// and the focused pane's cwd. The window title can't give us either —
    /// claude overwrites it with its spinner + conversation summary.
    struct ActiveTab {
        let name: String?
        let cwd: String?
    }

    private static let sessionDB = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite")

    /// Best-effort: Warp's schema is private, so any failure returns nil and the
    /// caller falls back to the window title.
    static func activeTab() -> ActiveTab? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(sessionDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 50)

        // Front window: the one whose saved frame matches the AX focused window,
        // else the first. Tabs are stored in display order by id.
        let windows = rows(db, "SELECT id, active_tab_index, origin_x, origin_y, window_width, window_height FROM windows")
        guard !windows.isEmpty else { return nil }
        let front = focusedWindowFrame()
        let window = windows.min(by: { frameDistance($0, front) < frameDistance($1, front) })!
        guard let windowID = Int(window[0] ?? ""), let index = Int(window[1] ?? "") else { return nil }

        guard let tab = rows(db, "SELECT id, custom_title FROM tabs WHERE window_id = \(windowID) ORDER BY id LIMIT 1 OFFSET \(index)").first,
              let tabID = Int(tab[0] ?? "") else { return nil }
        let pane = rows(db, """
            SELECT pl.custom_vertical_tabs_title, tp.cwd FROM pane_nodes pn
            JOIN pane_leaves pl ON pl.pane_node_id = pn.id
            LEFT JOIN terminal_panes tp ON tp.id = pn.id
            WHERE pn.tab_id = \(tabID) AND pn.is_leaf
            ORDER BY pl.is_focused DESC LIMIT 1
            """).first

        let name = [pane?[0], tab[1]].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return ActiveTab(name: name, cwd: pane?[1])
    }

    private static func rows(_ db: OpaquePointer?, _ sql: String) -> [[String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [[String?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((0..<sqlite3_column_count(stmt)).map { i in
                sqlite3_column_text(stmt, i).map { String(cString: $0) }
            })
        }
        return out
    }

    private static func focusedWindowFrame() -> CGRect? {
        guard let warp = warpBundleIDs
            .compactMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).first })
            .first else { return nil }
        let app = AXUIElementCreateApplication(warp.processIdentifier)
        guard let window = element(app, kAXFocusedWindowAttribute),
              let posVal = value(window, kAXPositionAttribute),
              let sizeVal = value(window, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    /// How far a saved window row's size is from the focused window's (origins
    /// use different coordinate systems, so size is the reliable signal).
    private static func frameDistance(_ row: [String?], _ frame: CGRect?) -> Double {
        guard let frame, let w = Double(row[4] ?? ""), let h = Double(row[5] ?? "") else { return 0 }
        return abs(w - frame.width) + abs(h - frame.height)
    }

    // MARK: - AX helpers

    private static func value(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
    }
    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        value(el, attr) as? String
    }
    private static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = value(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
}
