import AppKit
import ApplicationServices

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
