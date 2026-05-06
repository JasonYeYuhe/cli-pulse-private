import Foundation

/// Length-prefixed JSON UDS protocol — Swift port of the framing
/// layer in `helper/local_session_server.py`.
///
/// Wire format (matches the Python implementation byte-for-byte so
/// existing macOS app clients keep working):
///
///   - 4-byte big-endian unsigned length header
///   - N-byte JSON-encoded body (UTF-8)
///
/// Both sides MUST cap payloads at `Framing.maxPayload` to avoid
/// trivial DoS. Header-claimed sizes above the cap fail before
/// any draining happens (mirrors the Python `read_frame` early-
/// reject path); payloads larger than the cap on the writer side
/// throw `FrameError.frameTooLarge` before any bytes hit the
/// socket.
public enum Framing {
    /// 1 MiB. Same as Python `MAX_PAYLOAD = 1 << 20`. Anything
    /// larger almost certainly indicates a buggy client or an
    /// attempt to exhaust helper memory; refuse early.
    public static let maxPayload: Int = 1 << 20

    public enum FrameError: Error, Equatable {
        /// Header claims a payload size > `maxPayload`. Reader
        /// returns this WITHOUT draining the body; writer returns
        /// it WITHOUT sending anything.
        case frameTooLarge(claimed: Int)
        /// Header arrived but the connection ended before the
        /// declared payload size was fully read. Different from a
        /// clean EOF (where the reader returns `nil`).
        case frameTruncated
        /// Underlying socket I/O failed. Carries the localised
        /// errno description for telemetry.
        case ioError(String)
    }

    /// Read one frame from `fd`. Blocking — caller is responsible
    /// for spawning the read on an appropriate thread / Task.
    /// Returns `nil` on a clean EOF where no header bytes were
    /// received (peer closed without writing). Throws
    /// `frameTruncated` on a half-written frame.
    public static func readFrame(from fd: Int32) throws -> Data? {
        var headerBuf = Data(count: 4)
        switch try readExactly(fd, into: &headerBuf, count: 4) {
        case .closed: return nil
        case .truncated: throw FrameError.frameTruncated
        case .complete: break
        }
        let claimed = Int(UInt32(bigEndianBytes: headerBuf))
        if claimed > maxPayload {
            throw FrameError.frameTooLarge(claimed: claimed)
        }
        if claimed == 0 {
            return Data()
        }
        var body = Data(count: claimed)
        switch try readExactly(fd, into: &body, count: claimed) {
        case .closed, .truncated:
            throw FrameError.frameTruncated
        case .complete:
            return body
        }
    }

    /// Write one frame to `fd`. Blocking. Throws `frameTooLarge`
    /// when `body.count > maxPayload`; nothing is written in that
    /// case so a misuse can't poison subsequent frames.
    public static func writeFrame(to fd: Int32, body: Data) throws {
        if body.count > maxPayload {
            throw FrameError.frameTooLarge(claimed: body.count)
        }
        let header = UInt32(body.count).bigEndianBytes
        var combined = Data()
        combined.reserveCapacity(4 + body.count)
        combined.append(header)
        combined.append(body)
        try writeAll(fd, data: combined)
    }

    // MARK: - low-level helpers

    /// Result of `readExactly`. Distinguishes a clean peer-close
    /// (no header bytes ever read → `closed`) from a half-frame
    /// (some bytes read but not enough → `truncated`).
    private enum ReadOutcome { case complete, closed, truncated }

    private static func readExactly(_ fd: Int32, into buffer: inout Data, count: Int) throws -> ReadOutcome {
        var totalRead = 0
        while totalRead < count {
            let chunkRead: Int = try buffer.withUnsafeMutableBytes { rawPtr in
                guard let base = rawPtr.baseAddress else { return 0 }
                let writePtr = base.advanced(by: totalRead)
                let want = count - totalRead
                let n = Darwin.read(fd, writePtr, want)
                if n < 0 {
                    let savedErrno = errno
                    if savedErrno == EINTR { return -1 }
                    throw FrameError.ioError("read: \(String(cString: strerror(savedErrno)))")
                }
                return n
            }
            if chunkRead == -1 { continue }                  // EINTR retry
            if chunkRead == 0 {
                // Peer closed.
                if totalRead == 0 {
                    return .closed
                }
                return .truncated
            }
            totalRead += chunkRead
        }
        return .complete
    }

    private static func writeAll(_ fd: Int32, data: Data) throws {
        var offset = 0
        let total = data.count
        try data.withUnsafeBytes { rawPtr -> Void in
            guard let base = rawPtr.baseAddress else { return }
            while offset < total {
                let writePtr = base.advanced(by: offset)
                let n = Darwin.write(fd, writePtr, total - offset)
                if n < 0 {
                    let savedErrno = errno
                    if savedErrno == EINTR { continue }
                    throw FrameError.ioError("write: \(String(cString: strerror(savedErrno)))")
                }
                offset += n
            }
        }
    }
}

// MARK: - Big-endian conversion helpers

private extension UInt32 {
    init(bigEndianBytes data: Data) {
        precondition(data.count >= 4)
        let b0 = UInt32(data[data.startIndex])
        let b1 = UInt32(data[data.startIndex + 1])
        let b2 = UInt32(data[data.startIndex + 2])
        let b3 = UInt32(data[data.startIndex + 3])
        self = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
    var bigEndianBytes: Data {
        var be = self.bigEndian
        return Data(bytes: &be, count: 4)
    }
}
