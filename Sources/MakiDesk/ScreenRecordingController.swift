import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

/// Failures of a screen recording that the user has to hear about (T40).
enum ScreenRecordingError: Error, Equatable, LocalizedError {
    case permissionDenied
    case displayUnavailable
    case setupFailed(String)
    case noFrames

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording is required to record the screen."
        case .displayUnavailable:
            return "The display is not available for capture."
        case let .setupFailed(message):
            return "Could not start the recording: \(message)"
        case .noFrames:
            return "The recording captured nothing."
        }
    }
}

/// Writes the captured video and system audio to a movie (T40).
///
/// ScreenCaptureKit hands its samples to one serial queue; pause, resume and
/// stop are commands posted to that same queue. Every mutable field below is
/// therefore touched on that queue only, which is the invariant that makes the
/// `@unchecked Sendable` honest.
final class ScreenRecordingSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let url: URL
    /// Whether the stream carries system audio; when the writer refused the
    /// audio input the recording is video only.
    let includesAudio: Bool
    /// Called on the main queue when the stream dies on its own.
    var onFailure: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "com.makidesk.recording")
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private var stream: SCStream?
    private var started = false
    private var paused = false
    private var pauseBegan: CMTime?
    private var pausedTime = CMTime.zero
    private var failed = false

    init(url: URL, width: Int, height: Int, audio: Bool) throws {
        self.url = url
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw ScreenRecordingError.setupFailed(error.localizedDescription)
        }
        self.writer = writer
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, width * height * 5),
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else {
            throw ScreenRecordingError.setupFailed("The video track could not be added.")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ])
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }
        self.audioInput = audioInput
        includesAudio = audioInput != nil
        super.init()
        guard writer.startWriting() else {
            throw ScreenRecordingError.setupFailed(
                writer.error?.localizedDescription ?? "The movie file could not be opened."
            )
        }
    }

    /// Attaches the outputs and starts the stream. The stream is built by the
    /// caller so the filter and configuration live next to the selection.
    func start(_ stream: SCStream) async throws {
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if audioInput != nil {
            // A stream that refuses the audio output still records the video:
            // the track is simply left without samples.
            try? stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        do {
            try await stream.startCapture()
        } catch {
            writer.cancelWriting()
            throw ScreenRecordingError.setupFailed(error.localizedDescription)
        }
    }

    func setPaused(_ value: Bool) {
        queue.async { [self] in
            guard !failed else { return }
            if value, !paused {
                paused = true
                pauseBegan = CMClockGetTime(CMClockGetHostTimeClock())
            } else if !value, paused {
                paused = false
                if let began = pauseBegan {
                    pausedTime = CMTimeAdd(pausedTime,
                                           CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), began))
                }
                pauseBegan = nil
            }
        }
    }

    /// Stops the stream and finishes the file. The URL is `nil` when nothing was
    /// written; the message explains why, when the writer knows.
    func stop() async -> (url: URL?, message: String?) {
        if let stream { try? await stream.stopCapture() }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                guard started, writer.status == .writing else {
                    writer.cancelWriting()
                    // The writer had already opened the file: a movie with no
                    // frames must not be left behind on the shelf's behalf.
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(returning: (nil, ScreenRecordingError.noFrames.localizedDescription))
                    return
                }
                writer.finishWriting {
                    let url = self.writer.status == .completed ? self.url : nil
                    if url == nil { try? FileManager.default.removeItem(at: self.url) }
                    continuation.resume(returning: (url, self.writer.error?.localizedDescription))
                }
            }
        }
    }

    // MARK: - Samples

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard !failed else { return }
        switch type {
        case .screen:
            guard isCompleteFrame(buffer) else { return }
            append(buffer, to: videoInput)
        case .audio:
            if let audioInput { append(buffer, to: audioInput) }
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        queue.async { [self] in
            guard failed == false else { return }
            failed = true
            DispatchQueue.main.async { [onFailure] in onFailure?(message) }
        }
    }

    /// ScreenCaptureKit also delivers "idle" buffers — the screen did not change
    /// — which carry no new frame.
    private func isCompleteFrame(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            buffer, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return true }
        return status == .complete
    }

    /// On the session queue, from the sample callback or a command.
    private func append(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput) {
        guard writer.status == .writing, paused == false else { return }
        let adjusted: CMSampleBuffer
        if pausedTime > .zero {
            guard let retimed = retime(buffer, subtracting: pausedTime) else { return }
            adjusted = retimed
        } else {
            adjusted = buffer
        }
        let stamp = CMSampleBufferGetPresentationTimeStamp(adjusted)
        guard stamp.isValid else { return }
        if started == false {
            writer.startSession(atSourceTime: stamp)
            started = true
        }
        guard input.isReadyForMoreMediaData else { return }
        if input.append(adjusted) == false {
            failed = writer.status == .failed
        }
    }

    /// The paused stretch is cut out of the movie: the next frame carries the
    /// timestamp it would have had without the pause.
    private func retime(_ buffer: CMSampleBuffer, subtracting offset: CMTime) -> CMSampleBuffer? {
        let stamp = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard stamp.isValid else { return buffer }
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(buffer),
            presentationTimeStamp: CMTimeSubtract(stamp, offset),
            decodeTimeStamp: .invalid
        )
        guard timing.presentationTimeStamp >= .zero else { return buffer }
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: buffer,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleBufferOut: &copy
        ) == noErr else { return nil }
        return copy
    }
}

