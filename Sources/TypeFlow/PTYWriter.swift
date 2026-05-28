import Darwin
import Foundation

enum PTYWriter {
    enum WriteError: Error {
        case openFailed(path: String, errno: Int32)
        case writeFailed(errno: Int32)
    }

    /// Writes `text` to the target tty, then a newline to submit.
    ///
    /// The payload is wrapped in bracketed-paste escape sequences
    /// (ESC [ 200 ~ ... ESC [ 201 ~) so the receiving terminal — and any
    /// readline/Ink-based CLI like claude — treats the whole block as a
    /// single paste rather than processing one keystroke at a time. This is
    /// what fixes mangling on long or multi-line prompts.
    ///
    /// Bracketed paste has been supported by xterm/iTerm2/Warp/Alacritty/
    /// kitty/Terminal.app for years, and is enabled by default in Node.js
    /// readline (and therefore by claude). On a terminal that doesn't
    /// support it, the escape sequences are still safe — they're swallowed
    /// or appear as literal characters at most, never destructive.
    static func send(_ text: String, to ttyPath: String) throws {
        let fd = open(ttyPath, O_WRONLY | O_NOCTTY)
        guard fd >= 0 else {
            throw WriteError.openFailed(path: ttyPath, errno: errno)
        }
        defer { close(fd) }

        let pasteStart = "\u{1B}[200~"
        let pasteEnd = "\u{1B}[201~"
        // Normalise line endings: claude expects \n inside a paste block, not \r\n.
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\r", with: "\n")
        let payload = pasteStart + normalised + pasteEnd + "\r"

        try payload.withCString { cstr in
            let len = strlen(cstr)
            var written = 0
            while written < len {
                let n = Darwin.write(fd, cstr.advanced(by: written), len - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw WriteError.writeFailed(errno: errno)
                }
                written += n
            }
        }
    }
}
