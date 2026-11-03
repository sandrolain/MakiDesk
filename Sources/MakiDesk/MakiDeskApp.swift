import AppKit
import SwiftUI

struct MakiDeskApp: App {
    /// The migration from the app's previous name runs before the store reads
    /// its settings and its groups file.
    /// The recording menu follows the controller's phase (T40).
    @State private var recording = ScreenRecordingController.shared

    @State private var store: WorkspaceStore = {
        LegacyMigration.runIfNeeded()
        return WorkspaceStore.shared
    }()

    @State private var system = SystemMonitor.shared

    @NSApplicationDelegateAdaptor(MakiDeskAppDelegate.self) private var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        ExternalApplicationFocus.shared.start()
        WorkspaceStore.shared.start()
        WindowDrag.shared.start()
        ClipboardHistory.shared.start()
        ClipboardHistory.shared.configure(
            keepsImages: WorkspaceStore.shared.clipboardKeepsImages,
            budgetMB: WorkspaceStore.shared.clipboardImageBudgetMB
        )
        // Wires the rejection notice before the first copy, not only when the
        // panel is opened for the first time.
        _ = ClipboardController.shared
        ShelfController.shared.start()
        IdlePerformanceMetrics.shared.start()
        SystemMonitor.shared.start()
        UtilityBarController.shared.start()
    }

    /// A menu item whose shortcut text sits after the title. The menu has no
    /// key equivalents of its own: the global Carbon hot key is the trigger,
    /// so the text is a reminder, not a second handler.
    private func menuAction(
        _ title: String,
        _ action: WindowController.ShortcutAction,
        icon: String? = nil
    ) -> some View {
        menuButton(title, keys: shortcutKeys(action), icon: icon) {
            store.applyShortcut(action)
        }
    }

    /// The keys a menu row shows, read from the table in force: a remapped
    /// shortcut is reflected as soon as the store changes (T53).
    private func shortcutKeys(_ action: WindowController.ShortcutAction) -> String? {
        ShortcutManager.display(for: action, bindings: store.shortcutBindings)
    }

    private func menuButton(
        _ title: String,
        keys: String? = nil,
        icon: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if let icon {
                if let keys {
                    Label("\(title)    \(keys)", systemImage: icon)
                } else {
                    Label(title, systemImage: icon)
                }
            } else if let keys {
                Text("\(title)    \(keys)")
            } else {
                Text(title)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            Text(store.status)
                .font(.caption)
            Text(system.diskMenuLine)
                .font(.caption)
            Text(system.cpuMenuLine)
                .font(.caption)
            Divider()

            // The four panels are one click away; everything else lives in a
            // menu with a single level of nesting.
            menuButton("Search Windows", keys: shortcutKeys(.searchWindows), icon: "magnifyingglass") {
                store.applyShortcut(.searchWindows)
            }
            menuButton("Notes", keys: shortcutKeys(.toggleNotes), icon: "note.text") {
                NotesController.shared.show()
            }
            menuButton("Clipboard History", keys: shortcutKeys(.clipboardHistory), icon: "doc.on.clipboard") {
                ClipboardController.shared.toggle()
            }
            menuButton("Shelf", keys: shortcutKeys(.toggleShelf), icon: "tray.and.arrow.down") {
                ShelfController.shared.toggle()
            }
            menuButton(store.checklistVisible ? "Hide Checklist" : "Show Checklist",
                       keys: shortcutKeys(.toggleChecklist),
                       icon: "checklist") {
                store.updateChecklistVisible(!store.checklistVisible)
            }
            menuButton("Utility Bar", keys: shortcutKeys(.toggleUtilityBar),
                       icon: "rectangle.topthird.inset.filled") {
                store.applyShortcut(.toggleUtilityBar)
            }
            Menu {
                // No remaining time in these titles: a title that changed every
                // second rebuilt the open menu and closed it under the pointer.
                let timers = TimerController.shared.listedTimers
                if timers.isEmpty {
                    Button("No timers") {}.disabled(true)
                }
                ForEach(timers) { timer in
                    Menu(timer.isPaused ? "\(timer.label) (paused)" : timer.label) {
                        Button(timer.isPaused ? "Resume" : "Pause") {
                            timer.isPaused
                                ? TimerController.shared.resume(timer.id)
                                : TimerController.shared.pause(timer.id)
                        }
                        Button("Delete") { TimerController.shared.remove(timer.id) }
                    }
                }
                Divider()
                ForEach(TimerSettings.quickStarts) { quick in
                    menuButton(quick.title) {
                        TimerInputController.shared.show(
                            prefill: TimerText.duration(quick.seconds)
                        )
                    }
                }
                Divider()
                menuButton("New Timer…", keys: shortcutKeys(.newTimer), icon: "timer") {
                    TimerInputController.shared.show()
                }
            } label: {
                Label("Timers", systemImage: "timer")
            }
            menuButton("Capture Area…", keys: shortcutKeys(.captureScreenshot),
                       icon: "camera.viewfinder") {
                ScreenshotAnnotationController.shared.capture()
            }
            menuButton("Capture Window…", keys: shortcutKeys(.captureWindow),
                       icon: "macwindow") {
                ScreenshotAnnotationController.shared.captureWindow()
            }
            menuButton("Capture Screen…", keys: shortcutKeys(.captureScreen),
                       icon: "display") {
                ScreenshotAnnotationController.shared.captureScreen()
            }
            if recording.isRecording {
                menuButton(recording.phase == .paused ? "Resume Recording" : "Pause Recording",
                           icon: "pause.circle") {
                    recording.togglePause()
                }
                menuButton("Stop Recording", keys: shortcutKeys(.recordArea),
                           icon: "stop.circle") {
                    recording.stop()
                }
            } else {
                menuButton("Record Area…", keys: shortcutKeys(.recordArea),
                           icon: "record.circle") {
                    recording.toggle()
                }
            }
            menuButton("Screenshots", keys: shortcutKeys(.openScreenshots),
                       icon: "menubar.dock.rectangle") {
                ScreenshotLibraryController.shared.show()
            }

            Menu {
                let coordinator = DropzoneCoordinator.shared
                let _ = coordinator.reloadIfNeeded()
                if coordinator.zones.isEmpty {
                    Text("No dropzones yet")
                }
                ForEach(coordinator.zones) { zone in
                    menuButton(zone.name.isEmpty ? "Untitled dropzone" : zone.name,
                               icon: zone.icon.symbolName) {
                        ShelfController.shared.runSelectedDropzone(zone)
                    }
                    .disabled(zone.enabled == false
                              || coordinator.snapshot.isRunnable == false
                              || ShelfController.shared.hasSelection == false)
                }
                Divider()
                menuButton("Dropzones…", icon: "bolt.square") {
                    // The Settings tab is persisted: select it before opening.
                    UserDefaults.standard.set(SettingsView.SettingsTab.dropzones.rawValue,
                                              forKey: SettingsView.SettingsTab.defaultsKey)
                    SettingsController.shared.show()
                }
            } label: {
                Label("Dropzones", systemImage: "bolt.square")
            }

            Divider()

            Menu {
                menuAction("Left column", .leftHalf, icon: "rectangle.lefthalf.inset.filled")
                menuAction("Right column", .rightHalf, icon: "rectangle.righthalf.inset.filled")
                menuAction("Top row", .topHalf, icon: "rectangle.tophalf.inset.filled")
                menuAction("Bottom row", .bottomHalf, icon: "rectangle.bottomhalf.inset.filled")
                Divider()
                menuAction("Top Left", .topLeft)
                menuAction("Top Right", .topRight)
                menuAction("Bottom Left", .bottomLeft)
                menuAction("Bottom Right", .bottomRight)
                Divider()
                menuAction("Center / Full / Golden", .centerCycle)
                menuAction("Center", .center)
                menuAction("Golden Ratio (Phi)", .phi)
                menuAction("Toggle Full Screen", .toggleFullScreen)
                menuAction("Minimize", .minimize)
                Divider()
                menuButton(
                    store.focusBorderEnabled ? "Hide Focus Border" : "Show Focus Border",
                    keys: shortcutKeys(.toggleFocusBorder),
                    icon: "rectangle.dashed"
                ) {
                    store.updateFocusBorderEnabled(!store.focusBorderEnabled)
                }
                menuButton(
                    store.focusDimEnabled ? "Stop Focus Dim" : "Focus Dim — dim everything else",
                    keys: shortcutKeys(.toggleFocusDim),
                    icon: "circle.lefthalf.filled"
                ) {
                    store.updateFocusDimEnabled(!store.focusDimEnabled)
                }
                menuButton(
                    store.showMiniMap ? "Hide Mini Map" : "Show Mini Map",
                    keys: shortcutKeys(.toggleMiniMap),
                    icon: "rectangle.inset.filled"
                ) {
                    store.updateMiniMapVisibility(!store.showMiniMap)
                }
            } label: {
                Label("Window", systemImage: "macwindow")
            }

            Menu {
                menuAction("Grid — every window in view", .gridLayout)
                menuAction("Golden spiral — every window in view", .spiralLayout)
                menuAction("Suggested layout", .suggestLayout)
                menuAction("Content-weighted", .contentLayout,
                           icon: "rectangle.3.group")
                Divider()
                menuButton("Grid — selected windows") {
                    store.tileOnScreen(gap: store.gap, selection: store.lastLayoutSelection)
                }
                .disabled(store.lastLayoutSelection.isEmpty)
                menuButton("Golden spiral — selected windows") {
                    store.autoLayout(selection: store.lastLayoutSelection)
                }
                .disabled(store.lastLayoutSelection.isEmpty)
                menuButton("Suggested layout — selected windows") {
                    store.suggestLayout(selection: store.lastLayoutSelection)
                }
                .disabled(store.lastLayoutSelection.isEmpty)
                menuButton("Content — selected windows") {
                    store.contentLayout(selection: store.lastLayoutSelection)
                }
                .disabled(store.lastLayoutSelection.count < 3)
                if let advice = store.pendingLayout {
                    Divider()
                    menuButton("Apply Suggested Layout (\(advice.layout.label))",
                               keys: shortcutKeys(.applySuggestedLayout)) {
                        store.acceptPendingLayout()
                    }
                    menuButton("Dismiss Suggested Layout") {
                        store.dismissPendingLayout()
                    }
                }
            } label: {
                Label("Layout", systemImage: "square.grid.2x2")
            }

            Menu {
                if let scene = store.sceneTitle {
                    Text("In use: \(scene)")
                    if store.activeGroupSlot != nil {
                        menuButton("Leave Group",
                                   keys: shortcutKeys(.leaveGroup)) {
                            store.leaveGroup()
                        }
                    }
                    Divider()
                }
                // One flat list to recall a group; three management submenus
                // replace the nine nested ones.
                ForEach(1...9, id: \.self) { slot in
                    menuButton(store.groupMenuLabel(slot),
                               keys: shortcutKeys(.recallGroup(slot))) {
                        store.recallGroup(slot: slot)
                    }
                    .disabled(store.groupIsEmpty(slot))
                }
                Divider()
                Menu("Add Front Window to Group") {
                    ForEach(1...9, id: \.self) { slot in
                        menuButton(store.groupMenuLabel(slot),
                                   keys: shortcutKeys(.assignToGroup(slot))) {
                            store.toggleGroupMembership(slot: slot)
                        }
                    }
                }
                Menu("Rename Group…") {
                    ForEach(1...9, id: \.self) { slot in
                        menuButton(store.groupMenuLabel(slot)) {
                            GroupRenamePrompt.present(slot: slot, store: store)
                        }
                    }
                }
                Menu("Empty Group") {
                    ForEach(1...9, id: \.self) { slot in
                        menuButton(store.groupMenuLabel(slot)) {
                            store.clearGroup(slot: slot)
                        }
                        .disabled(store.groupIsEmpty(slot))
                    }
                }
            } label: {
                Label("Groups", systemImage: "rectangle.3.group")
            }

            Menu {
                Text(store.sceneTitle.map { "In use: \($0)" } ?? "Nothing in use")
                Divider()
                menuButton("Focus Selected Windows",
                           keys: shortcutKeys(.focusSelection)) {
                    store.focus(on: store.lastLayoutSelection)
                }
                .disabled(store.lastLayoutSelection.isEmpty)
                menuAction("Send Front Window Away", .putAwayFront)
                Divider()
                menuAction("Everything Back", .showEverything)
                menuAction("Undo One Step", .undoStep)
            } label: {
                Label("Focus", systemImage: "scope")
            }

            Menu {
                menuButton("Designate Front Window",
                           keys: shortcutKeys(.peekDesignate)) {
                    store.togglePeekDesignation()
                }
                menuButton("Clear Peek (bring the window back)",
                           keys: shortcutKeys(.clearPeek)) {
                    store.clearPeek()
                }
                .disabled(store.peekName == nil)
                Divider()
                Text(store.peekName.map { "\($0) is put away · hold ⌃⌥H to peek at it" }
                     ?? "Hold ⌃⌥H to peek · nothing designated")
            } label: {
                Label("Peek", systemImage: "eye")
            }

            Menu {
                menuButton("Recognize Text from Selected Area", keys: shortcutKeys(.recognizeText),
                           icon: "text.viewfinder") {
                    TextRecognitionController.shared.recognizeArea(
                        options: store.textRecognitionOptions,
                        output: store.ocrOutput,
                        reveal: store.ocrRevealHistory
                    )
                }
                // The same service, without dragging over the screen (T41).
                menuButton("Recognize Text from the Window Under the Pointer",
                           icon: "macwindow") {
                    TextRecognitionController.shared.recognize(.windowUnderPointer)
                }
                menuButton("Recognize Text from the Frontmost Window",
                           icon: "macwindow.on.rectangle") {
                    TextRecognitionController.shared.recognize(.frontmostWindow)
                }
                menuButton("Recognize Text from the Whole Screen",
                           icon: "rectangle.dashed") {
                    TextRecognitionController.shared.recognize(.wholeScreen)
                }
                menuButton("Recognize Text from the Copied Image",
                           icon: "photo.on.rectangle.angled") {
                    TextRecognitionController.shared.recognizeCopiedImage()
                }
                menuButton("Recognize Text from a Screenshot…", icon: "photo") {
                    ScreenshotLibraryController.shared.show()
                }
                menuButton("Pick a Color from the Screen", keys: shortcutKeys(.sampleColor),
                           icon: "eyedropper") {
                    ColorSamplerController.shared.sample()
                }
                Divider()
                Text("Text goes to the clipboard; the colour uses the format chosen in Settings. Everything runs locally.")
            } label: {
                Label("Text & Color", systemImage: "text.viewfinder")
            }

            Menu {
                menuButton("Measure an Area…", keys: shortcutKeys(.measureArea), icon: "ruler") {
                    MeasureController.shared.start()
                }
                menuButton("Clear Measurements", icon: "xmark.circle") {
                    MeasureController.shared.clear()
                }
                .disabled(MeasureController.shared.measurementCount == 0)
                Divider()
                Picker("Units", selection: Binding(
                    get: { MeasurementSettings.unit() },
                    set: { MeasurementSettings.setUnit($0) }
                )) {
                    ForEach(MeasurementUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                Divider()
                Text("Drag over any app; Esc cancels. Values snap to windows and displays.")
            } label: {
                Label("Measure", systemImage: "ruler")
            }

            Menu {
                Text(system.diskMenuLine)
                if let detail = system.diskDetailLine {
                    Text(detail)
                }
                Button(system.diskMenuBarMode == .never
                       ? "Show Free Space in Menu Bar"
                       : "Hide Free Space from Menu Bar") {
                    system.updateDiskMenuBarMode(system.diskMenuBarMode == .never
                                                 ? .always : .never)
                }
                Button("Refresh Disk Now") { system.refreshDiskNow() }
                Button("Open Storage Settings…") { system.openStorageSettings() }
                Divider()
                if system.cpuAlertsEnabled {
                    Text(system.cpuMenuLine)
                    ForEach(Array(system.topProcesses.prefix(3))) { process in
                        Text("\(process.name) · \(process.percentText)")
                    }
                    if system.topProcesses.isEmpty {
                        Text("No process above \(Int(system.cpuThresholdPercent))% right now")
                    }
                    Button("Open Activity Monitor…") { system.openActivityMonitor() }
                } else {
                    Text("CPU alerts are off")
                    Button("Turn On CPU Alerts") { system.updateCPUAlertsEnabled(true) }
                }
                Divider()
                Button("Ports…") { store.applyShortcut(.openPorts) }
                Divider()
                Button("MakiDesk Settings…") { openSystemSettingsTab() }
            } label: {
                Label("System", systemImage: "gauge")
            }

            Divider()

            menuButton("Keyboard Shortcuts…",
                       keys: shortcutKeys(.openKeyboardShortcuts),
                       icon: "keyboard") {
                ShortcutsWindowController.shared.show()
            }
            menuButton("Run a Command…", keys: shortcutKeys(.runCommand),
                       icon: "command") {
                CommandBoxController.shared.show()
            }
            menuButton("Notification History…", icon: "bell") {
                NotificationHistoryController.shared.show()
            }
            menuButton("Dismiss All Notices", icon: "bell.slash") {
                HUDController.shared.hide()
            }
            .disabled(!HUDController.shared.hasNotices)
            menuButton("Settings…", keys: shortcutKeys(.openSettings),
                       icon: "gearshape") {
                store.applyShortcut(.openSettings)
            }
            Divider()
            menuButton("Quit MakiDesk", icon: "power") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            if recording.isRecording {
                // A recording must never be forgotten: the icon itself changes.
                Image(systemName: recording.phase == .paused ? "pause.circle" : "record.circle")
                    .accessibilityLabel("MakiDesk — recording")
            } else {
                HStack(spacing: 4) {
                    Image(nsImage: MenuBarIcon.image())
                    if let disk = system.menuBarDiskText {
                        Text(disk)
                            .monospacedDigit()
                            .foregroundStyle(system.isDiskLow ? Color.orange : Color.primary)
                    }
                }
                .accessibilityLabel(system.menuBarAccessibilityLabel)
                .onAppear(perform: openSetupOnFirstRun)
            }
        }
    }

    /// Opens Settings on the System page from the menu's deep link.
    private func openSystemSettingsTab() {
        UserDefaults.standard.set(SettingsView.SettingsTab.system.rawValue,
                                  forKey: SettingsView.SettingsTab.defaultsKey)
        SettingsController.shared.show()
    }

    /// The first launch opens Settings, where the permissions are explained.
    private func openSetupOnFirstRun() {
        guard !Self.didAttemptFirstRun else { return }
        guard !UserDefaults.standard.bool(forKey: SettingsKey.setupCompleted.rawValue) else { return }
        Self.didAttemptFirstRun = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            MakiLog.app.notice("FirstRun: opening setup window")
            SettingsController.shared.show()
        }
    }

    private static var didAttemptFirstRun = false
}

/// Notes are written while the user types, but the session (tabs, cursors,
/// window frame) and the clean-close marker are flushed here, together with
/// any debounce still in flight (T20).
final class MakiDeskAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            NotesStore.shared.flushIfNeeded(cleanClose: true)
            TimerController.shared.shutdown()
            ChecklistStore.shared.flushBlocking()
            ShelfController.shared.shutdown()
            ScreenshotLibraryController.shared.shutdown()
        }
    }
}
