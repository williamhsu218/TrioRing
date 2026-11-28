import AppKit
import Carbon
import OSLog
import Sparkle
import SwiftUI

@main
@MainActor
struct TrioRingApp {
    private static let controller = AppController()

    static func main() {
        let app = NSApplication.shared
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
private final class AppController: NSObject, NSApplicationDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private let store = StatusStore()
    private let preferences = Preferences()
    private let batteryActions = BatteryActions()
    private let wifiAccess = WiFiLocationAccess()
    private let panel = AnchoredPanel()
    private var panelHeights: [PanelLayout: CGFloat] = [:]
    private var pendingPanelFit: Task<Void, Never>?
    private var latestPanelFit: PanelFitRequest?
    private let accentView = StatusIconAccentView()
    private var accentSizeConstraints: [NSLayoutConstraint] = []
    private var iconPowerTask: Task<Void, Never>?
    private var iconTelemetrySource: MiddleIconSource?
    private let logger = AppIdentity.logger(category: "Status")
    private var item: NSStatusItem?
    private var lastIcon: StatusIcon?
    private var fallbackTimer: Timer?
    private var isSystemAsleep = false
    private var isScreenAsleep = false
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?
    private var powerObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var hostingController: NSHostingController<StatusPanel>?
    private lazy var updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
    private lazy var updaterState = UpdaterState(updater: updater.updater)
    private let updateBadge = StatusIconAccentView()

    private lazy var volumeScroll = VolumeScrollController(
        store: store, preferences: preferences, audio: audio, panel: panel
    )

    private lazy var globalShortcut = GlobalShortcutController(preferences: preferences, backend: CarbonShortcutBackend()) { [weak self] in
        self?.togglePanelFromShortcut()
    }

    private lazy var settingsCoordinator = SettingsWindowCoordinator(
        preferences: preferences,
        store: store,
        audio: audio,
        batteryActions: batteryActions,
        wifiAccess: wifiAccess,
        globalShortcut: globalShortcut,
        updaterState: updaterState
    )

    private lazy var battery = BatteryMonitor { [weak self] status in
        self?.updateBattery(status)
    }
    private lazy var network = NetworkMonitor { [weak self] status in
        DispatchQueue.main.async { self?.updateNetwork(status) }
    }
    private lazy var audio = AudioMonitor { [weak self] status in
        DispatchQueue.main.async { self?.updateAudio(status) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "TrioRing"
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.setAccessibilityIdentifier("RingABar.statusItem")
            accentView.imageScaling = .scaleNone
            accentView.setAccessibilityElement(false)
            accentView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(accentView)
            let size = CGFloat(preferences.icon.menuBarSize)
            accentSizeConstraints = [
                accentView.widthAnchor.constraint(equalToConstant: size),
                accentView.heightAnchor.constraint(equalToConstant: size)
            ]
            NSLayoutConstraint.activate(accentSizeConstraints + [
                accentView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                accentView.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])
            updateBadge.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
            updateBadge.contentTintColor = .systemBlue
            updateBadge.isHidden = true
            updateBadge.setAccessibilityElement(false)
            updateBadge.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(updateBadge)
            NSLayoutConstraint.activate([
                updateBadge.widthAnchor.constraint(equalToConstant: 6),
                updateBadge.heightAnchor.constraint(equalToConstant: 6),
                updateBadge.centerXAnchor.constraint(equalTo: accentView.trailingAnchor),
                updateBadge.centerYAnchor.constraint(equalTo: accentView.topAnchor, constant: 3)
            ])
        }
        self.item = item
        updater.startUpdater()
        _ = updaterState
        preferences.onIconChange = { [weak self] in
            guard let self else { return }
            if self.iconTelemetrySource != self.preferences.icon.middleSource {
                self.refreshIconTelemetry()
                self.scheduleFallbackTimer()
            }
            self.refreshIcon()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParametersChanged(_:)),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleInputSourceChanged() }
        }

