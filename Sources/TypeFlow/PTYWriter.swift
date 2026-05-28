import Darwin
import Foundation

enum PTYWriter {
    enum WriteError: Error {
        case openFailed(path: String, errno: Int32)
        case writeFailed(errno: Int32)
    }

    /// Default chunk and inter-chunk delay tuned for claude (Ink-based REPL):
    ///   - Plain blast write on long text: claude drops characters / wraps oddly.
    ///   - Bracketed paste markers (ESC[200~ ... ESC[201~): claude swallows the
    ///     trailing \r inside paste mode, so the prompt never submits.
    ///   - Chunked writes with small gaps: claude processes each chunk as
    ///     normal typed input; Enter at the end is a real keystroke that
    ///     submits, and Backspace inside claude works on the resulting text.
    static let chunkSize = 32
    static let interChunkMicros: UInt32 = 8_000   // 8ms
    static let preSubmitMicros: UInt32 = 50_000   // 50ms before the final \r

    /// Writes `text` to the target tty as if typed, then sends Enter to submit.
    /// Multi-line input is normalised to `\n`; the final submission uses `\r`.
    static func send(_ text: String, to ttyPath: String) throws {
        let fd = open(ttyPath, O_WRONLY | O_NOCTTY)
        guard fd >= 0 else {
            throw WriteError.openFailed(path: ttyPath, errno: errno)
        }
        defer { close(fd) }

        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\r", with: "\n")
        let bytes = Array(normalised.utf8)

        try writeChunked(bytes, fd: fd)

        // Small pause so claude finishes redrawing its input buffer before
        // the Enter keystroke lands.
        if !bytes.isEmpty { usleep(preSubmitMicros) }

        try writeRaw([0x0D], fd: fd) // CR == Enter
    }

    private static func writeChunked(_ bytes: [UInt8], fd: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            let slice = Array(bytes[offset..<end])
            try writeRaw(slice, fd: fd)
            offset = end
            if offset < bytes.count { usleep(interChunkMicros) }
        }
    }

    private static func writeRaw(_ bytes: [UInt8], fd: Int32) throws {
        try bytes.withUnsafeBufferPointer { buf in
            let total = buf.count
            var written = 0
            while written < total {
                let n = Darwin.write(fd, buf.baseAddress!.advanced(by: written),
                                     total - written)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw WriteError.writeFailed(errno: errno)
                }
                written += n
            }
        }
    }
}
