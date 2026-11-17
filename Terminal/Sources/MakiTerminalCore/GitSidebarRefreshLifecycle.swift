import Foundation

public struct GitSidebarRefreshLifecycle: Equatable, Sendable {
    public private(set) var isEnabled = false
    public private(set) var isWindowVisible = false
    public private(set) var generation: UInt64 = 0

    public init() {}

    public var shouldRefresh: Bool {
        isEnabled && isWindowVisible
    }

    public mutating func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        generation &+= 1
    }

    public mutating func setWindowVisible(_ visible: Bool) {
        guard isWindowVisible != visible else { return }
        isWindowVisible = visible
        generation &+= 1
    }

    public mutating func beginRequest() -> UInt64 {
        generation &+= 1
        return generation
    }

    public func canPublish(_ requestGeneration: UInt64) -> Bool {
        shouldRefresh && generation == requestGeneration
    }
}
