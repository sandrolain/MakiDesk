import AppKit

/// Reads the focused window of the frontmost app on a worker and hands the
/// result back on the main actor.
///
/// The app being read may be slow, and focus events must not park the main
/// thread behind it. One read runs at a time. A request made while it runs
/// marks it stale, so one more read follows; so does a result for an app that
/// is no longer frontmost. Both repeats are bounded, after which the latest
/// answer is delivered as it is. Reading and the system queries are injected,
/// so the policy is tested without Accessibility.
@MainActor
final class FocusReadCoordinator {
    /// Why a read was asked for; each purpose's effects run once when the
    /// read that covers it completes.
    enum Purpose: Hashable { case now, change, inventory }

    struct Target {
        let pid: pid_t
        let appName: String?
    }

    typealias Reader = @Sendable (pid_t, String?, [WindowController.WindowInfo]) -> WindowController.Frontmost
    typealias Delivery = (WindowController.Frontmost, pid_t?, Set<Purpose>) -> Void

    static let maximumRepeats = 2

    private let frontmostTarget: () -> Target?
    private let indexedWindows: () -> [WindowController.WindowInfo]
    private let read: Reader
    private let deliver: Delivery
    private let queue: DispatchQueue

    private var inFlight = false
    private var stale = false
    private var purposes: Set<Purpose> = []

    init(frontmostTarget: @escaping () -> Target?,
         indexedWindows: @escaping () -> [WindowController.WindowInfo],
         read: @escaping Reader = { pid, name, indexed in
             WindowController.readFocusedWindow(pid: pid, appName: name, indexed: indexed)
         },
         queue: DispatchQueue = DispatchQueue(label: "MakiDesk.focus-read", qos: .userInteractive),
         deliver: @escaping Delivery) {
        self.frontmostTarget = frontmostTarget
        self.indexedWindows = indexedWindows
        self.read = read
        self.queue = queue
        self.deliver = deliver
    }

    func request(_ purpose: Purpose) {
        purposes.insert(purpose)
        if inFlight {
            stale = true
            return
        }
        start(repeatCount: 0)
    }

    private func start(repeatCount: Int) {
        guard let target = frontmostTarget() else {
            finish(.none, pid: nil)
            return
        }
        inFlight = true
        stale = false
        let indexed = indexedWindows()
        let read = self.read
        queue.async { [weak self] in
            let result = read(target.pid, target.appName, indexed)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight = false
                let stillFrontmost = self.frontmostTarget()?.pid == target.pid
                if (!stillFrontmost || self.stale), repeatCount < Self.maximumRepeats {
                    self.start(repeatCount: repeatCount + 1)
                    return
                }
                self.finish(stillFrontmost ? result : .none, pid: stillFrontmost ? target.pid : nil)
            }
        }
    }

    private func finish(_ focused: WindowController.Frontmost, pid: pid_t?) {
        let delivered = purposes
        purposes.removeAll()
        deliver(focused, pid, delivered)
    }
}
