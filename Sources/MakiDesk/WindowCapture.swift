import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Window image capture backed by ScreenCaptureKit, plus the Screen Recording
/// permission probes used by the UI.
///
/// The previous implementation called `CGWindowListCreateImage` (deprecated on
/// macOS 14) synchronously on the main thread, once per window, after an
/// uncached `CGWindowListCopyWindowInfo` — which blocked the main thread for
/// seconds on a busy desktop. Here captures are asynchronous, run off the main
/// thread, are cached by window id with a short TTL and are downscaled before
/// use.
enum WindowCapture {
    /// One capture request: an opaque key returned with the image, plus the
    /// on-screen window id to capture.
    struct Request {
        let key: String
        let windowID: CGWindowID
    }

    private struct CaptureBatch {
        let requests: [Request]
        let maxDimension: CGFloat
        let onImage: @MainActor (String, NSImage) -> Void
    }

    // MARK: - Permission

    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    @discardableResult
    static func requestAuthorization() -> Bool { CGRequestScreenCaptureAccess() }

    // MARK: - Capture cache

    private struct Cached {
        let image: NSImage
        let date: Date
        let cost: Int
        var lastAccess: Date
    }

    private struct CacheKey: Hashable {
        let windowID: CGWindowID
        let identity: String
        let maxDimension: Int
    }

    private static let cacheTTL: TimeInterval = 5
    private static let cacheByteLimit = 64 * 1024 * 1024
    @MainActor private static var cacheBytes = 0
    @MainActor private static var cache: [CacheKey: Cached] = [:]
    @MainActor private static var captureInFlight = false
    @MainActor private static var queuedBatch: CaptureBatch?
    @MainActor private static var captureTask: Task<Void, Never>?
    private static let screenshotBudget = ScreenshotBudget()

    private actor ScreenshotBudget {
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !busy { busy = true; return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if waiters.isEmpty { busy = false }
            else { waiters.removeFirst().resume() }
        }
    }

    @MainActor
    static func cancelPaletteCapture() {
        queuedBatch = nil
        captureTask?.cancel()
    }

    // MARK: - Capture

    /// Captures the given windows, delivering each image as it is ready on the
    /// main actor. Returns immediately; images are produced asynchronously.
    /// When `force` is true the cache TTL is bypassed so every request is
    /// re-captured (used for the live refresh while the palette is open); the
    /// fresh images are still written back to the cache.
    @MainActor
    static func capture(
        _ requests: [Request],
        maxDimension: CGFloat = 640,
        force: Bool = false,
        onImage: @MainActor @escaping (String, NSImage) -> Void
    ) {
        guard isAuthorized, !requests.isEmpty else { return }
        let now = Date()
        let dimension = Int(maxDimension.rounded())
        var pending: [Request] = []
        for request in requests {
            let cacheKey = CacheKey(windowID: request.windowID, identity: request.key, maxDimension: dimension)
            if let hit = cache[cacheKey], force || now.timeIntervalSince(hit.date) < cacheTTL {
                cache[cacheKey]?.lastAccess = now
                let image = hit.image
                let key = request.key
                Task { @MainActor in onImage(key, image) }
                if force { pending.append(request) }
            } else {
                pending.append(request)
            }
        }
        guard !pending.isEmpty else { return }
        let batch = CaptureBatch(requests: pending, maxDimension: maxDimension, onImage: onImage)
        if captureInFlight {
            // Keep at most one follow-up batch. A newer visible palette state
            // replaces requests from an obsolete refresh cycle.
            queuedBatch = batch
            return
        }
        startCapture(batch)
    }

