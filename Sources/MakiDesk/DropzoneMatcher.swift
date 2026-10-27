import Foundation
import UniformTypeIdentifiers

/// What one dragged element looks like to the matcher: a kind, a display name,
/// and a UTI for files. It carries no path, so a rejection message can be shown
/// without leaking the file system.
struct DropItemInfo: Equatable, Sendable {
    enum Kind: String, Sendable {
        case file
        case text
        case url
        case image
    }

    var kind: Kind
    var uti: String?
    var name: String
    /// Position in the original drop, so an `any` match can keep exactly the
    /// sources it accepted. Matching itself ignores it.
    var index: Int

    init(kind: Kind, uti: String? = nil, name: String = "", index: Int = 0) {
        self.kind = kind
        self.uti = uti
        self.name = name
        self.index = index
    }
}

enum DropzoneMatch: Equatable, Sendable {
    /// The items the command will receive. With `match: any` these are only the
    /// compatible ones.
    case accepted([DropItemInfo])
    case rejected(DropzoneRejection)

    var acceptedItems: [DropItemInfo] {
        if case let .accepted(items) = self { return items }
        return []
    }

    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

enum DropzoneRejection: Equatable, Sendable, LocalizedError {
    case disabled
    case emptyPayload
    case wrongKind(DropItemInfo.Kind)
    case unknownType(String)
    case wrongType(String)
    case invalidConfiguration(String)
    case tooFew(Int)
    case tooMany(Int)

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "This dropzone is disabled."
        case .emptyPayload:
            return "Nothing was dropped."
        case let .wrongKind(kind):
            return "This dropzone does not accept \(Self.label(for: kind)) items."
        case let .unknownType(name):
            return "Could not tell what “\(name)” is; this dropzone accepts specific file types."
        case let .wrongType(name):
            return "“\(name)” is not a type this dropzone accepts."
        case let .invalidConfiguration(reason):
            return "The dropzone configuration is invalid: \(reason)"
        case let .tooFew(count):
            return "This dropzone needs at least \(count) items."
        case let .tooMany(count):
            return "This dropzone accepts at most \(count) items."
        }
    }

    private static func label(for kind: DropItemInfo.Kind) -> String {
        switch kind {
        case .file: return "file"
        case .text: return "text"
        case .url: return "link"
        case .image: return "image"
        }
    }
}

/// Decides whether a dropzone can take what is being dragged.
///
/// Matching during a drag is best effort: a file promise or a file whose type
/// cannot be read yet arrives as an unknown UTI and is accepted only when the
/// zone declares no types. The authoritative check happens on the real payload
/// at drop time, with the same function.
enum DropzoneMatcher {
    static func match(_ items: [DropItemInfo], zone: DropzoneConfig) -> DropzoneMatch {
        guard zone.enabled else { return .rejected(.disabled) }
        guard items.isEmpty == false else { return .rejected(.emptyPayload) }
        guard zone.accepts.kinds.isEmpty == false else {
            return .rejected(.invalidConfiguration("no accepted kinds"))
        }

        var acceptedTypes: [UTType] = []
        for raw in zone.accepts.utis {
            guard let type = UTType(raw) else {
                return .rejected(.invalidConfiguration("\(raw) is not a UTI"))
            }
            acceptedTypes.append(type)
        }

        var compatible: [DropItemInfo] = []
        var firstRejection: DropzoneRejection?
        for item in items {
            switch compatibility(of: item, in: zone, acceptedTypes: acceptedTypes) {
            case .accepted:
                compatible.append(item)
            case let .rejected(rejection):
                if zone.accepts.match == .all { return .rejected(rejection) }
                if firstRejection == nil { firstRejection = rejection }
            }
        }

        guard compatible.isEmpty == false else {
            return .rejected(firstRejection ?? .emptyPayload)
        }
        if let minimum = zone.accepts.minItems, compatible.count < minimum {
            return .rejected(.tooFew(minimum))
        }
        if let maximum = zone.accepts.maxItems, compatible.count > maximum {
            return .rejected(.tooMany(maximum))
        }
        return .accepted(compatible)
    }

    private enum Compatibility {
        case accepted
        case rejected(DropzoneRejection)
    }

    /// A short description of what a zone will receive, shown on its tile
    /// during a drag (T47). Counts only: no path and no file system access.
    static func summary(for items: [DropItemInfo]) -> String {
        var counts: [DropItemInfo.Kind: Int] = [:]
        for item in items { counts[item.kind, default: 0] += 1 }
        var parts: [String] = []
        func append(_ kind: DropItemInfo.Kind, one: String, many: String) {
            guard let count = counts[kind], count > 0 else { return }
            parts.append("\(count) \(count == 1 ? one : many)")
        }
        append(.file, one: "file", many: "files")
        append(.image, one: "image", many: "images")
        append(.url, one: "link", many: "links")
        append(.text, one: "text", many: "texts")
        return parts.joined(separator: " · ")
    }

    private static func compatibility(of item: DropItemInfo,
                                      in zone: DropzoneConfig,
                                      acceptedTypes: [UTType]) -> Compatibility {
        switch item.kind {
        case .text:
            return zone.accepts.accepts(kind: .text) ? .accepted : .rejected(.wrongKind(.text))
        case .url:
            return zone.accepts.accepts(kind: .urls) ? .accepted : .rejected(.wrongKind(.url))
        case .image:
            guard zone.accepts.accepts(kind: .images) else { return .rejected(.wrongKind(.image)) }
            guard acceptedTypes.isEmpty == false else { return .accepted }
            return acceptedTypes.contains { UTType.image.conforms(to: $0) }
                ? .accepted
                : .rejected(.wrongType(item.name))
        case .file:
            guard zone.accepts.accepts(kind: .files) else { return .rejected(.wrongKind(.file)) }
            // No declared types: any file, including a type we cannot read yet.
            guard acceptedTypes.isEmpty == false else { return .accepted }
            guard let raw = item.uti, let type = UTType(raw) else {
                return .rejected(.unknownType(item.name))
            }
            return acceptedTypes.contains { type.conforms(to: $0) }
                ? .accepted
                : .rejected(.wrongType(item.name))
        }
    }
}
