import Foundation

/// One message on the MakiDesk ↔ Terminal socket (F1).
///
/// A closed kind and a small optional body: the helper executes only message
/// kinds it knows, never arbitrary payloads. `id` pairs a reply with its
/// request; `version` is the wire format, separate from the app versions in the
/// handshake body.
public struct TerminalMessage: Codable, Equatable, Sendable {
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
        case toggleQuake
        case quit
        // Events from the terminal
        case state
        case attention
        case settingsRequested
        case willTerminate
    }

    public struct Body: Codable, Equatable, Sendable {
        public var protocolVersion: Int?
        public var appVersion: String?
        public var build: String?
        public var pid: Int32?
        public var bundleIdentifier: String?
        public var message: String?
        public var workspaceCount: Int?
        public var quakeVisible: Bool?
        public var page: String?

        public init(protocolVersion: Int? = nil,
                    appVersion: String? = nil,
                    build: String? = nil,
                    pid: Int32? = nil,
                    bundleIdentifier: String? = nil,
                    message: String? = nil,
                    workspaceCount: Int? = nil,
                    quakeVisible: Bool? = nil,
                    page: String? = nil) {
            self.protocolVersion = protocolVersion
            self.appVersion = appVersion
            self.build = build
            self.pid = pid
            self.bundleIdentifier = bundleIdentifier
            self.message = message
            self.workspaceCount = workspaceCount
            self.quakeVisible = quakeVisible
            self.page = page
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