        let hostingController = NSHostingController(rootView: StatusPanel(
            store: store,
            preferences: preferences,
            network: network,
            audio: audio,
            batteryActions: batteryActions,
            wifiAccess: wifiAccess,
            onVolume: { [weak self] value, device in self?.volumeScroll.scheduleVolume(value, on: device) },
            onMute: { [weak self] muted, device in self?.audio.setMuted(muted, on: device) },
            onClose: { [weak self] in self?.closePanel() },
            onSettings: { [weak self] in self?.openSettings() },
            onBatterySettings: { [weak self] in self?.showSettings(.battery) },
            onNetworkSettings: { [weak self] in self?.showSettings(.network) },
            onAudioSettings: { [weak self] in self?.showSettings(.audio) },
            onAbout: { [weak self] in
                self?.closePanel()
                NSApp.orderFrontStandardAboutPanel(nil)
                NSApp.activate()
            },
            onCheckForUpdates: { [weak self] in self?.checkForUpdates() },
            onHeight: { [weak self] layout, presentation, height, ready in
                self?.requestPanelFit(layout: layout, presentation: presentation, height: height, ready: ready)
            },
            onQuit: { NSApplication.shared.terminate(nil) },
            onSystemSettings: { [weak self] pane in
                self?.closePanel()
                NSWorkspace.shared.open(pane.url)
            }
        ))
        hostingController.sizingOptions = []
        self.hostingController = hostingController
        panel.host(hostingController.view)

