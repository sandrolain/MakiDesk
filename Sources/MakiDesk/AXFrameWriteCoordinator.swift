import AppKit

/// Owns only pending frame writes. A state exists while a window has queued
/// work and is removed as soon as its queue drains.
final class AXFrameWriteCoordinator: @unchecked Sendable {
    typealias FrameWriter = @Sendable (CGRect, AXUIElement, CGRect?,
                                        WindowController.FrameWriteOrder) throws -> Void

    private struct Request: @unchecked Sendable {
        let frame: CGRect
        let element: AXUIElement
        let order: WindowController.FrameWriteOrder
        let completion: (@MainActor () -> Void)?
    }

    private final class State: @unchecked Sendable {
        let queue: DispatchQueue
        var pending: Request?
        var draining = false
        var lastWritten: CGRect?

        init(identity: String) {
            queue = DispatchQueue(label: "com.makidesk.ax-frame-\(identity)", qos: .userInitiated)
        }
    }

    static let shared = AXFrameWriteCoordinator(writeFrame: { frame, element, previous, order in
        try AXEnhancedUIController.performFrameAdjustment(for: element) {
            switch order {
            case .positionThenSize:
                if frame.origin != previous?.origin { try WindowController.setPosition(frame.origin, for: element) }
                if frame.size != previous?.size { try WindowController.setSize(frame.size, for: element) }
            case .sizeThenPosition:
                if frame.size != previous?.size { try WindowController.setSize(frame.size, for: element) }
                if frame.origin != previous?.origin { try WindowController.setPosition(frame.origin, for: element) }
            }
        }
    })
    private let lock = NSLock()
    private let writeFrame: FrameWriter
    private var states: [String: State] = [:]

    init(writeFrame: @escaping FrameWriter) {
        self.writeFrame = writeFrame
    }

    func enqueue(_ frame: CGRect, element: AXUIElement, identity: String,
                 order: WindowController.FrameWriteOrder,
                 completion: (@MainActor () -> Void)?) {
        // Our own windows must never reach this queue: AppKit runs the write
        // in-process and its text input invalidation asserts the main thread.
        // `WindowController.setFrameAsync` keeps them on the main actor.
        guard WindowController.isOwnProcess(element) == false else {
            makiLog.error("frame write for our own window reached a worker queue identity=\(identity, privacy: .public)")
            return
        }
        lock.lock()
        let state = states[identity] ?? State(identity: identity)
        states[identity] = state
        state.pending = Request(frame: frame, element: element, order: order, completion: completion)
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
            let previous = state.lastWritten
            lock.unlock()

            var succeeded = true
            do {
                try writeFrame(request.frame, request.element, previous, request.order)
            } catch {
                succeeded = false
                makiLog.error("frame write failed window=\(identity, privacy: .public) order=\(String(describing: request.order), privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }

            lock.lock()
            if succeeded { state.lastWritten = request.frame }
            lock.unlock()
            if let completion = request.completion {
                Task { @MainActor in completion() }
            }
        }
    }
}
