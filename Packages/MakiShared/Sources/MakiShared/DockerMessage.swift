import Foundation

/// One message on the MakiDesk ↔ Docker helper socket.
///
/// Like the terminal boundary, this is a closed set of message kinds and a
/// small optional body. The helper never executes an arbitrary payload: the
/// one action that crosses into another app is `openExec`, and it carries only
/// a container reference and an allow-listed shell.
public struct DockerMessage: Codable, Equatable, Sendable {
    public static let wireVersion = 1

    public enum Kind: String, Codable, Sendable {
        // Handshake
        case hello
        case welcome
        case ping
        case pong
        // Commands from MakiDesk
        case showMain
        case hideMain
        case quit
        case themeChanged
        // Events from the helper
        case openExec
        case state
        case willTerminate
    }

    public struct Body: Codable, Equatable, Sendable {
        public var protocolVersion: Int?
        public var appVersion: String?
        public var build: String?
        public var pid: Int32?
        public var bundleIdentifier: String?
        public var containerID: String?
        public var shell: String?
        public var title: String?
        public var message: String?
        public var detail: String?
        public var contextName: String?
        public var containerCount: Int?
        public var imageCount: Int?
        public var volumeCount: Int?
        public var networkCount: Int?

        public init(protocolVersion: Int? = nil,
                    appVersion: String? = nil,
                    build: String? = nil,
                    pid: Int32? = nil,
                    bundleIdentifier: String? = nil,
                    containerID: String? = nil,
                    shell: String? = nil,
                    title: String? = nil,
                    message: String? = nil,
                    detail: String? = nil,
                    contextName: String? = nil,
                    containerCount: Int? = nil,
                    imageCount: Int? = nil,
                    volumeCount: Int? = nil,
                    networkCount: Int? = nil) {
            self.protocolVersion = protocolVersion
            self.appVersion = appVersion
            self.build = build
            self.pid = pid
            self.bundleIdentifier = bundleIdentifier
            self.containerID = containerID
            self.shell = shell
            self.title = title
            self.message = message
            self.detail = detail
            self.contextName = contextName
            self.containerCount = containerCount
            self.imageCount = imageCount
            self.volumeCount = volumeCount
            self.networkCount = networkCount
        }
    }

    public var version: Int
    public var id: UUID
    public var kind: Kind
    public var body: Body?

    public init(kind: Kind, body: Body? = nil, id: UUID = UUID()) {
        self.version = Self.wireVersion
        self.id = id
        self.kind = kind
        self.body = body
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.wireVersion
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(Kind.self, forKey: .kind)
        body = try container.decodeIfPresent(Body.self, forKey: .body)
    }
}

public enum DockerWireError: Error, Equatable, LocalizedError {
    case frameTooLarge(Int)
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case let .frameTooLarge(size):
            return "Docker message is too large (\(size) bytes)"
        case let .malformed(detail):
            return "Docker message is malformed: \(detail)"
        }
    }
}

/// Length-prefixed framing for the Docker socket.
public enum DockerWire {
    public static let maximumFrameBytes = 1 << 20

    public static func frame(_ message: DockerMessage) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        guard payload.count <= maximumFrameBytes else {
            throw DockerWireError.frameTooLarge(payload.count)
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

    public static func decode(_ payload: Data) throws -> DockerMessage {
        do {
            return try JSONDecoder().decode(DockerMessage.self, from: payload)
        } catch {
            throw DockerWireError.malformed(error.localizedDescription)
        }
    }
}

/// Accumulates bytes from a stream and yields whole Docker messages.
public struct DockerFrameDecoder {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [DockerMessage] {
        buffer.append(data)
        var messages: [DockerMessage] = []
        while buffer.count >= 4 {
            let header = [UInt8](buffer.prefix(4))
            let length = (Int(header[0]) << 24)
                | (Int(header[1]) << 16)
                | (Int(header[2]) << 8)
                | Int(header[3])
            guard length > 0 else {
                throw DockerWireError.malformed("empty frame")
            }
            guard length <= DockerWire.maximumFrameBytes else {
                throw DockerWireError.frameTooLarge(length)
            }
            guard buffer.count >= 4 + length else { break }
            let payload = Data(buffer.dropFirst(4).prefix(length))
            buffer.removeFirst(4 + length)
            messages.append(try DockerWire.decode(payload))
        }
        return messages
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
    }
}
