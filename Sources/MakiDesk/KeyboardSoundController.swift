import AVFAudio
import AppKit
import CoreGraphics
import Foundation
import Observation

enum KeyboardSoundPreset: String, CaseIterable, Identifiable, Sendable {
    case soft
    case crisp
    case low
    case quack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .soft: return "Soft"
        case .crisp: return "Crisp"
        case .low: return "Low"
        case .quack: return "Quack"
        }
    }

    var frequency: Double {
        switch self {
        case .soft: return 1_450
        case .crisp: return 2_450
        case .low: return 820
        case .quack: return 640
        }
    }

    var noise: Double {
        switch self {
        case .soft: return 0.015
        case .crisp: return 0.11
        case .low: return 0.025
        case .quack: return 0.2
        }
    }

    var decay: Double {
        switch self {
        case .soft: return 240
        case .crisp: return 390
        case .low: return 180
        case .quack: return 45
        }
    }
}

@Observable
@MainActor
final class KeyboardSoundController {
    static let shared = KeyboardSoundController()

    private(set) var isEnabled: Bool
    private(set) var preset: KeyboardSoundPreset
    private(set) var volume: Double
    private(set) var permissionGranted: Bool
    private(set) var isListening = false
    private(set) var listenerUnavailable = false

    @ObservationIgnored private let playback = KeyboardSoundPlaybackEngine()
    @ObservationIgnored private let eventQueue: KeyboardSoundEventQueue
    @ObservationIgnored private let eventTap: KeyboardEventTap
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isStarting = false

    private init() {
        isEnabled = Settings.bool(.keyboardSoundsEnabled)
        preset = Settings.value(.keyboardSoundsPreset, as: KeyboardSoundPreset.self) ?? .soft
        let storedVolume = Settings.double(.keyboardSoundsVolume)
        volume = min(max(storedVolume, 0), 1)
        permissionGranted = CGPreflightListenEventAccess()

        eventQueue = KeyboardSoundEventQueue(queue: playback.queue) { [weak playback] in
            playback?.playOnQueue()
        }
        eventTap = KeyboardEventTap(eventQueue: eventQueue)

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPermissionAndStartIfAllowed() }
        }
    }

    deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
    }

    var permissionMessage: String {
        if isListening { return "Keyboard sounds are on." }
        if isEnabled && !permissionGranted {
            return "Allow MakiDesk in Privacy & Security ▸ Input Monitoring."
        }
        if listenerUnavailable {
            return "Keyboard sound listener could not start. Toggle it off and on to retry."
        }
        if isStarting && permissionGranted { return "Starting keyboard sounds…" }
        return "Off. MakiDesk listens only after you turn this on."
    }

    func start() {
        guard isEnabled else { return }
        permissionGranted = CGPreflightListenEventAccess()
        guard permissionGranted else { return }
        beginListening()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        Settings.set(enabled, for: .keyboardSoundsEnabled)
        generation &+= 1

        guard enabled else {
            isListening = false
            isStarting = false
            eventQueue.clear()
            listenerUnavailable = false
            eventTap.stop()
            playback.stop()
            return
        }

        permissionGranted = CGRequestListenEventAccess()
        if permissionGranted {
            beginListening()
        } else {
            permissionGranted = CGPreflightListenEventAccess()
        }
    }

    func setPreset(_ value: KeyboardSoundPreset) {
        guard value != preset else { return }
        preset = value
        Settings.set(value.rawValue, for: .keyboardSoundsPreset)
        playback.setPreset(value)
    }

    func setVolume(_ value: Double) {
        let bounded = min(max(value, 0), 1)
        guard bounded != volume else { return }
        volume = bounded
        Settings.set(bounded, for: .keyboardSoundsVolume)
        playback.setVolume(Float(bounded))
    }

    func preview() {
        guard isEnabled, permissionGranted else { return }
        playback.preview()
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func shutdown() {
        generation &+= 1
        isListening = false
        isStarting = false
        eventQueue.clear()
        eventTap.stop()
        playback.stop()
    }

    private func refreshPermissionAndStartIfAllowed() {
        permissionGranted = CGPreflightListenEventAccess()
        if !permissionGranted, isListening || isStarting {
            generation &+= 1
            isListening = false
            isStarting = false
            eventQueue.clear()
            eventTap.stop()
            playback.stop()
        }
        guard isEnabled, permissionGranted, !isListening, !isStarting else { return }
        beginListening()
    }

    private func beginListening() {
        guard isEnabled, permissionGranted, !isListening, !isStarting else { return }
        generation &+= 1
        let expectedGeneration = generation
        isStarting = true
        listenerUnavailable = false
        playback.start(preset: preset, volume: Float(volume))
        eventQueue.setActive(true)
        eventTap.start { [weak self] succeeded in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expectedGeneration, self.isEnabled else { return }
                self.isStarting = false
                self.isListening = succeeded
                if !succeeded {
                    self.permissionGranted = CGPreflightListenEventAccess()
                    self.listenerUnavailable = true
                    self.eventQueue.clear()
                    self.playback.stop()
                }
            }
        }
    }
}

/// The callback retains no key code, character, modifier or application data.
/// It records only a capped count of key-down signals and schedules at most one
/// drain on the audio queue at a time.
private final class KeyboardSoundEventQueue: @unchecked Sendable {
    // `pending` and `drainScheduled` are protected by `lock`; the callback only
    // transfers a bounded count to this queue and never carries event details.
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let play: @Sendable () -> Void
    private var pending = 0
    private var drainScheduled = false
    private var isActive = false
    private let maximumPending = 3

    init(queue: DispatchQueue, play: @escaping @Sendable () -> Void) {
        self.queue = queue
        self.play = play
    }

