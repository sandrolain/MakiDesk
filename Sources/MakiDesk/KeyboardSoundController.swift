import AVFAudio
import AppKit
import CoreGraphics
import Foundation
import Observation

enum KeyboardSoundTrigger: String, CaseIterable, Identifiable, Sendable {
    case press, release, both
    var id: String { rawValue }
    var title: String {
        switch self {
        case .press: return "On press"
        case .release: return "On release"
        case .both: return "On press and release"
        }
    }
}

enum KeyboardSoundSource: String, CaseIterable, Identifiable, Sendable {
    case synthesized, soundPack
    var id: String { rawValue }
    var title: String { self == .synthesized ? "Synthesized" : "Sound pack" }
}

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
    private(set) var trigger: KeyboardSoundTrigger
    private(set) var source: KeyboardSoundSource
    private(set) var savedPacks: [KeyboardSoundPackInfo] = []
    private(set) var selectedPackPath = ""
    private(set) var importedPackName: String?
    private(set) var importError: String?
    private(set) var isImportingPack = false
    private(set) var permissionGranted: Bool
    private(set) var isListening = false
    private(set) var listenerUnavailable = false

    @ObservationIgnored private let playback = KeyboardSoundPlaybackEngine()
    @ObservationIgnored private let eventQueue: KeyboardSoundEventQueue
    @ObservationIgnored private let eventTap: KeyboardEventTap
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isStarting = false
    @ObservationIgnored private var importGeneration = 0

    private init() {
        isEnabled = Settings.bool(.keyboardSoundsEnabled)
        preset = Settings.value(.keyboardSoundsPreset, as: KeyboardSoundPreset.self) ?? .soft
        let storedVolume = Settings.double(.keyboardSoundsVolume)
        volume = min(max(storedVolume, 0), 1)
        trigger = Settings.value(.keyboardSoundsTrigger, as: KeyboardSoundTrigger.self) ?? .press
        source = Settings.value(.keyboardSoundsSource, as: KeyboardSoundSource.self) ?? .synthesized
        importedPackName = Settings.string(.keyboardSoundsPack).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent }
        permissionGranted = CGPreflightListenEventAccess()

        eventQueue = KeyboardSoundEventQueue(queue: playback.queue) { [weak playback] keyCode, isDown in
            playback?.playOnQueue(keyCode: keyCode, isDown: isDown)
        }
        eventTap = KeyboardEventTap(eventQueue: eventQueue)

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshPermissionAndStartIfAllowed() }
        }
        let path = Settings.string(.keyboardSoundsPack) ?? ""
        selectedPackPath = path
        Task { @MainActor [weak self] in
            let library = await Task.detached(priority: .utility) {
                KeyboardSoundPackImporter.library()
            }.value
            guard let self else { return }
            for item in library where !self.savedPacks.contains(item) {
                self.savedPacks.append(item)
            }
            if self.importGeneration == 0, !path.isEmpty {
                self.selectPack(path, activate: false)
            }
        }
    }

    func selectPack(_ path: String, activate: Bool = true) {
        guard !isImportingPack else { return }
        isImportingPack = true
        importGeneration &+= 1
        let revision = importGeneration
        Task { @MainActor [weak self] in
            let pack = await Task.detached(priority: .userInitiated) {
                try? KeyboardSoundPackImporter.loadDirectory(URL(fileURLWithPath: path))
            }.value
            guard let self, self.importGeneration == revision else { return }
            self.isImportingPack = false
            guard let pack else {
                self.importError = "The selected sound pack could not be loaded."
                return
            }
            self.applyPack(pack, activate: activate)
        }
    }

    func deletePack(_ path: String) {
        guard let pack = savedPacks.first(where: { $0.id == path }),
              KeyboardSoundPackImporter.isManagedDirectory(URL(fileURLWithPath: path)) else { return }
        do {
            try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        } catch {
            importError = "The sound pack could not be deleted."
            return
        }
        savedPacks.removeAll { $0.id == pack.id }
        guard selectedPackPath == path else { return }
        playback.setPack(nil)
        if let replacement = savedPacks.first {
            selectPack(replacement.id)
        } else {
            selectedPackPath = ""
            importedPackName = nil
            Settings.set("", for: .keyboardSoundsPack)
            setSource(.synthesized)
        }
    }

    func previewPack(_ path: String, release: Bool) {
        guard isEnabled, permissionGranted,
              savedPacks.contains(where: { $0.id == path }) else { return }
        Task { @MainActor [weak self] in
            let pack = await Task.detached(priority: .userInitiated) {
                try? KeyboardSoundPackImporter.loadDirectory(URL(fileURLWithPath: path))
            }.value
            guard let self, self.savedPacks.contains(where: { $0.id == path }),
                  let clip = pack?.clips.sorted(by: { $0.key < $1.key }).first?.value,
                  let buffer = release ? clip.release : clip.press else { return }
            self.playback.preview(buffer)
        }
    }

    private func applyPack(_ pack: KeyboardSoundPack, activate: Bool) {
        let path = pack.directory.path
        if !savedPacks.contains(where: { $0.id == path }) {
            savedPacks.append(.init(id: path, name: pack.name))
        }
        selectedPackPath = path
        importedPackName = pack.name
        importError = nil
        Settings.set(path, for: .keyboardSoundsPack)
        playback.setPack(pack)
        if activate { setSource(.soundPack) }
        else { playback.setUsesPack(source == .soundPack) }
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

    func setTrigger(_ value: KeyboardSoundTrigger) {
        guard trigger != value else { return }
        trigger = value
        Settings.set(value.rawValue, for: .keyboardSoundsTrigger)
        eventQueue.setTrigger(value)
    }

    func setSource(_ value: KeyboardSoundSource) {
        guard value != .soundPack || importedPackName != nil else { return }
        source = value
        Settings.set(value.rawValue, for: .keyboardSoundsSource)
        playback.setUsesPack(value == .soundPack)
    }

    func importSoundPack(_ archive: URL) {
        guard !isImportingPack else { return }
        isImportingPack = true
        importGeneration &+= 1
        let expectedGeneration = importGeneration
        Task { @MainActor [weak self] in
            do {
                let pack = try await Task.detached(priority: .userInitiated) {
                    try KeyboardSoundPackImporter.importArchive(archive)
                }.value
                guard let self else { return }
                guard self.importGeneration == expectedGeneration else { return }
                self.isImportingPack = false
                self.applyPack(pack, activate: true)
            } catch {
                guard let self, self.importGeneration == expectedGeneration else { return }
                self.isImportingPack = false
                self.importError = "Could not import sound pack: \(error.localizedDescription)"
                MakiLog.app.error("KeyboardSound: sound pack import failed (\(String(describing: type(of: error)), privacy: .public))")
            }
        }
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
        eventQueue.setTrigger(trigger)
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

/// The callback transfers only a virtual key code and press/release phase.
/// Held-key state and the capped event queue stay in memory; at most one drain
/// is scheduled on the audio queue at a time.
private final class KeyboardSoundEventQueue: @unchecked Sendable {
    // `pending`, `pressedKeys`, `trigger` and `drainScheduled` are protected by
    // `lock`; no character, modifier or application data enters this queue.
    private let lock = NSLock()
    private let queue: DispatchQueue
    private let play: @Sendable (UInt16, Bool) -> Void
    private var pending: [(UInt16, Bool)] = []
    private var pressedKeys: Set<UInt16> = []
    private var trigger: KeyboardSoundTrigger = .press
    private var drainScheduled = false
    private var isActive = false
    private let maximumPending = 3

    init(queue: DispatchQueue, play: @escaping @Sendable (UInt16, Bool) -> Void) {
        self.queue = queue
        self.play = play
    }

    func setTrigger(_ value: KeyboardSoundTrigger) {
        lock.lock()
        trigger = value
        lock.unlock()
    }

    func receive(keyCode: UInt16, isDown: Bool) {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return
        }
        if isDown {
            guard pressedKeys.insert(keyCode).inserted else { lock.unlock(); return }
            if trigger != .release { pending.append((keyCode, true)) }
        } else {
            guard pressedKeys.remove(keyCode) != nil else { lock.unlock(); return }
            if trigger != .press { pending.append((keyCode, false)) }
        }
        if pending.count > maximumPending { pending.removeFirst(pending.count - maximumPending) }
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
        pending = []
        pressedKeys.removeAll()
        lock.unlock()
    }

    func setActive(_ value: Bool) {
        lock.lock()
        isActive = value
        if !value { pending = []; pressedKeys.removeAll() }
        lock.unlock()
    }

    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                drainScheduled = false
                lock.unlock()
                return
            }
            let event = pending.removeFirst()
            lock.unlock()
            play(event.0, event.1)
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
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
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

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The event proxy is not the CFMachPort required by tapEnable, so
            // use the port owned by this controller. Recovery remains local.
            lock.lock()
            let tap = self.tap
            lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        } else if type == .keyDown || type == .keyUp {
            eventQueue.receive(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), isDown: type == .keyDown)
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        Unmanaged<KeyboardEventTap>.fromOpaque(userInfo)
            .takeUnretainedValue()
            .handle(type: type, event: event)
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
    private var players: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    private var format: AVAudioFormat?
    private var buffer: AVAudioPCMBuffer?
    private var releaseBuffer: AVAudioPCMBuffer?
    private var pack: KeyboardSoundPack?
    private var usesPack = false
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
                self.engine?.mainMixerNode.outputVolume = self.volume
                return
            }

            let engine = AVAudioEngine()
            let players = (0..<32).map { _ in AVAudioPlayerNode() }
            for player in players {
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
            }
            engine.mainMixerNode.outputVolume = self.volume
            do {
                try engine.start()
                self.engine = engine
                self.players = players
                self.nextVoice = 0
            } catch {
                MakiLog.app.error("KeyboardSound: audio engine failed to start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.players.forEach { $0.stop() }
            self.engine?.stop()
            self.players.removeAll()
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
        queue.async { [weak self] in self?.playOnQueue(keyCode: nil, isDown: true) }
    }

    func preview(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in self?.playVoice(buffer) }
    }

    func setPack(_ value: KeyboardSoundPack?) {
        queue.async { [weak self] in self?.pack = value }
    }

    func setUsesPack(_ value: Bool) {
        queue.async { [weak self] in self?.usesPack = value }
    }

    func playOnQueue(keyCode: UInt16? = nil, isDown: Bool = true) {
        if usesPack, let pack {
            let clip = keyCode.map { pack.clips[$0] } ?? pack.clips.values.first
            guard let clip, let buffer = isDown ? clip.press : clip.release else { return }
            playVoice(buffer)
            return
        }
        guard let buffer = isDown ? buffer : (releaseBuffer ?? buffer) else { return }
        playVoice(buffer)
    }

    private func playVoice(_ buffer: AVAudioPCMBuffer) {
        guard !players.isEmpty else { return }
        let voice = players[nextVoice]
        nextVoice = (nextVoice + 1) % players.count
        voice.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !voice.isPlaying { voice.play() }
    }

    private func prepareBuffer() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else { return }
        self.format = format
        let sampleRate = format.sampleRate
        let duration = preset == .quack ? 0.085 : 0.018
        func makeBuffer(release: Bool) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else { return nil }

        buffer.frameLength = frameCount
        var random: UInt32 = 0x6D2B79F5
        for index in 0..<Int(frameCount) {
            let time = Double(index) / sampleRate
            let envelope = exp(-time * preset.decay * (release ? 1.35 : 1))
            let attack = min(1, time / 0.00035)
            random = 1_664_525 &* random &+ 1_013_904_223
            let noise = (Double(random) / Double(UInt32.max) * 2 - 1) * preset.noise
            let baseFrequency = preset.frequency * (release ? 0.72 : 1)
            let pitch = preset == .quack
                ? max(180, baseFrequency - time * 5_200)
                : baseFrequency
            let body = sin(2 * .pi * pitch * time) * 0.55
                + sin(2 * .pi * pitch * 2.4 * time) * 0.18
            channel[index] = Float((body + noise) * envelope * attack)
        }
        return buffer
        }
        self.buffer = makeBuffer(release: false)
        self.releaseBuffer = makeBuffer(release: true)
    }
}