/// Records an area of the screen into a movie on the shelf (T40).
///
/// Area selection is the shared selector (T49); the movie is written by
/// `ScreenRecordingSession`. The recording lives in the menu-bar menu while it
/// runs — pause, resume, stop — and the icon changes so a recording in progress
/// is not forgotten.
@MainActor
@Observable
final class ScreenRecordingController {
    static let shared = ScreenRecordingController()

    enum Phase: Equatable {
        case idle
        case selecting
        case recording
        case paused
    }

    private(set) var phase: Phase = .idle
    /// Seconds recorded so far, the paused stretches left out.
    private(set) var elapsed: TimeInterval = 0

    var isRecording: Bool { phase == .recording || phase == .paused }
    var isBusy: Bool { phase != .idle }

    @ObservationIgnored private var session: ScreenRecordingSession?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var pauseStartedAt: Date?
    @ObservationIgnored private var pausedTotal: TimeInterval = 0
    @ObservationIgnored private var ticker: Timer?

    private init() {}

    /// The menu item and the shortcut both land here: start, or stop what runs.
    func toggle() {
        if isRecording {
            stop()
        } else {
            start()
        }
    }

    func start() {
        guard phase == .idle else { return }
        phase = .selecting
        // A notice still on screen would be in the first frames.
        HUDController.shared.hide()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var options = ScreenRegionSelector.Options()
                options.capturesPixels = false
                options.showsLoupe = false
                options.respectsModifiers = true
                let selection = try await ScreenRegionSelector.shared.select(options: options)
                await self.begin(selection)
            } catch {
                // Cancelled: nothing was started, nothing to say.
                self.phase = .idle
            }
        }
    }

    func togglePause() {
        guard let session else { return }
        switch phase {
        case .recording:
            session.setPaused(true)
            pauseStartedAt = Date()
            phase = .paused
            refreshElapsed()
        case .paused:
            if let began = pauseStartedAt {
                pausedTotal += Date().timeIntervalSince(began)
            }
            pauseStartedAt = nil
            session.setPaused(false)
            phase = .recording
        default:
            break
        }
    }

    func stop() {
        guard let session else { return }
        self.session = nil
        stopTicker()
        let recorded = elapsed
        phase = .idle
        Task { @MainActor [weak self] in
            let result = await session.stop()
            self?.elapsed = 0
            guard let url = result.url else {
                HUDController.shared.show(result.message ?? "The recording could not be saved",
                                          symbol: "exclamationmark.triangle.fill", kind: .warning)
                return
            }
            ShelfController.shared.add(file: url)
            HUDController.shared.show("Recording on the shelf · \(RecordingClock.text(recorded))",
                                      symbol: "record.circle", kind: .success)
        }
    }

    // MARK: - Session

    private func begin(_ selection: ScreenRegionSelector.Selection) async {
        let scale = selection.display.scale
        // H.264 needs even dimensions.
        let width = max(2, Int((selection.rect.width * scale).rounded()) & ~1)
        let height = max(2, Int((selection.rect.height * scale).rounded()) & ~1)

        guard ScreenRegionCapture.isAuthorized else {
            phase = .idle
            HUDController.shared.show(ScreenRecordingError.permissionDenied.localizedDescription,
                                      symbol: "exclamationmark.triangle.fill", kind: .warning)
            return
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let display = content.displays.first(where: { $0.displayID == selection.display.id }) else {
                throw ScreenRecordingError.displayUnavailable
            }
            let session = try ScreenRecordingSession(
                url: Self.recordingURL(),
                width: width, height: height,
                audio: WorkspaceStore.shared.recordingIncludesAudio
            )
            session.onFailure = { [weak self] message in
                Task { @MainActor in
                    guard let self, self.session != nil else { return }
                    self.stop()
                    HUDController.shared.show(message, symbol: "exclamationmark.triangle.fill",
                                              kind: .warning)
                }
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = ScreenRegionGeometry.displayLocalRect(
                selection.rect, in: selection.display
            )
            configuration.width = width
            configuration.height = height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 6
            configuration.showsCursor = true
            configuration.capturesAudio = session.includesAudio
            configuration.excludesCurrentProcessAudio = true
            let stream = SCStream(filter: filter, configuration: configuration, delegate: session)
            try await session.start(stream)
            self.session = session
            startedAt = Date()
            pausedTotal = 0
            pauseStartedAt = nil
            elapsed = 0
            phase = .recording
            startTicker()
            HUDController.shared.show("Recording \(RecordingClock.text(0))",
                                      symbol: "record.circle")
        } catch {
            phase = .idle
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            HUDController.shared.show(message, symbol: "exclamationmark.triangle.fill",
                                      kind: .warning)
        }
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshElapsed() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func refreshElapsed() {
        guard phase != .idle else { return }
        let now = Date()
        let paused = pausedTotal + (pauseStartedAt.map { now.timeIntervalSince($0) } ?? 0)
        elapsed = max(0, now.timeIntervalSince(startedAt) - paused)
    }

    private static func recordingURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("MakiDesk/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(RecordingNaming.name(at: Date()))
    }
}

/// `m:ss`, or `h:mm:ss` past the hour, for the recording timer.
enum RecordingClock {
    static func text(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, rest)
        }
        return String(format: "%d:%02d", minutes, rest)
    }
}