    func receiveKeyDown() {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        pending = min(pending + 1, maximumPending)
        let shouldSchedule = !drainScheduled
        drainScheduled = true
        lock.unlock()

        if shouldSchedule {
            queue.async { [weak self] in self?.drain() }
        }
    }

    func clear() {
        lock.lock()
        isActive = false
        pending = 0
        lock.unlock()
    }

    func setActive(_ value: Bool) {
        lock.lock()
        isActive = value
        if !value { pending = 0 }
        lock.unlock()
    }

    private func drain() {
        while true {
            lock.lock()
            guard pending > 0 else {
                drainScheduled = false
                lock.unlock()
                return
            }
            pending -= 1
            lock.unlock()
            play()
        }
    }
}

/// Owns the listen-only event tap and its run loop on a dedicated thread.
private final class KeyboardEventTap: @unchecked Sendable {
    private let lock = NSLock()
    private let eventQueue: KeyboardSoundEventQueue
    private var shouldRun = false
    private var generation: UInt64 = 0
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    init(eventQueue: KeyboardSoundEventQueue) {
        self.eventQueue = eventQueue
    }

    func start(completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        guard !shouldRun else {
            lock.unlock()
            return
        }
        generation &+= 1
        let expectedGeneration = generation
        shouldRun = true
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.run(generation: expectedGeneration, completion: completion)
        }
        thread.name = "com.makidesk.keyboard-sound-events"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.lock()
        shouldRun = false
        generation &+= 1
        let tap = self.tap
        let runLoop = self.runLoop
        lock.unlock()

        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            if let tap { CFMachPortInvalidate(tap) }
            CFRunLoopStop(runLoop)
        }
        CFRunLoopWakeUp(runLoop)
    }

    private func run(generation expectedGeneration: UInt64,
                     completion: @escaping @Sendable (Bool) -> Void) {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            lock.lock()
            if generation == expectedGeneration { shouldRun = false }
            lock.unlock()
            completion(false)
            return
        }

        let runLoop = CFRunLoopGetCurrent()
        lock.lock()
        guard shouldRun, generation == expectedGeneration else {
            lock.unlock()
            CFMachPortInvalidate(tap)
            completion(false)
            return
        }
        self.tap = tap
        self.runLoop = runLoop
        lock.unlock()

        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        completion(true)
        CFRunLoopRun()
        CFRunLoopRemoveSource(runLoop, source, .commonModes)

        lock.lock()
        if generation == expectedGeneration {
            self.tap = nil
            self.runLoop = nil
            shouldRun = false
        }
        lock.unlock()
    }

    private func handle(type: CGEventType) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The event proxy is not the CFMachPort required by tapEnable, so
            // use the port owned by this controller. Recovery remains local.
            lock.lock()
            let tap = self.tap
            lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        } else if type == .keyDown {
            eventQueue.receiveKeyDown()
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        Unmanaged<KeyboardEventTap>.fromOpaque(userInfo)
            .takeUnretainedValue()
            .handle(type: type)
        return Unmanaged.passUnretained(event)
    }
}

/// Generates short local click buffers and schedules them through one audio
/// queue. The preset uses synthesized PCM, so no third-party sound assets or
/// sample licenses are bundled.
private final class KeyboardSoundPlaybackEngine: @unchecked Sendable {
    // Every mutable AVAudioEngine/player/buffer field is read or written only
    // on `queue`; public methods enqueue changes onto that same serial executor.
    let queue = DispatchQueue(label: "com.makidesk.keyboard-sound-audio", qos: .userInteractive)

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var buffer: AVAudioPCMBuffer?
    private var preset: KeyboardSoundPreset = .soft
    private var volume: Float = 0.35

    func start(preset: KeyboardSoundPreset, volume: Float) {
        queue.async { [weak self] in
            guard let self else { return }
            self.preset = preset
            self.volume = min(max(volume, 0), 1)
            self.prepareBuffer()
            guard self.engine == nil,
                  let format = self.format else {
                self.player?.volume = self.volume
                return
            }

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = self.volume
            do {
                try engine.start()
                player.play()
                self.engine = engine
                self.player = player
            } catch {
                MakiLog.app.error("KeyboardSound: audio engine failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.player?.stop()
            self.engine?.stop()
            self.player = nil
            self.engine = nil
        }
    }

    func setPreset(_ value: KeyboardSoundPreset) {
        queue.async { [weak self] in
            guard let self else { return }
            self.preset = value
            self.prepareBuffer()
        }
    }

    func setVolume(_ value: Float) {
        queue.async { [weak self] in
            guard let self else { return }
            self.volume = min(max(value, 0), 1)
            self.engine?.mainMixerNode.outputVolume = self.volume
        }
    }

    func preview() {
        queue.async { [weak self] in self?.playOnQueue() }
    }

    func playOnQueue() {
        guard let player, let buffer else { return }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    private func prepareBuffer() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else { return }
        self.format = format
        let sampleRate = format.sampleRate
        let duration = preset == .quack ? 0.085 : 0.018
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else { return }

        buffer.frameLength = frameCount
        var random: UInt32 = 0x6D2B79F5
        for index in 0..<Int(frameCount) {
            let time = Double(index) / sampleRate
            let envelope = exp(-time * preset.decay)
            let attack = min(1, time / 0.00035)
            random = 1_664_525 &* random &+ 1_013_904_223
            let noise = (Double(random) / Double(UInt32.max) * 2 - 1) * preset.noise
            let pitch = preset == .quack
                ? max(180, preset.frequency - time * 5_200)
                : preset.frequency
            let body = sin(2 * .pi * pitch * time) * 0.55
                + sin(2 * .pi * pitch * 2.4 * time) * 0.18
            channel[index] = Float((body + noise) * envelope * attack)
        }
        self.buffer = buffer
    }
}
