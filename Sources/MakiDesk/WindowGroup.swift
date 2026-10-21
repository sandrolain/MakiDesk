import Foundation

/// A window the user can run actions on, reduced to the fields a group needs to
/// remember and to re-find it later.
struct WindowIdentity: Equatable {
    var id: String
    var bundleId: String?
    var appName: String
    var title: String?
    var document: String?
}

/// A member of a group: enough clues to recognise the window again, in the same
/// session (via `systemIdentity`) and after a restart (via the app/title/document
/// ladder). Codable so groups can be persisted (G2).
struct WindowRef: Codable, Equatable, Identifiable {
    var bundleId: String?
    var appName: String
    var title: String?
    var document: String?
    /// The runtime window id when this ref was taken (see `stableID`). Precise
    /// within a session; stale after a restart, where the ladder takes over.
    var systemIdentity: String?

    var id: String { systemIdentity ?? "\(bundleId ?? appName)|\(title ?? "")" }

    /// What to show when the member has no title worth reading.
    var label: String {
        if let title, !title.isEmpty { return title }
        return appName
    }

    init(identity: WindowIdentity) {
        self.bundleId = identity.bundleId
        self.appName = identity.appName
        self.title = identity.title
        self.document = identity.document
        self.systemIdentity = identity.id
    }

    /// Whether two refs point at the same window (used to toggle membership).
    func matches(_ other: WindowRef) -> Bool {
        if let a = systemIdentity, let b = other.systemIdentity {
            if a == b { return true }
            // A changed window id from the same process is not a restart. Do
            // not let a sibling with the same title steal this membership.
            if GroupMatcher.processID(in: a) == GroupMatcher.processID(in: b),
               GroupMatcher.processID(in: a) != nil { return false }
        }
        if let a = bundleId, let b = other.bundleId, a == b {
            if let title, let otherTitle = other.title, title == otherTitle { return true }
            if let document, let otherDocument = other.document, document == otherDocument { return true }
        }
        return appName == other.appName && title != nil && title == other.title
    }
}

/// A numbered set of windows (slot 1…9) that can be shown together. Think of it
/// as a saved selection: the palette loads it into the tick marks, and edits to
/// the tick marks are edits to the group.
///
/// A group holds **no layout**: recalling it puts its windows back where they
/// were, and the arrangement is only ever what the user gave them — a layout
/// preset is applied to what is on screen, on request (T18).
struct WindowGroup: Codable, Equatable, Identifiable {
    var id: UUID
    var slot: Int
    var name: String?
    var members: [WindowRef] = []
    /// The **arrangement remembered** for this group (T15): the frame each member
    /// had the last time the group was laid out, keyed by `WindowRef.id` (so it
    /// travels with the member and can be looked up at the next recall).
    ///
    /// Only normal frames are ever written here: a window that is minimised or
    /// put away by a scene keeps its remembered place, or a recall would
    /// faithfully restore a position off the screen.
    var frames: [String: CGRect] = [:]

    /// Whether the group remembers where its windows were. An empty table means
    /// "nothing recorded yet": the first recall brings the windows back where
    /// they stand and records that (T15).
    var hasArrangement: Bool { !frames.isEmpty }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return "Group \(slot)"
    }

    init(id: UUID = UUID(), slot: Int, name: String? = nil,
         members: [WindowRef] = [], frames: [String: CGRect] = [:]) {
        self.id = id
        self.slot = slot
        self.name = name
        self.members = members
        self.frames = frames
    }

    /// Groups written before T15 have no `frames` at all: they load with an empty
    /// arrangement (and the next recall records one) rather than failing to
    /// decode and taking every other group with them. A `layout` written by an
    /// older version is ignored — a group no longer has one (T18).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        slot = try container.decode(Int.self, forKey: .slot)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        members = try container.decodeIfPresent([WindowRef].self, forKey: .members) ?? []
        frames = try container.decodeIfPresent([String: CGRect].self, forKey: .frames) ?? [:]
    }
}

/// Finds the live window behind each saved reference, without ever handing the
/// same window to two members. Pure, so it is unit-tested without accessibility
/// permissions.
enum GroupMatcher {
    static func processID(in systemIdentity: String?) -> String? {
        guard let systemIdentity, let separator = systemIdentity.firstIndex(of: "-") else { return nil }
        let prefix = systemIdentity[..<separator]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber) else { return nil }
        return String(prefix)
    }

    /// One optional index into `windows` per reference, in the same order.
    static func match(_ refs: [WindowRef], to windows: [WindowIdentity]) -> [Int?] {
        // The "any window of that app" fallback is only safe when the app holds a
        // single member in the group; otherwise it could steal a sibling's window.
        let perBundle = Dictionary(grouping: refs, by: { $0.bundleId ?? "" }).mapValues(\.count)
        var used = Set<Int>()
        return refs.map { ref in
            let allowLoose = ref.bundleId.map { perBundle[$0] == 1 } ?? false
            let index = bestMatch(for: ref, in: windows, used: used, allowLoose: allowLoose)
            if let index { used.insert(index) }
            return index
        }
    }

    private static func bestMatch(
        for ref: WindowRef, in windows: [WindowIdentity], used: Set<Int>, allowLoose: Bool
    ) -> Int? {
        let refProcessID = processID(in: ref.systemIdentity)
        func first(_ predicate: (WindowIdentity) -> Bool) -> Int? {
            windows.indices.first { index in
                guard !used.contains(index) else { return false }
                let candidate = windows[index]
                if let refID = ref.systemIdentity,
                   refID != candidate.id,
                   let refProcessID,
                   processID(in: candidate.id) == refProcessID {
                    return false
                }
                return predicate(candidate)
            }
        }

        // 1. The exact window from this session.
        if let id = ref.systemIdentity, let index = first({ $0.id == id }) { return index }

        if let bundle = ref.bundleId {
            // 2. Same app and same document.
            if let document = ref.document, let index = first({ $0.bundleId == bundle && $0.document == document }) {
                return index
            }
            // 3. Same app and exact title.
            if let title = ref.title, let index = first({ $0.bundleId == bundle && $0.title == title }) {
                return index
            }
            // 4. Same app, first free window — only when it cannot be ambiguous.
            if allowLoose, let index = first({ $0.bundleId == bundle }) { return index }
        }

        // The bundle id was unavailable: fall back to the app name and title.
        if let title = ref.title, let index = first({ $0.appName == ref.appName && $0.title == title }) {
            return index
        }
        return nil
    }
}
