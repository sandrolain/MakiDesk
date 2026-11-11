import AppKit

@main
enum DockerMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = DockerAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}