struct KeyboardSoundPackInfo: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

private struct KeyboardSoundPack: @unchecked Sendable {
    struct Clip {
        let press: AVAudioPCMBuffer?
        let release: AVAudioPCMBuffer?
    }
    let name: String
    let directory: URL
    let clips: [UInt16: Clip]
}

/// Imports packs with one audio file. ZIP members are read by name and copied to a
/// generated flat path, never extracted using archive-controlled paths.
private enum KeyboardSoundPackImporter {
    private struct Config: Decodable {
        struct Definition: Decodable { let timing: [[Double]] }
        let name: String?
        let author: String?
        let definition_method: String?
        let audio_file: String?
        let definitions: [String: Definition]?
        let defs: [String: Definition]?
    }

    private static var formats: Set<String> { ["wav", "mp3", "flac", "ogg"] }

    static func isManagedDirectory(_ directory: URL) -> Bool {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("MakiDesk/KeyboardSoundPacks", isDirectory: true).standardizedFileURL
        else { return false }
        let candidate = directory.standardizedFileURL
        return candidate.deletingLastPathComponent() == root && candidate != root
    }

    static func library() -> [KeyboardSoundPackInfo] {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("MakiDesk/KeyboardSoundPacks")
        guard let root, let directories = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        ) else { return [] }
        return directories.compactMap { directory -> KeyboardSoundPackInfo? in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
                  let config = try? JSONDecoder().decode(Config.self, from: data),
                  let name = config.audio_file, !name.contains("/"),
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
            else { return nil }
            return .init(id: directory.path, name: config.name ?? config.author ?? "Imported pack")
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func importArchive(_ archive: URL) throws -> KeyboardSoundPack {
        let hasSecurityScope = archive.startAccessingSecurityScopedResource()
        defer { if hasSecurityScope { archive.stopAccessingSecurityScopedResource() } }
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 100 * 1_024 * 1_024 else {
            throw ImportError.archiveTooLarge
        }
        let names = String(decoding: try unzip(archive, arguments: ["-Z1"], maximumOutput: 200_000), as: UTF8.self)
            .split(whereSeparator: \.isNewline).map(String.init)
        guard names.count <= 500,
              names.allSatisfy(isSafeArchivePath),
              Set(names.map { $0.lowercased() }).count == names.count,
              names.contains("config.json") else { throw ImportError.invalidArchive }

        let configData = try unzip(archive, arguments: ["-p", "config.json"], maximumOutput: 1_000_000)
        let config = try JSONDecoder().decode(Config.self, from: configData)
        guard config.definition_method == "single",
              let audioName = config.audio_file,
              isSafeArchivePath(audioName), names.contains(audioName),
              formats.contains(URL(fileURLWithPath: audioName).pathExtension.lowercased()) else {
            throw ImportError.unsupportedPack
        }
        let audioData = try unzip(archive, arguments: ["-p", audioName], maximumOutput: 100 * 1_024 * 1_024)
        guard audioData.count <= 100 * 1_024 * 1_024 else { throw ImportError.archiveTooLarge }

        let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MakiDesk/KeyboardSoundPacks", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var storedConfig = try JSONSerialization.jsonObject(with: configData) as? [String: Any]
        let audioExtension = URL(fileURLWithPath: audioName).pathExtension.lowercased()
        let storedName = audioExtension == "ogg" ? "audio.wav" : "audio." + audioExtension
        let audioURL = directory.appendingPathComponent(storedName)
        var imported = false
        defer { if !imported { try? FileManager.default.removeItem(at: directory) } }
        if audioExtension == "ogg" {
            try convertOgg(audioData, directory: directory, output: audioURL)
        } else {
            try audioData.write(to: audioURL, options: .atomic)
        }
        storedConfig?["audio_file"] = storedName
        let storedConfigData = try JSONSerialization.data(withJSONObject: storedConfig ?? [:], options: [.sortedKeys])
        try storedConfigData.write(to: directory.appendingPathComponent("config.json"), options: .atomic)
        let licenseName = names.first { $0.lowercased() == "license.txt" }
        if let licenseName, let license = try? unzip(archive, arguments: ["-p", licenseName], maximumOutput: 1_000_000) {
            try license.write(to: directory.appendingPathComponent("LICENSE.txt"), options: .atomic)
        }
        let pack = try loadDirectory(directory)
        imported = true
        return pack
    }

    private static func convertOgg(_ data: Data, directory: URL, output: URL) throws {
        guard let decoder = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { throw ImportError.oggDecoderMissing }
        let input = directory.appendingPathComponent("source.ogg")
        try data.write(to: input, options: .atomic)
        defer { try? FileManager.default.removeItem(at: input) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: decoder)
        process.arguments = ["-nostdin", "-v", "error", "-protocol_whitelist", "file",
                             "-f", "ogg", "-i", input.path, "-map", "0:a:0", "-ac", "1",
                             "-ar", "44100", "-t", "600", "-c:a", "pcm_s16le", output.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ImportError.invalidAudio }
    }

    static func loadDirectory(_ directory: URL) throws -> KeyboardSoundPack {
        let configData = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        let config = try JSONDecoder().decode(Config.self, from: configData)
        guard let audioName = config.audio_file, !audioName.contains("/"),
              formats.contains(URL(fileURLWithPath: audioName).pathExtension.lowercased()) else { throw ImportError.unsupportedPack }
        let audioURL = directory.appendingPathComponent(audioName)
        let file = try AVAudioFile(forReading: audioURL)
        guard file.length > 0, file.length <= 26_460_000,
              file.processingFormat.channelCount <= 8,
              let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length)) else { throw ImportError.invalidAudio }
        try file.read(into: pcm)
        let normalized = try normalize(pcm)
        let sampleRate = normalized.format.sampleRate
        var clips: [UInt16: KeyboardSoundPack.Clip] = [:]
        for (name, definition) in config.definitions ?? config.defs ?? [:] {
            guard let code = keyCodes[name], let first = definition.timing.first,
                  let pressRange = frameRange(first, sampleRate: sampleRate, frameLength: normalized.frameLength),
                  let press = slice(normalized, range: pressRange) else { continue }
            let release: AVAudioPCMBuffer? = definition.timing.count > 1
                ? frameRange(definition.timing[1], sampleRate: sampleRate, frameLength: normalized.frameLength).flatMap { slice(normalized, range: $0) } : nil
            clips[code] = .init(press: press, release: release)
        }
        return KeyboardSoundPack(name: config.name ?? config.author ?? "Imported pack",
                                 directory: directory, clips: clips)
    }

    private struct FrameRange { let start: Int; let end: Int }

    private static func frameRange(_ timing: [Double], sampleRate: Double, frameLength: AVAudioFrameCount) -> FrameRange? {
        guard timing.count == 2, timing[0].isFinite, timing[1].isFinite,
              timing[0] >= 0, timing[1] > timing[0] else { return nil }
        let duration = Double(frameLength) / sampleRate * 1_000
        guard timing[0] < duration else { return nil }
        let start = Int(timing[0] * sampleRate / 1_000)
        let end = Int(min(timing[1], duration, timing[0] + 5_000) * sampleRate / 1_000)
        guard start < Int(frameLength), end > start else { return nil }
        return .init(start: start, end: min(end, Int(frameLength)))
    }

    private static func normalize(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let target = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let converter = AVAudioConverter(from: input.format, to: target) else { throw ImportError.invalidAudio }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * target.sampleRate / input.format.sampleRate))
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw ImportError.invalidAudio }
        var providedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard !providedInput else { inputStatus.pointee = .noDataNow; return nil }
            providedInput = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil else { throw ImportError.invalidAudio }
        return output
    }

    private static func slice(_ source: AVAudioPCMBuffer, range: FrameRange) -> AVAudioPCMBuffer? {
        let count = range.end - range.start
        guard count > 0, let output = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(count)),
              let sourceChannel = source.floatChannelData?[0], let outputChannel = output.floatChannelData?[0] else { return nil }
        output.frameLength = AVAudioFrameCount(count)
        outputChannel.update(from: sourceChannel.advanced(by: range.start), count: count)
        return output
    }

    private static func unzip(_ archive: URL, arguments: [String], maximumOutput: Int) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        if arguments.first == "-p" {
            process.arguments = ["-p", archive.path] + arguments.dropFirst()
        } else {
            process.arguments = arguments + [archive.path]
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readData(ofLength: maximumOutput + 1)
        if data.count > maximumOutput {
            process.terminate()
            process.waitUntilExit()
            throw ImportError.archiveTooLarge
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ImportError.invalidArchive }
        return data
    }

    private enum ImportError: LocalizedError {
        case archiveTooLarge, invalidArchive, unsupportedPack, invalidAudio, oggDecoderMissing

        var errorDescription: String? {
            switch self {
            case .archiveTooLarge: return "the ZIP or expanded WAV exceeds the 100 MiB limit."
            case .invalidArchive: return "the ZIP paths or config.json are invalid."
            case .unsupportedPack: return "choose a Mechvibes pack with one WAV, MP3, FLAC or OGG audio file."
            case .oggDecoderMissing: return "OGG import requires FFmpeg installed via Homebrew."
            case .invalidAudio: return "the audio could not be decoded or converted."
            }
        }
    }

    private static func isSafeArchivePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.contains("*"), !path.contains("?"), !path.contains("[") else { return false }
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    // DOM key names used by Mechvibes mapped to macOS virtual key codes.
    private static let keyCodes: [String: UInt16] = {
        var map: [String: UInt16] = [
            "Escape": 53, "Tab": 48, "Space": 49, "Enter": 36, "Backspace": 51,
            "Delete": 117, "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125,
            "ArrowUp": 126, "ShiftLeft": 56, "ShiftRight": 60, "ControlLeft": 59,
            "ControlRight": 62, "AltLeft": 58, "AltRight": 61, "MetaLeft": 55,
            "MetaRight": 54, "CapsLock": 57, "Backquote": 50, "Minus": 27,
            "Equal": 24, "BracketLeft": 33, "BracketRight": 30, "Backslash": 42,
            "Semicolon": 41, "Quote": 39, "Comma": 43, "Period": 47, "Slash": 44,
            "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97,
            "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111,
            "Home": 115, "End": 119, "PageUp": 116, "PageDown": 121, "Insert": 114,
            "NumLock": 71, "NumpadDecimal": 65, "NumpadMultiply": 67,
            "NumpadAdd": 69, "NumpadDivide": 75, "NumpadSubtract": 78,
            "NumpadEnter": 76
        ]
        let letters: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        for (index, code) in letters.enumerated() { map["Key\(Character(UnicodeScalar(65 + index)!) )"] = code }
        let digits: [UInt16] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (index, code) in digits.enumerated() { map["Digit\(index)"] = code }
        let keypad: [UInt16] = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        for (index, code) in keypad.enumerated() { map["Numpad\(index)"] = code }
        return map
    }()
}