    @MainActor
    private static func startCapture(_ batch: CaptureBatch) {
        captureInFlight = true
        let dimension = Int(batch.maxDimension.rounded())
        captureTask = Task.detached(priority: .userInitiated) {
            defer {
                Task { @MainActor in
                    captureInFlight = false
                    captureTask = nil
                    if let queued = queuedBatch {
                        queuedBatch = nil
                        startCapture(queued)
                    }
                }
            }
            guard !Task.isCancelled, let content = try? await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return }
            var windowsByID: [CGWindowID: SCWindow] = [:]
            for window in content.windows { windowsByID[window.windowID] = window }

            for request in batch.requests {
                guard !Task.isCancelled else { return }
                guard let window = windowsByID[request.windowID] else { continue }
                guard let image = await image(of: window, maxDimension: batch.maxDimension) else { continue }
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    let cacheKey = CacheKey(windowID: request.windowID, identity: request.key, maxDimension: dimension)
                    insert(image, for: cacheKey)
                    batch.onImage(request.key, image)
                }
            }
        }
    }

    /// Keeps recent captures within a decoded-memory budget. A full-screen
    /// palette image cannot evict every compact-size thumbnail for the same ID.
    @MainActor
    private static func insert(_ image: NSImage, for key: CacheKey) {
        let cost = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            .map { $0.bytesPerRow * $0.height } ?? 0
        if let old = cache.removeValue(forKey: key) { cacheBytes -= old.cost }
        guard cost <= cacheByteLimit else { return }
        cache[key] = Cached(image: image, date: Date(), cost: cost, lastAccess: Date())
        cacheBytes += cost
        while cacheBytes > cacheByteLimit,
              let oldest = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess }) {
            cacheBytes -= oldest.value.cost
            cache.removeValue(forKey: oldest.key)
        }
    }

    /// Edge-energy score per request, for the auto-layout entropy ordering.
    /// Returns an empty dictionary when Screen Recording is unavailable, so the
    /// caller can fall back to a size-based score.
    static func scores(for requests: [Request], maxDimension: CGFloat = 400) async -> [String: Double] {
        guard !Task.isCancelled, isAuthorized, !requests.isEmpty else { return [:] }
        guard let content = try? await SCShareableContent
            .excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return [:] }
        var windowsByID: [CGWindowID: SCWindow] = [:]
        for window in content.windows { windowsByID[window.windowID] = window }

        var result: [String: Double] = [:]
        for request in requests {
            guard !Task.isCancelled else { return [:] }
            guard let window = windowsByID[request.windowID],
                  let image = await image(of: window, maxDimension: maxDimension) else { continue }
            result[request.key] = edgeEnergy(image)
        }
        return result
    }

    /// Captures one window of an application, found by geometry among **all**
    /// windows — minimised and owned by a hidden app, all included. That is
    /// exactly the peek's case (T16): the window it shows
    /// has no on-screen number to look up by, and ScreenCaptureKit leaves it out
    /// of the on-screen content (`onScreenWindowsOnly: true`), which is why the
    /// palette's path could never see it.
    static func captureWindow(
        pid: pid_t,
        near frame: CGRect,
        maxDimension: CGFloat = 1600
    ) async -> NSImage? {
        guard isAuthorized else { return nil }
        let capture = Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard !Task.isCancelled else { return nil }
            guard let content = try? await SCShareableContent
                .excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return nil }
            let candidates = content.windows.filter { $0.owningApplication?.processID == pid }
            guard let window = closest(to: frame, among: candidates) else { return nil }
            return await image(of: window, maxDimension: maxDimension)
        }
        return await withTaskCancellationHandler {
            await capture.value
        } onCancel: {
            capture.cancel()
        }
    }

    /// The window whose geometry is nearest to `frame`. Window coordinates are
    /// top-left based in both Accessibility and ScreenCaptureKit, so the
    /// comparison is direct; the size difference keeps a window from being
    /// mistaken for a shadow or a popover of the same app.
    private static func closest(to frame: CGRect, among windows: [SCWindow]) -> SCWindow? {
        var best: SCWindow?
        var bestScore = CGFloat.greatestFiniteMagnitude
        for window in windows {
            let size = window.frame.size
            let score = abs(window.frame.minX - frame.minX) + abs(window.frame.minY - frame.minY)
                + abs(size.width - frame.width) + abs(size.height - frame.height)
            if score < bestScore {
                bestScore = score
                best = window
            }
        }
        return best
    }

    private static func image(of window: SCWindow, maxDimension: CGFloat) async -> NSImage? {
        await screenshotBudget.acquire()
        defer { Task { await screenshotBudget.release() } }
        guard !Task.isCancelled else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let source = window.frame.size
        let scale = maxDimension / max(source.width, source.height, 1)
        let factor = scale < 1 ? scale : 1
        configuration.width = max(2, Int((source.width * factor).rounded()))
        configuration.height = max(2, Int((source.height * factor).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        guard let cgImage = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        ) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    // MARK: - Entropy

    /// How much detail a window carries: the mean absolute luminance step
    /// between neighbouring pixels, in both directions, on a grayscale copy.
    ///
    /// The copy is large enough — 240 × 150 — for a page of text to still read
    /// as text. On the coarse grid this used to be (48 × 32) a line of 14 pt
    /// text averaged away into flat grey, and a mostly empty window with a
    /// couple of hard edges could outrank a full editor: the measure has to see
    /// the small steps, or it measures the frame instead of the content.
    /// Windows with dense content — editors, terminals, busy pages — land in the
    /// tens; a nearly empty window stays close to zero. Sampling is uniform, so
    /// the same content scores the same whatever the window's size on screen.
    static func edgeEnergy(_ image: NSImage) -> Double {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return 0
        }
        let width = 240
        let height = 150
        var pixels = [UInt8](repeating: 0, count: width * height)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .low
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return 0 }
        var total = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let value = Double(pixels[y * width + x])
                if x > 0 { total += abs(value - Double(pixels[y * width + x - 1])) }
                if y > 0 { total += abs(value - Double(pixels[(y - 1) * width + x])) }
            }
        }
        let pairs = Double(2 * width * height - width - height)
        return pairs > 0 ? total / pairs : 0
    }
}