        updateMaximumIconSize()
        refreshIconTelemetry()
        refreshIcon()
        battery.start()
        batteryActions.startCalibrationObservation()
        network.start()
        audio.start()
        globalShortcut.start()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self, selector: #selector(willSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil
        )
        workspaceCenter.addObserver(
            self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil
        )
        workspaceCenter.addObserver(
            self, selector: #selector(screensDidSleep(_:)), name: NSWorkspace.screensDidSleepNotification, object: nil
        )
        workspaceCenter.addObserver(
            self, selector: #selector(screensDidWake(_:)), name: NSWorkspace.screensDidWakeNotification, object: nil
        )
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.battery.refresh()
                self.batteryActions.refreshPowerModes(pluggedIn: self.store.battery.reading?.pluggedIn)
            }
        }
        scheduleFallbackTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        iconPowerTask?.cancel()
        if let inputSourceObserver { DistributedNotificationCenter.default().removeObserver(inputSourceObserver) }
        NotificationCenter.default.removeObserver(self)
        volumeScroll.cancel()
        settingsCoordinator.stop()
        globalShortcut.stop()
        removePanelEventMonitors()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
        battery.stop()
        batteryActions.stopCalibrationObservation()
        network.stop()
        audio.stop()
    }

    @objc private func statusItemClicked() {
        logger.info("Status item activated")
        if NSApp.currentEvent?.type == .rightMouseUp {
            openContextMenu()
            return
        }
        if panel.isVisible {
            closePanel()
        } else {
            showPanel(click: NSEvent.mouseLocation)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if settingsCoordinator.isVisible {
            openSettings()
        } else {
            showPanel()
        }
        return false
    }

    private func togglePanelFromShortcut() {
        if panel.isVisible {
            closePanel()
            return
        }
        guard let button = item?.button, button.window != nil else {
            logger.debug("No status item window for the panel shortcut")
            return
        }
        showPanel()
        NSApp.activate()
    }

    private func showPanel(click: NSPoint? = nil) {
        guard !panel.isVisible, let button = item?.button else { return }
        store.audioExpanded = preferences.opensWithExpandedAudio
        refreshStatus()
        panel.anchor(under: button, click: click)
        prepareSummaryHeight()
        // Request another measurement even when the natural height matches
        // the last layout SwiftUI performed while the panel was hidden.
        store.panelPresentation &+= 1
        store.panelVisible = true
        panel.presentFromStatusItem()
        // Leave the first move to Tab or a click. Space on a newly opened
        // panel must not activate a control selected by a previous session.
        panel.makeFirstResponder(nil)
        installPanelEventMonitors()
    }

    private func prepareSummaryHeight() {
        let height = panelHeights[.summary(audioExpanded: store.audioExpanded)]
            ?? panelHeights[.summary(audioExpanded: false)] ?? AnchoredPanel.initialSummaryHeight
        panel.fit(height: height)
    }

    private func requestPanelFit(layout: PanelLayout, presentation: UInt64, height: CGFloat, ready: Bool) {
        let request = PanelFitRequest(layout: layout, presentation: presentation, height: height, ready: ready)
        guard request.matches(layout: store.panelLayout, presentation: store.panelPresentation) else { return }
        if !panel.isVisible {
            if ready, case .summary = layout { panelHeights[layout] = height }
            return
        }

        latestPanelFit = request
        guard pendingPanelFit == nil else { return }
        pendingPanelFit = Task { @MainActor [weak self] in
            // Coalesce this layout pass, not a fixed 16/225 ms loading delay.
            // An outgoing page may still report geometry during its transition;
            // validate both its layout and presentation again before applying.
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.pendingPanelFit = nil
            guard self.panel.isVisible, let fit = self.latestPanelFit,
                  fit.matches(layout: self.store.panelLayout, presentation: self.store.panelPresentation) else { return }
            if fit.ready { self.panelHeights[fit.layout] = fit.height }
            if let height = fit.targetHeight(currentHeight: self.panel.frame.height,
                                             wifiFeedbackVisible: self.store.wifiConnection.phase != .idle) {
                self.panel.fit(height: height, animated: true)
            }
        }
    }

    private func installPanelEventMonitors() {
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
            let consume = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .scrollWheel { return self.volumeScroll.handleScroll(event) }
                if event.type == .keyDown {
                    if event.keyCode == 53, self.store.batteryInfoVisible,
                       event.window === self.panel || event.window?.parent === self.panel {
                        self.store.batteryInfoVisible = false
                        return true
                    }
                    guard event.window === self.panel, self.panel.attachedSheet == nil else { return false }
                    if event.keyCode == 48, self.panel.firstResponder === self.panel,
                       event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                       let hostingController = self.hostingController {
                        // Hand the first Tab to SwiftUI, which owns the key-view loop.
                        self.panel.makeFirstResponder(hostingController.view)
                    }
                    if event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command {
                        if event.charactersIgnoringModifiers == "," {
                            self.openSettings()
                            return true
                        }
                        if event.charactersIgnoringModifiers == "[", self.store.page != .summary {
                            self.store.navigate(to: .summary, fromKeyboard: true)
                            return true
                        }
                    }
                    guard event.keyCode == 53 else { return false }
                    self.closePanel()
                    return true
                }
                if event.window !== self.panel, event.window?.sheetParent !== self.panel,
                   event.window?.parent !== self.panel {
                    self.dismissIfOutside()
                }
                return false
            }
            return consume ? nil : event
        }
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.dismissIfOutside() }
        }
        logger.notice("Panel opened")
    }

    private func openContextMenu() {
        let location = NSEvent.mouseLocation
        closePanel()
        let menu = NSMenu()
        let settings = menu.addItem(withTitle: String(localized: "Settings…"),
                                    action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let updates = menu.addItem(withTitle: String(localized: "Check for Updates…"),
                                   action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        updates.isEnabled = updaterState.canCheckForUpdates
        menu.autoenablesItems = false
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: String(localized: "Quit TrioRing"), action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        // AppKit can mirror the status item across displays. Anchor the menu to
        // the pointer on the display that received the click.
        menu.popUp(positioning: nil, at: location, in: nil)
    }

    @objc private func openSettings() { showSettings() }

    @objc private func checkForUpdates() {
        guard updaterState.canCheckForUpdates else { return }
        closePanel()
        NSApp.activate()
        updater.checkForUpdates(nil)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else { return }
        updateBadge.isHidden = false
        item?.button?.setAccessibilityHelp(String(localized: "A TrioRing update is available."))
        item?.button?.toolTip = String(localized: "A TrioRing update is available.")
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        clearUpdateBadge()
    }

    func standardUserDriverWillFinishUpdateSession() {
        clearUpdateBadge()
    }

    private func clearUpdateBadge() {
        updateBadge.isHidden = true
        item?.button?.setAccessibilityHelp(nil)
        item?.button?.toolTip = nil
    }

    private func showSettings(_ section: SettingsCategory? = nil) {
        closePanel()
        settingsCoordinator.show(section)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        pendingPanelFit?.cancel()
        pendingPanelFit = nil
        latestPanelFit = nil
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        store.panelVisible = false
        store.batteryInfoVisible = false
        store.batteryReadingsExpanded = false
        store.inputDevicesExpanded = true
        store.audioDirection = .output
        store.showsAllSummaryOutputs = false
        store.pointerOverOutputSlider = false
        store.connectionDisclosureOverride = nil
        store.showsMoreConnectionDetails = false
        store.navigate(to: .summary)
        store.audioExpanded = preferences.opensWithExpandedAudio
        // Resize while hidden as well so the next order-front never presents
        // the window's previous expanded frame.
        prepareSummaryHeight()
        removePanelEventMonitors()
        logger.notice("Panel closed")
    }

    func applicationDidResignActive(_ notification: Notification) {
        // SwiftUI's information popover can temporarily activate the app and
        // then hand focus back. The normal outside-click monitors still apply.
        if store.batteryInfoVisible || ProcessInfo.processInfo.systemUptime - store.batteryInfoFocusChange < 0.4 {
            return
        }
        if !pointerIsOverStatusItem { closePanel() }
    }

    private func dismissIfOutside() {
        let point = NSEvent.mouseLocation
        if pointerIsOverStatusItem { return }
        if panel.frame.contains(point) || panel.childWindows?.contains(where: { $0.isVisible && $0.frame.contains(point) }) == true {
            return
        }
        closePanel()
    }

    private var pointerIsOverStatusItem: Bool {
        guard let button = item?.button, let window = button.window else { return false }
        let point = NSEvent.mouseLocation
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        if rect.contains(point) { return true }
        guard let source = window.screen, let target = NSScreen.screens.first(where: { $0.frame.contains(point) }) else { return false }
        return rect.offsetBy(dx: target.frame.maxX - source.frame.maxX,
                             dy: target.frame.maxY - source.frame.maxY).contains(point)
    }

    private func removePanelEventMonitors() {
        if let localEventMonitor { NSEvent.removeMonitor(localEventMonitor) }
        if let globalEventMonitor { NSEvent.removeMonitor(globalEventMonitor) }
        localEventMonitor = nil
        globalEventMonitor = nil
    }

    private func scheduleFallbackTimer() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        guard !isSystemAsleep && !isScreenAsleep else { return }
        let needsLivePower = preferences.icon.middleSource == .power
        let interval: TimeInterval = needsLivePower ? 20 : 60
        let tolerance: TimeInterval = needsLivePower ? 3 : 10
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStatus() }
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    @objc private func willSleep(_ notification: Notification) {
        isSystemAsleep = true
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    @objc private func didWake(_ notification: Notification) {
        isSystemAsleep = false
        isScreenAsleep = false
        scheduleFallbackTimer()
        refreshStatus()
        logger.notice("Refreshed after wake")
    }

    @objc private func screensDidSleep(_ notification: Notification) {
        isScreenAsleep = true
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    @objc private func screensDidWake(_ notification: Notification) {
        isScreenAsleep = false
        scheduleFallbackTimer()
        refreshStatus()
    }

    private func refreshStatus() {
        battery.refresh()
        batteryActions.refreshChargingInBackground()
        network.refresh()
        audio.refresh()
        refreshIconTelemetry()
        refreshIcon()
    }

    @objc private func screenParametersChanged(_ notification: Notification) {
        updateMaximumIconSize()
        refreshIcon()
    }

    private func updateMaximumIconSize() {
        let notchHeight = NSScreen.screens.first?.safeAreaInsets.top ?? 0
        let menuBarHeight = max(NSStatusBar.system.thickness, notchHeight)
        store.maximumMenuBarIconSize = max(IconPreferences.menuBarSizes.lowerBound, Int(menuBarHeight.rounded(.down)) - 1)
    }

    private func handleInputSourceChanged() {
        guard preferences.icon.middleSource == .inputSource else { return }
        updateIconInputSource()
        refreshIcon()
    }

    private func updateIconInputSource() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            store.iconInputSource = nil
            return
        }
        let id = Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
        if id.hasPrefix("com.apple.inputmethod.") {
            let marker: String?
            if id.contains("SCIM") || id.contains("TCIM") { marker = "中" }
            else if id.contains("Japanese") { marker = "あ" }
            else if id.contains("Korean") { marker = "한" }
            else { marker = nil }
            if let marker {
                store.iconInputSource = marker
                return
            }
        }
        let name = TISGetInputSourceProperty(source, kTISPropertyLocalizedName).map {
            Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String
        }
        store.iconInputSource = name?.first.map { String($0).uppercased() }
    }

    private func refreshIconTelemetry() {
        let source = preferences.icon.middleSource
        iconTelemetrySource = source
        if source == .inputSource { updateIconInputSource() }
        guard source == .power else {
            iconPowerTask?.cancel()
            iconPowerTask = nil
            store.iconSystemWatts = nil
            return
        }
        guard iconPowerTask == nil else { return }
        iconPowerTask = Task { [weak self] in
            let sample = await Task.detached(priority: .utility) { SystemPowerReader().read() }.value
            guard let self, !Task.isCancelled else { return }
            self.iconPowerTask = nil
            self.store.iconSystemWatts = sample.map { Int($0.watts.rounded()) }
            self.refreshIcon()
        }
    }

    private func updateBattery(_ status: BatteryStatus) {
        guard store.battery != status else { return }
        store.battery = status
        refreshIcon()
        logger.info("Battery \(status.percent ?? -1, privacy: .public) percent")
    }

    private func updateNetwork(_ status: NetworkStatus) {
        guard store.network != status else { return }
        store.network = status
        refreshIcon()
        logger.info("Network path: \(status.path.rawValue, privacy: .public)")
    }

    private func updateAudio(_ status: AudioStatus) {
        guard store.audio != status else { return }
        volumeScroll.resetIfDeviceChanged(from: store.audio.deviceID, to: status.deviceID)
        store.audio = status
        refreshIcon()
        logger.info("Audio \(status.percent ?? -1, privacy: .public) percent, muted: \(status.muted == true, privacy: .public)")
    }

    private func refreshIcon() {
        let icon = store.statusIcon(preferences.icon)
        guard let button = item?.button else { return }
        if icon != lastIcon {
            accentSizeConstraints.forEach { $0.constant = icon.size }
            button.image = icon.image(layer: .template)
            accentView.image = icon.image(layer: .accent)
            lastIcon = icon
        }

        let batteryLabel = store.battery.percent.map {
            String(localized: "Battery \($0) percent") + ", " + store.battery.detail
        } ?? store.battery.detail
        let volumeLabel: String
        if store.audio.muted == true {
            volumeLabel = String(localized: "Muted")
        } else if let percent = store.audio.percent {
            volumeLabel = String(localized: "Volume \(percent) percent")
        } else {
            volumeLabel = String(localized: "Volume unavailable")
        }
        button.setAccessibilityLabel(["TrioRing", batteryLabel, store.network.effectivePath.title, volumeLabel].joined(separator: ", "))
    }
}
