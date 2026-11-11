import AppKit
import SwiftUI

@MainActor
final class DockerWindowController: NSObject, NSWindowDelegate {
    private let store: DockerStore
    private var window: NSWindow?
    private var saveWorkItem: DispatchWorkItem?

    init(store: DockerStore) {
        self.store = store
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil { build() }
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        store.setWindowVisible(true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        saveFrame()
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        store.setWindowVisible(false)
    }

    func closeWindow() {
        hide()
    }

    func build() {
        let root = DockerRootView(store: store)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Docker"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = store.theme.nsBackground
        window.isOpaque = true
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 900, height: 560)
        window.setContentSize(NSSize(width: 1240, height: 780))
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self

        if let saved = DockerWindowStateStore.load()?.restoredFrame() {
            window.setFrame(saved, display: false)
        } else {
            window.center()
        }
        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        saveFrame()
        store.setWindowVisible(false)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidMove(_ notification: Notification) {
        scheduleSave()
    }

    func windowDidResize(_ notification: Notification) {
        scheduleSave()
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveFrame() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func saveFrame() {
        guard let window else { return }
        DockerWindowStateStore.save(DockerWindowState(frame: window.frame))
    }
}
