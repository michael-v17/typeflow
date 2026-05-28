import Darwin
import Foundation

enum PTYWriter {
    enum WriteError: Error {
        case openFailed(path: String, errno: Int32)
        case writeFailed(errno: Int32)
    }

    /// Payloads up to this many bytes go in a single atomic write — best
    /// behavior with claude's Ink input. Beyond it we chunk to avoid
    /// PTY-buffer truncation, but keep the chunks large enough that the
    /// trailing LF still arrives in the same write as preceding text.
    private static let singleWriteThreshold = 2048
    private static let chunkSize = 1024
    private static let interChunkMicros: UInt32 = 8_000

    /// Writes `text` to the tty followed by LF to submit.
    ///
    /// Two requirements that took some discovery:
    ///   1. The submit byte must be LF (0x0A), not CR (0x0D). CR is
    ///      interpreted by the terminal renderer as cursor-to-column-0
    ///      before claude's input handler sees it, so the prompt never
    ///      submits and the caret jumps home.
    ///   2. The LF must arrive in the SAME write() call as the trailing
    ///      bytes of the text. A standalone LF write after the text is
    ///      treated by claude as a stray newline after input has already
    ///      been finalized, leaving the buffer in a half-state where the
    ///      next keystroke wipes it. Inlining the LF in the final chunk
    ///      makes the submit byte part of the same input event.
    static func send(_ text: String, to ttyPath: String) throws {
        let fd = open(ttyPath, O_WRONLY | O_NOCTTY)
        guard fd >= 0 else {
            throw WriteError.openFailed(path: ttyPath, errno: errno)
        }
        defer { close(fd) }

        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\r", with: "\n")
        var bytes = Array(normalised.utf8)
        bytes.append(0x0A)

        if bytes.count <= singleWriteThreshold {
            try writeRaw(bytes, fd: fd)
        } else {
            try writeChunked(bytes, fd: fd)
        }
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
