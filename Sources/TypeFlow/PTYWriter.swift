import Darwin
import Foundation

enum PTYWriter {
    enum WriteError: Error {
        case openFailed(path: String, errno: Int32)
        case writeFailed(errno: Int32)
    }

    static func send(_ text: String, to ttyPath: String, appendNewline: Bool = true) throws {
        let fd = open(ttyPath, O_WRONLY | O_NOCTTY)
        guard fd >= 0 else {
            throw WriteError.openFailed(path: ttyPath, errno: errno)
        }
        defer { close(fd) }

        let payload = appendNewline ? text + "\n" : text
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
