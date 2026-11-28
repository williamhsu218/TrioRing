import AppKit
import OSLog
import SwiftUI

@MainActor
final class SettingsWindowCoordinator: NSObject, NSWindowDelegate {
    private let preferences: Preferences
    private let store: StatusStore
    private let audio: AudioMonitor
    private let batteryActions: BatteryActions
    private let wifiAccess: WiFiLocationAccess
    private let globalShortcut: GlobalShortcutController
    private let updaterState: UpdaterState
    private let logger = AppIdentity.logger(category: "Status")
    private var windowController: NSWindowController?
    private lazy var shortcutRecorder = ShortcutRecorder(globalShortcut: globalShortcut) { [weak self] in
        self?.windowController?.window
    }

    init(
        preferences: Preferences,
        store: StatusStore,
        audio: AudioMonitor,
        batteryActions: BatteryActions,
        wifiAccess: WiFiLocationAccess,
        globalShortcut: GlobalShortcutController,
        updaterState: UpdaterState
    ) {
        self.preferences = preferences
        self.store = store
        self.audio = audio
        self.batteryActions = batteryActions
        self.wifiAccess = wifiAccess
        self.globalShortcut = globalShortcut
        self.updaterState = updaterState
    }

    var isVisible: Bool {
        windowController?.window?.isVisible == true
    }

    func show(_ section: SettingsCategory? = nil) {
        if let section {
            shortcutRecorder.cancel()
            store.settingsCategory = section
        }
        if store.settingsCategory == .icon && (section == .icon || windowController?.window?.isVisible != true) {
            store.settingsIconLeaf = .overall
        }
        if windowController == nil {
            let hosting = NSHostingController(rootView: SettingsView(
                preferences: preferences,
                store: store,
                audio: audio,
                batteryActions: batteryActions,
                wifiAccess: wifiAccess,
                globalShortcut: globalShortcut,
                onRecordShortcut: { [weak self] in self?.shortcutRecorder.begin() },
                onCancelShortcut: { [weak self] in self?.shortcutRecorder.cancel() },
                automaticallyChecksForUpdates: Binding(
                    get: { [updaterState] in updaterState.automaticallyChecksForUpdates },
                    set: { [updaterState] in updaterState.setAutomaticallyChecksForUpdates($0) }
                )
            ))
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.contentMinSize = SettingsView.windowSize
            window.title = String(localized: "TrioRing Settings")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(SettingsView.windowSize)
            if !window.setFrameUsingName("TrioRingSettings") { window.center() }
            window.setFrameAutosaveName("TrioRingSettings")
            window.setAccessibilityIdentifier("RingABar.settingsWindow")
            windowController = NSWindowController(window: window)
        }
        store.settingsVisible = true
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        logger.notice("Settings opened")
    }

    func stop() {
        shortcutRecorder.stop()
    }

    func windowDidResignKey(_ notification: Notification) {
        shortcutRecorder.cancel()
    }

    func windowWillClose(_ notification: Notification) {
        shortcutRecorder.cancel()
        store.settingsVisible = false
    }
}
