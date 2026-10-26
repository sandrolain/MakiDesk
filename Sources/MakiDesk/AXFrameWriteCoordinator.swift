import AppKit
import ApplicationServices

/// Owns only pending frame writes. A state exists while a window has queued
/// work and is removed as soon as its queue drains.
///
/// Writes are serialized per logical window and coalesced: a newer request
/// replaces a pending one, so an animation never floods an app with frames.
/// Position-only writes exist for the mini-map drag, which moves a window
/// without touching its size.
final class AXFrameWriteCoordinator: @unchecked Sendable {
    typealias FrameWriter = @Sendable (CGRect, AXUIElement, CGRect?,
                                        WindowController.FrameWriteOrder) throws -> Void
    typealias PositionWriter = @Sendable (CGPoint, AXUIElement) throws -> Void

    private enum Work: Sendable {
        case frame(CGRect, WindowController.FrameWriteOrder)
        case position(CGPoint)
    }

    private struct Request: @unchecked Sendable {
        let element: AXUIElement
        let work: Work
        let completion: (@MainActor () -> Void)?
    }

    private final class State: @unchecked Sendable {
        let queue: DispatchQueue
        var pending: Request?
        var draining = false
        var lastOrigin: CGPoint?
        var lastSize: CGSize?

        init(identity: String) {
            queue = DispatchQueue(label: "com.makidesk.ax-frame-\(identity)", qos: .userInitiated)
        }

        /// The last frame written, when both halves are known. It lets the
        /// frame writer skip an unchanged position or size.
        var previousFrame: CGRect? {
            guard let lastOrigin, let lastSize else { return nil }
            return CGRect(origin: lastOrigin, size: lastSize)
        }
    }

    static let shared = AXFrameWriteCoordinator(
        frameWriter: { frame, element, previous, order in
            try AXEnhancedUIController.performFrameAdjustment(for: element) {
                switch order {
                case .positionThenSize:
                    if frame.origin != previous?.origin {
                        try WindowController.setPosition(frame.origin, for: element)
                    }
                    if frame.size != previous?.size {
                        try WindowController.setSize(frame.size, for: element)
                    }
                case .sizeThenPosition:
                    if frame.size != previous?.size {
                        try WindowController.setSize(frame.size, for: element)
                    }
                    if frame.origin != previous?.origin {
                        try WindowController.setPosition(frame.origin, for: element)
                    }
                }
            }
        },
        positionWriter: { origin, element in
            try AXEnhancedUIController.performFrameAdjustment(for: element) {
                try WindowController.setPosition(origin, for: element)
            }
        }
    )

    private let lock = NSLock()
    private let frameWriter: FrameWriter
    private let positionWriter: PositionWriter
    private var states: [String: State] = [:]

    init(frameWriter: @escaping FrameWriter, positionWriter: @escaping PositionWriter) {
        self.frameWriter = frameWriter
        self.positionWriter = positionWriter
    }

    /// A coordinator without position writes, for tests that only exercise
    /// frames.
    convenience init(frameWriter: @escaping FrameWriter) {
        self.init(frameWriter: frameWriter, positionWriter: { _, _ in })
    }

    func enqueue(_ frame: CGRect, element: AXUIElement, identity: String,
                 order: WindowController.FrameWriteOrder,
                 completion: (@MainActor () -> Void)?) {
        enqueue(Request(element: element, work: .frame(frame, order), completion: completion),
                identity: identity)
    }

    func enqueuePosition(_ origin: CGPoint, element: AXUIElement, identity: String,
                         completion: (@MainActor () -> Void)? = nil) {
        enqueue(Request(element: element, work: .position(origin), completion: completion),
                identity: identity)
    }

    private func enqueue(_ request: Request, identity: String) {
        // Our own windows must never reach this queue: AppKit runs the write
        // in-process and its text input invalidation asserts the main thread.
        // `WindowController.setFrameAsync`/`setPositionAsync` keep them on main.
        guard WindowController.isOwnProcess(request.element) == false else {
            makiLog.error("frame write for our own window reached a worker queue identity=\(identity, privacy: .public)")
            return
        }
        lock.lock()
        let state = states[identity] ?? State(identity: identity)
        states[identity] = state
        state.pending = request
        let shouldStart = !state.draining
        if shouldStart { state.draining = true }
        lock.unlock()

        if shouldStart {
            state.queue.async { [self] in drain(state, identity: identity) }
        }
    }

    private func drain(_ state: State, identity: String) {
        while true {
            lock.lock()
            guard let request = state.pending else {
                state.draining = false
                states[identity] = nil
                lock.unlock()
                return
            }
            state.pending = nil
            let previous = state.previousFrame
            let previousOrigin = state.lastOrigin
            lock.unlock()

            do {
                switch request.work {
                case let .frame(frame, order):
                    try frameWriter(frame, request.element, previous, order)
                    lock.lock()
                    state.lastOrigin = frame.origin
                    state.lastSize = frame.size
                    lock.unlock()
                case let .position(origin):
                    // A drag can enqueue the same point repeatedly; the last
                    // write already put the window there.
                    if previousOrigin != origin {
                        try positionWriter(origin, request.element)
                        lock.lock()
                        state.lastOrigin = origin
                        lock.unlock()
                    }
                }
            } catch {
                makiLog.error("frame write failed window=\(identity, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }

            if let completion = request.completion {
                Task { @MainActor in completion() }
            }
        }
    }
}
