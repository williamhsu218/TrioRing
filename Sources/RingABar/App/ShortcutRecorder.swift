import AppKit

@MainActor
final class ShortcutRecorder {
    private let globalShortcut: GlobalShortcutController
    private let targetWindow: () -> NSWindow?
    private var monitor: Any?
    private var pressedModifiers = false
    private var sawKey = false

    init(globalShortcut: GlobalShortcutController, targetWindow: @escaping () -> NSWindow?) {
        self.globalShortcut = globalShortcut
        self.targetWindow = targetWindow
    }

    func begin() {
        guard targetWindow()?.isKeyWindow == true, monitor == nil else { return }
        globalShortcut.beginRecording()
        guard globalShortcut.isRecording else { return }
        pressedModifiers = false
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                self?.consume(event) ?? false
            }
            return consumed ? nil : event
        }
        if monitor == nil { cancel() }
    }

    func cancel() {
        removeMonitor()
        globalShortcut.cancelRecording()
    }

    func stop() {
        removeMonitor()
    }

    private func consume(_ event: NSEvent) -> Bool {
        guard globalShortcut.isRecording, let window = targetWindow() else { return false }
        if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown
            || event.window !== window {
            cancel()
            return false
        }

        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.type == .flagsChanged {
            if modifiers.isEmpty {
                if pressedModifiers && !sawKey { globalShortcut.record(nil) }
                pressedModifiers = false
                sawKey = false
            } else {
                pressedModifiers = true
            }
            return true
        }

        guard !event.isARepeat else { return true }
        sawKey = !modifiers.isEmpty
        if event.keyCode == 53 && modifiers.isEmpty {
            cancel()
        } else {
            globalShortcut.record(StatusPanelShortcut(event: event))
            if !globalShortcut.isRecording { removeMonitor() }
        }
        return true
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pressedModifiers = false
        sawKey = false
    }
}
