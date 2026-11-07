import Foundation

/// The workspace model (F1), free of AppKit so it can be tested and persisted
/// on its own. A workspace is one tab in the sidebar; its root is a binary tree
/// of splits whose leaves are terminal panes.
public struct PaneID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: UUID

    public init(raw: UUID = UUID()) {
        self.raw = raw
    }

    public var description: String { raw.uuidString }
}

public enum SplitOrientation: String, Codable, Sendable {
    /// Two columns: the divider is vertical.
    case sideBySide
    /// Two rows: the divider is horizontal.
    case stacked
}

public indirect enum SplitNode: Equatable, Codable, Sendable {
    case pane(PaneID)
    case split(orientation: SplitOrientation, ratio: Double, first: SplitNode, second: SplitNode)
}

public struct TerminalWorkspace: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var root: SplitNode
    public var focusedPane: PaneID
    /// Last directory reported by the shell, keyed by pane id string. Kept
    /// beside the tree so restoring a layout can start each shell where it was.
    public var directories: [String: String]

    public init(id: UUID = UUID(),
                title: String,
                firstPane: PaneID = PaneID()) {
        self.id = id
        self.title = title
        self.root = .pane(firstPane)
        self.focusedPane = firstPane
        self.directories = [:]
    }

    // MARK: - Queries

    public var paneIDs: [PaneID] {
        Self.panes(in: root)
    }

    public var paneCount: Int {
        paneIDs.count
    }

    public func contains(_ pane: PaneID) -> Bool {
        paneIDs.contains(pane)
    }

    public func directory(for pane: PaneID) -> String? {
        directories[pane.description]
    }

    public mutating func setDirectory(_ path: String, for pane: PaneID) {
        guard path.isEmpty == false else { return }
        directories[pane.description] = path
    }

    public func node(at path: [Int]) -> SplitNode? {
        var current = root
        for step in path {
            guard case let .split(_, _, first, second) = current else { return nil }
            current = step == 0 ? first : second
        }
        return current
    }

    // MARK: - Mutations

    /// Replaces `pane` with a split and returns the new pane, which becomes
    /// focused. Nil when the pane is not in this workspace.
    @discardableResult
    public mutating func split(_ pane: PaneID,
                               orientation: SplitOrientation,
                               ratio: Double = 0.5,
                               newPane: PaneID = PaneID()) -> PaneID? {
        let (updated, inserted) = Self.insertingSplit(in: root, pane: pane,
                                                      orientation: orientation,
                                                      ratio: ratio,
                                                      newPane: newPane)
        guard inserted else { return nil }
        root = updated
        focusedPane = newPane
        return newPane
    }

    /// Removes a leaf and promotes its sibling. Refuses to remove the last pane
    /// of a workspace; closing the workspace is a separate action.
    @discardableResult
    public mutating func remove(_ pane: PaneID) -> Bool {
        let (updated, found) = Self.removing(in: root, pane: pane)
        guard found, let updated else { return false }
        root = updated
        if focusedPane == pane {
            focusedPane = paneIDs.first ?? PaneID()
        }
        directories[pane.description] = nil
        return true
    }

    @discardableResult
    public mutating func focus(_ pane: PaneID) -> Bool {
        guard contains(pane) else { return false }
        focusedPane = pane
        return true
    }

    /// Sets the divider ratio of the split at `path`. Values outside 0.15…0.85
    /// would let a pane collapse to nothing, so they are clamped.
    @discardableResult
    public mutating func setRatio(_ ratio: Double, at path: [Int]) -> Bool {
        let clamped = min(max(ratio, 0.15), 0.85)
        let (updated, changed) = Self.updatingRatio(in: root, path: path[...], ratio: clamped)
        guard changed else { return false }
        root = updated
        return true
    }

    // MARK: - Tree helpers

    private static func panes(in node: SplitNode) -> [PaneID] {
        switch node {
        case let .pane(id):
            return [id]
        case let .split(_, _, first, second):
            return panes(in: first) + panes(in: second)
        }
    }

    private static func insertingSplit(in node: SplitNode,
                                       pane: PaneID,
                                       orientation: SplitOrientation,
                                       ratio: Double,
                                       newPane: PaneID) -> (SplitNode, Bool) {
        switch node {
        case let .pane(id):
            guard id == pane else { return (node, false) }
            return (.split(orientation: orientation, ratio: ratio,
                           first: .pane(id), second: .pane(newPane)), true)
        case let .split(currentOrientation, currentRatio, first, second):
            let (left, leftInserted) = insertingSplit(in: first, pane: pane,
                                                      orientation: orientation,
                                                      ratio: ratio, newPane: newPane)
            if leftInserted {
                return (.split(orientation: currentOrientation, ratio: currentRatio,
                               first: left, second: second), true)
            }
            let (right, rightInserted) = insertingSplit(in: second, pane: pane,
                                                        orientation: orientation,
                                                        ratio: ratio, newPane: newPane)
            if rightInserted {
                return (.split(orientation: currentOrientation, ratio: currentRatio,
                               first: first, second: right), true)
            }
            return (node, false)
        }
    }

    private static func removing(in node: SplitNode, pane: PaneID) -> (SplitNode?, Bool) {
        switch node {
        case let .pane(id):
            return id == pane ? (nil, true) : (node, false)
        case let .split(orientation, ratio, first, second):
            let (left, leftFound) = removing(in: first, pane: pane)
            if leftFound {
                if let left {
                    return (.split(orientation: orientation, ratio: ratio,
                                   first: left, second: second), true)
                }
                return (second, true)
            }
            let (right, rightFound) = removing(in: second, pane: pane)
            if rightFound {
                if let right {
                    return (.split(orientation: orientation, ratio: ratio,
                                   first: first, second: right), true)
                }
                return (first, true)
            }
            return (node, false)
        }
    }

    private static func updatingRatio(in node: SplitNode,
                                      path: ArraySlice<Int>,
                                      ratio: Double) -> (SplitNode, Bool) {
        guard case let .split(orientation, currentRatio, first, second) = node else {
            return (node, false)
        }
        guard let step = path.first else {
            return (.split(orientation: orientation, ratio: ratio,
                           first: first, second: second), true)
        }
        if step == 0 {
            let (updated, changed) = updatingRatio(in: first, path: path.dropFirst(), ratio: ratio)
            guard changed else { return (node, false) }
            return (.split(orientation: orientation, ratio: currentRatio,
                           first: updated, second: second), true)
        }
        let (updated, changed) = updatingRatio(in: second, path: path.dropFirst(), ratio: ratio)
        guard changed else { return (node, false) }
        return (.split(orientation: orientation, ratio: currentRatio,
                       first: first, second: updated), true)
    }
}
