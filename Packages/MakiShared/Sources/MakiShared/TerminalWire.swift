import Foundation

/// Length-prefixed framing for the terminal socket.
///
/// A stream socket has no message boundaries: four big-endian bytes give the
/// payload length, and JSON follows. The cap is deliberately small; a terminal
/// command is a few hundred bytes, and an unbounded length is an easy way to
/// make a local socket allocate without limit.
public enum TerminalWireError: Error, Equatable, LocalizedError {
    case frameTooLarge(Int)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case let .frameTooLarge(size):
            return "Terminal message is too large (\(size) bytes)"
        case let .malformed(detail):
            return "Terminal message is malformed: \(detail)"
        }
    }
}

public enum TerminalWire {
    public static let maximumFrameBytes = 1 << 20

    public static func frame(_ message: TerminalMessage) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        guard payload.count <= maximumFrameBytes else {
            throw TerminalWireError.frameTooLarge(payload.count)
        }
        var data = Data(capacity: 4 + payload.count)
        let length = UInt32(payload.count)
        data.append(UInt8((length >> 24) & 0xFF))
        data.append(UInt8((length >> 16) & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))
        data.append(payload)
        return data
    }

    public static func decode(_ payload: Data) throws -> TerminalMessage {
        do {
            return try JSONDecoder().decode(TerminalMessage.self, from: payload)
        } catch {
            throw TerminalWireError.malformed(error.localizedDescription)
        }
    }
}

/// Accumulates bytes from a stream and yields whole messages.
public struct TerminalFrameDecoder {
    private var buffer = Data()

    public init() {}

    /// Appends a read chunk and returns every complete message it now holds.
    /// A partial frame stays buffered; a malformed or oversized one throws and
    /// the caller closes the connection.
    public mutating func append(_ data: Data) throws -> [TerminalMessage] {
        buffer.append(data)
        var messages: [TerminalMessage] = []
        while buffer.count >= 4 {
            let header = [UInt8](buffer.prefix(4))
            let length = (Int(header[0]) << 24)
                | (Int(header[1]) << 16)
                | (Int(header[2]) << 8)
                | Int(header[3])
            guard length > 0 else {
                throw TerminalWireError.malformed("empty frame")
            }
            guard length <= TerminalWire.maximumFrameBytes else {
                throw TerminalWireError.frameTooLarge(length)
            }
            guard buffer.count >= 4 + length else { break }
            let payload = Data(buffer.dropFirst(4).prefix(length))
            buffer.removeFirst(4 + length)
            messages.append(try TerminalWire.decode(payload))
        }
        return messages
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}
