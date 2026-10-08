import Darwin
import Foundation

struct ClaudeSession: Equatable {
    let pid: pid_t
    let ttyPath: String
    let cwd: String?
    let startTime: TimeInterval

    /// Short human-readable label for the UI — uses the cwd basename if known,
    /// otherwise falls back to the tty name.
    var shortLabel: String {
        let tty = (ttyPath as NSString).lastPathComponent
        if let cwd, !cwd.isEmpty {
            let folder = (cwd as NSString).lastPathComponent
            return "\(folder) · \(tty)"
        }
        return tty
    }
}

final class ProcessWatcher {
    private(set) var sessions: [ClaudeSession] = []
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "typeflow.processwatcher")
    var onChange: (([ClaudeSession]) -> Void)?

    /// Manual override: when set and still alive, this pid wins over the
    /// most-recently-started heuristic. Cleared automatically when the
    /// selected session disappears, or when a newer session is started (the
    /// `claude` you just launched supersedes a stale pick).
    var preferredPID: pid_t?

    /// Set TYPEFLOW_DEBUG=1 in the environment to see watcher diagnostics on stderr.
    private static let debug: Bool = ProcessInfo.processInfo.environment["TYPEFLOW_DEBUG"] == "1"

    /// Poll cadence: slow while the composer is closed (the common idle state),
    /// faster only while it's open — so a newly-started session shows up
    /// promptly in the picker without paying the scan cost continuously.
    private let idleInterval: TimeInterval = 3.0
    private let activeInterval: TimeInterval = 1.0
    private var currentInterval: TimeInterval = 0

    func start() {
        reschedule(idleInterval)
    }

    /// Fast cadence + an immediate refresh — call when the composer opens.
    func boost() { reschedule(activeInterval) }
    /// Back to the slow idle cadence — call when the composer closes.
    func relax() { reschedule(idleInterval) }

    private func reschedule(_ interval: TimeInterval) {
        guard interval != currentInterval else { return }
        currentInterval = interval
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval) // deadline .now() = refresh immediately
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Routing precedence:
    ///   1. The user's explicit pick (preferredPID), if still alive.
    ///   2. The most recently started session.
    func target() -> ClaudeSession? {
        if let pid = preferredPID, let s = sessions.first(where: { $0.pid == pid }) {
            return s
        }
        return sessions.max(by: { $0.startTime < $1.startTime })
    }

    private func refresh() {
        let current = Self.findClaudeProcesses()
        if current != sessions {
            let previousPIDs = Set(sessions.map { $0.pid })
            sessions = current
            // A freshly-started session supersedes a stale manual pick, so the
            // default target follows the `claude` the user just launched.
            if current.contains(where: { !previousPIDs.contains($0.pid) }) {
                preferredPID = nil
            }
            // Drop a stale manual pick if the underlying session is gone.
            if let pid = preferredPID, !current.contains(where: { $0.pid == pid }) {
                preferredPID = nil
            }
            if Self.debug {
                fputs("TypeFlow: detected \(current.count) claude session(s): \(current)\n", stderr)
            }
            let snapshot = current
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(snapshot)
            }
        }
    }

    // MARK: - libproc lookup

    private static func findClaudeProcesses() -> [ClaudeSession] {
        // First call with nil buffer to find required size.
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else {
            if debug { fputs("TypeFlow: proc_listpids returned \(needed)\n", stderr) }
            return []
        }

        let capacity = Int(needed) / MemoryLayout<pid_t>.size + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0,
                          buf.baseAddress, Int32(capacity * MemoryLayout<pid_t>.size))
        }
        guard bytes > 0 else {
            if debug { fputs("TypeFlow: proc_listpids (fill) returned \(bytes)\n", stderr) }
            return []
        }
        let count = Int(bytes) / MemoryLayout<pid_t>.size

        var found: [ClaudeSession] = []
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            guard let path = executablePath(pid: pid) else { continue }
            guard isClaudeBinary(path: path) else { continue }
            guard let bsd = bsdInfo(pid: pid) else {
                if debug { fputs("TypeFlow: pid \(pid) (\(path)) — no bsdinfo\n", stderr) }
                continue
            }
            guard let tty = ttyPath(from: bsd) else {
                if debug {
                    fputs("TypeFlow: pid \(pid) (\(path)) — no tty (e_tdev=\(bsd.e_tdev))\n", stderr)
                }
                continue
            }
            let start = TimeInterval(bsd.pbi_start_tvsec)
                      + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000
            let cwd = workingDirectory(pid: pid)
            found.append(ClaudeSession(pid: pid, ttyPath: tty, cwd: cwd, startTime: start))
        }
        return found
    }

    private static func executablePath(pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// Recognize the Claude Code CLI across installer variants:
    ///   - Native installer: ~/.local/share/claude/versions/X.Y.Z
    ///   - npm / homebrew / direct: a binary literally named "claude"
    private static func isClaudeBinary(path: String) -> Bool {
        if path.contains("/share/claude/versions/") { return true }
        return (path as NSString).lastPathComponent == "claude"
    }

    private static func bsdInfo(pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard n == size else { return nil }
        return info
    }

    private static func workingDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard n == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw -> String in
            let p = raw.bindMemory(to: CChar.self).baseAddress!
            return String(cString: p)
        }
        return path.isEmpty ? nil : path
    }

    private static func ttyPath(from info: proc_bsdinfo) -> String? {
        let raw = info.e_tdev
        guard raw != UInt32.max, raw != 0 else { return nil }
        // devname() returns a static buffer string like "ttys003" for the dev_t.
        guard let cstr = devname(dev_t(bitPattern: UInt32(raw)), S_IFCHR) else {
            return nil
        }
        let name = String(cString: cstr)
        guard !name.isEmpty, name != "??" else { return nil }
        return "/dev/" + name
    }
}
