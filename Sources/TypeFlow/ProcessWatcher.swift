import Darwin
import Foundation

struct ClaudeSession: Equatable {
    let pid: pid_t
    let ttyPath: String
    let startTime: TimeInterval
}

final class ProcessWatcher {
    private(set) var sessions: [ClaudeSession] = []
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "typeflow.processwatcher")
    var onChange: (([ClaudeSession]) -> Void)?

    func start(interval: TimeInterval = 0.5) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval)
        t.setEventHandler { [weak self] in self?.refresh() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// v1 routing: most recently started `claude` process.
    /// TODO: replace with AX-based frontmost-Warp-window → child-PID mapping.
    func target() -> ClaudeSession? {
        sessions.max(by: { $0.startTime < $1.startTime })
    }

    private func refresh() {
        let current = Self.findClaudeProcesses()
        if current != sessions {
            sessions = current
            let snapshot = current
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(snapshot)
            }
        }
    }

    // MARK: - libproc lookup

    private static func findClaudeProcesses() -> [ClaudeSession] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }

        let capacity = Int(needed) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<pid_t>.size

        var found: [ClaudeSession] = []
        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            guard let name = processName(pid: pid), name == "claude" else { continue }
            guard let tty = ttyPath(pid: pid) else { continue }
            let start = startTime(pid: pid) ?? 0
            found.append(ClaudeSession(pid: pid, ttyPath: tty, startTime: start))
        }
        return found
    }

    private static func processName(pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let n = proc_name(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    private static func ttyPath(pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard n == size else { return nil }

        let dev = info.e_tdev
        guard dev != UInt32.max, dev != 0 else { return nil }

        // devname() resolves dev_t back to a path like "ttys003"
        guard let cstr = devname_r(dev_t(dev), S_IFCHR, nil, 0) ?? devname(dev_t(dev), S_IFCHR) else {
            return nil
        }
        let name = String(cString: cstr)
        guard !name.isEmpty, name != "??" else { return nil }
        return "/dev/" + name
    }

    private static func startTime(pid: pid_t) -> TimeInterval? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard n == size else { return nil }
        return TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
    }
}
