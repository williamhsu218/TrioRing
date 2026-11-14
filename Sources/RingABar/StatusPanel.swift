import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class StatusStore {
    var battery = BatteryStatus.unavailable
    var network = NetworkStatus()
    let wifiConnection = WiFiConnectionController()
    var audio = AudioStatus()
    private(set) var page = PanelPage.summary
    private(set) var navigationFocus: PanelNavigationFocus?
    private var summaryReturnFocus: PanelNavigationFocus?
    var panelVisible = false
    var panelPresentation: UInt64 = 0
    var audioExpanded = false
    var showsAllSummaryOutputs = false
    var audioDirection = AudioDirection.output
    var inputDevicesExpanded = true
    var summaryCanScroll = false
    var pointerOverOutputSlider = false
    var maximumMenuBarIconSize = IconPreferences.menuBarSizes.upperBound
    var iconInputSource: String?
    var iconSystemWatts: Int?
    var settingsIconLeaf = AppIconLeaf.overall
    var settingsCategory: SettingsCategory? = .icon
    var settingsVisible = false
    var vpn = VPNStatus()
    var localIP: String?
    var connectionDisclosureOverride: Bool?
    var showsMoreConnectionDetails = false
    var batteryReadingsExpanded = false

    var connectionDetailsExpanded: Bool {
        get { connectionDisclosureOverride ?? !network.showsWiFi }
        set { connectionDisclosureOverride = newValue }
    }

    var panelLayout: PanelLayout {
        switch page {
        case .summary: .summary(audioExpanded: audioExpanded, allOutputs: audioExpanded && showsAllSummaryOutputs)
        case .details(.battery): .battery(readingsExpanded: batteryReadingsExpanded)
        case .details(.network):
            .network(wifi: network.showsWiFi, expanded: connectionDetailsExpanded,
                     more: network.showsWiFi && connectionDetailsExpanded && showsMoreConnectionDetails)
        case .details(.audio):
            .audio(direction: audioDirection, inputExpanded: audioDirection == .input && inputDevicesExpanded)
        }
    }
    var batteryInfoVisible = false {
        didSet {
            if oldValue != batteryInfoVisible { batteryInfoFocusChange = ProcessInfo.processInfo.systemUptime }
        }
    }
    private(set) var batteryInfoFocusChange: TimeInterval = -.infinity

    func navigate(to destination: PanelPage, fromKeyboard: Bool = false) {
        switch destination {
        case .details(let section):
            summaryReturnFocus = .summary(section)
            navigationFocus = fromKeyboard ? .back : nil
        case .summary:
            navigationFocus = fromKeyboard ? summaryReturnFocus : nil
            summaryReturnFocus = nil
        }
        page = destination
    }

    func statusIcon(_ preferences: IconPreferences) -> StatusIcon {
        var appearance = preferences
        appearance.menuBarSize = min(appearance.menuBarSize, maximumMenuBarIconSize)
        return StatusIcon(battery: battery, network: network, audio: audio, preferences: appearance,
                          inputSource: iconInputSource, systemWatts: iconSystemWatts)
    }
}

enum PanelPage: Hashable, Sendable { case summary, details(PanelSection) }
enum PanelNavigationFocus: Hashable {
    case summary(PanelSection), audioDisclosure, back
}

enum PanelLayout: Hashable, Sendable {
    case summary(audioExpanded: Bool, allOutputs: Bool = false)
    case battery(readingsExpanded: Bool)
    case network(wifi: Bool, expanded: Bool, more: Bool)
    case audio(direction: AudioDirection, inputExpanded: Bool)
}

/// Mark complete layouts as cacheable without delaying provisional/loading geometry.
struct PanelReadyLayoutKey: PreferenceKey {
    static let defaultValue: PanelLayout? = nil
    static func reduce(value: inout PanelLayout?, nextValue: () -> PanelLayout?) {
        value = nextValue() ?? value
    }
}

private struct PanelMeasurement: Equatable, Sendable {
    let layout: PanelLayout
    let presentation: UInt64
    let height: CGFloat
    let ready: Bool
}

struct PanelHeightReporter {
    let layout: PanelLayout
    let presentation: UInt64
    let ready: Bool
    let onHeight: (PanelLayout, UInt64, CGFloat, Bool) -> Void

    func measuring<Content: View>(_ content: Content, adding chromeHeight: CGFloat) -> some View {
        content.fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: PanelMeasurement.self) { [layout, presentation, ready] proxy in
                PanelMeasurement(layout: layout, presentation: presentation,
                                 height: ceil(proxy.size.height) + chromeHeight, ready: ready)
            } action: { sample in
                guard sample.height.isFinite, sample.height > chromeHeight else { return }
                onHeight(sample.layout, sample.presentation, sample.height, sample.ready)
            }
    }
}

struct StatusPanel: View {
    static let summaryFooterHeight: CGFloat = 42
    static let summaryActionWidth: CGFloat = 30
    private static let summaryActionSpacing: CGFloat = 6
    private static let summaryDisclosureWidth: CGFloat = 14
    private static let summaryOutputLimit = 5

    let store: StatusStore
    let preferences: Preferences
    let network: NetworkMonitor
    let audio: AudioMonitor
    let batteryActions: BatteryActions
    let wifiAccess: WiFiLocationAccess
    let onVolume: (Double, UInt32) -> Void
    let onMute: (Bool, UInt32) -> Void
    let onClose: () -> Void
    let onSettings: () -> Void
    let onBatterySettings: () -> Void
    let onNetworkSettings: () -> Void
    let onAudioSettings: () -> Void
    let onAbout: () -> Void
    let onHeight: (PanelLayout, UInt64, CGFloat, Bool) -> Void
    let onQuit: () -> Void
    let onSystemSettings: (SystemSettingsPane) -> Void
    @State private var devicePicker = AudioDevicePicker()
    @State private var batteryPageCache = BatteryPageCache()
    @State private var networkPageCache = NetworkPageCache()
    @FocusState private var navigationFocus: PanelNavigationFocus?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum AudioDemand { case none, prefetch, live }
    private var audioDevicesVisible: Bool { store.audioExpanded && devicePicker.routes != nil }
    private var audioDisclosureLoading: Bool { store.audioExpanded && devicePicker.routes == nil }

    @State private var readyLayout: PanelLayout?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var summaryNetworkReady = false
    @State private var confirmWiFiOff = false
    @State private var vpnBusy = false
    @State private var vpnError: LocalizedStringKey?
    @State private var lastVolumeHapticStep: Int?

    private var needsSummaryNetwork: Bool {
        preferences.visibleSections.contains(.network) && (preferences.showsVPN || preferences.showsLocalIP)
    }

    var body: some View {
        let page = store.page
        let layout = store.panelLayout
        let summaryReady = (!preferences.visibleSections.contains(.audio) || !audioDisclosureLoading)
            && (!needsSummaryNetwork || summaryNetworkReady)
        let ready = page == .summary ? summaryReady : readyLayout == layout
        let height = PanelHeightReporter(layout: layout, presentation: store.panelPresentation,
                                         ready: ready, onHeight: onHeight)
        // The AppKit bounds drive presentation; a new page must not re-centre
        // a differently sized SwiftUI stack inside the previous frame.
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Group {
                    switch page {
                    case .summary:
                        summaryLayout(viewport: geometry.size.height, height: height)
                    case .details(let section):
                        detailPage(section, height: height)
                            .frame(height: geometry.size.height, alignment: .top)
                    }
                }
                .id(page)
                .transition(PanelMotion.pageTransition(reduceMotion: reduceMotion || !store.panelVisible))
            }
            .animation(PanelMotion.animation(reduceMotion: reduceMotion || !store.panelVisible), value: page)
        }
        .clipped()
        .frame(width: AnchoredPanel.width)
        .background {
            Color(nsColor: .windowBackgroundColor)
                .opacity(reduceTransparency ? 1 : 0.74)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onPreferenceChange(PanelReadyLayoutKey.self) { readyLayout = $0 }
        .onExitCommand(perform: onClose)
        .task(id: page) {
            await Task.yield()
            guard !Task.isCancelled, store.panelVisible else { return }
            navigationFocus = store.navigationFocus
        }
        .onChange(of: store.panelVisible) { _, visible in
            if !visible {
                navigationFocus = nil
                batteryPageCache = BatteryPageCache()
                networkPageCache = NetworkPageCache()
            }
        }
        .task(id: audioDemand) {
            switch audioDemand {
            case .none: break
            case .prefetch:
                if devicePicker.routes == nil { await devicePicker.refresh(using: audio) }
            case .live:
                await devicePicker.refreshWhileVisible(using: audio)
            }
        }
        .task(id: store.panelVisible ? preferences.showsLocalIP : nil) {
            // Prime the optional VPN row before the first visible measurement.
            guard needsSummaryNetwork, store.panelVisible || !summaryNetworkReady else { return }
            while !Task.isCancelled {
                let current = await network.vpnStatus()
                let details = preferences.showsLocalIP ? await network.details() : nil
                guard !Task.isCancelled else { return }
                store.vpn = current
                store.localIP = details?.ipv4 ?? details?.ipv6
                summaryNetworkReady = true
                guard store.panelVisible else { return }
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .task(id: observesBattery) {
            guard observesBattery else { return }
            while !Task.isCancelled {
                await batteryActions.refresh()
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .alert("Turn off Wi-Fi?", isPresented: $confirmWiFiOff) {
            Button("Turn Off Wi-Fi", role: .destructive) { network.setWiFiPower(false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current Wi-Fi connection will disconnect.")
        }
    }

    private func summaryLayout(viewport: CGFloat, height: PanelHeightReporter) -> some View {
        let footerHeight = Self.summaryFooterHeight
        return VStack(spacing: 0) {
            ScrollView {
                height.measuring(
                    summary.frame(width: AnchoredPanel.width - 28, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading),
                    adding: footerHeight
                )
            }
            .frame(width: AnchoredPanel.width, height: max(0, viewport - footerHeight), alignment: .topLeading)
            .background(StableScrollViewport())
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
                    > geometry.containerSize.height + 1
            } action: { _, canScroll in
                store.summaryCanScroll = canScroll
            }
            .onDisappear { store.summaryCanScroll = false }
            VStack(spacing: 0) {
                if !preferences.visibleSections.isEmpty { Divider().opacity(0.65) }
                footer.frame(maxHeight: .infinity)
            }
            .padding(.horizontal, 14)
            .frame(height: footerHeight)
        }
    }

    @ViewBuilder
    private func detailPage(_ section: PanelSection, height: PanelHeightReporter) -> some View {
        switch section {
        case .battery:
            BatteryPage(store: store, preferences: preferences, actions: batteryActions,
                        height: height, navigationFocus: $navigationFocus,
                        onBack: returnToSummary, onOpenSettings: { onSystemSettings(.battery) },
                        onOpenAppSettings: onBatterySettings, cache: batteryPageCache)
        case .network:
            NetworkPage(store: store, preferences: preferences, monitor: network, access: wifiAccess,
                        height: height, navigationFocus: $navigationFocus, onBack: returnToSummary,
                        onOpenSettings: onSystemSettings, onOpenAppSettings: onNetworkSettings,
                        onTogglePower: toggleWiFi, cache: networkPageCache)
        case .audio:
            AudioPage(store: store, preferences: preferences, monitor: audio, picker: devicePicker,
                      outputControls: audioControls, height: height, navigationFocus: $navigationFocus, onBack: returnToSummary,
                      onOpenSettings: { onSystemSettings(.sound) },
                      onOpenAppSettings: onAudioSettings)
        }
    }

    private var isKeyboardAction: Bool {
        switch NSApp.currentEvent?.type {
        case .keyDown, .keyUp: true
        default: false
        }
    }

    private func returnToSummary() {
        store.navigate(to: .summary, fromKeyboard: isKeyboardAction)
    }

    private func toggleWiFi() {
        guard !store.wifiConnection.busy else { return }
        if store.network.wifiPowered == true {
            if preferences.confirmsWiFiOff && (store.network.signalDBm != nil || store.network.path == .wifi) {
                confirmWiFiOff = true
            } else { network.setWiFiPower(false) }
        } else { network.setWiFiPower(true) }
    }

    private var observesBattery: Bool {
        store.panelVisible && preferences.visibleSections.contains(.battery)
            && (store.page == .summary || store.page == .details(.battery))
    }

    private var audioDemand: AudioDemand {
        guard store.panelVisible else { return .none }
        if store.page == .details(.audio) { return .live }
        guard store.page == .summary, preferences.visibleSections.contains(.audio) else { return .none }
        return store.audioExpanded ? .live : .prefetch
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(preferences.visibleSections) { section in
                summarySection(section)
                if section != preferences.visibleSections.last {
                    Divider().opacity(0.65).padding(.vertical, 10)
                }
            }
        }
    }

    @ViewBuilder
    private func summarySection(_ section: PanelSection) -> some View {
        switch section {
        case .battery:
            VStack(alignment: .leading, spacing: 8) {
                summaryRow(.battery, settings: .battery, label: "System Battery Settings…") {
                    row(symbol: store.battery.symbol, tint: batteryTint) {
                        statusLine("Battery", percent: store.battery.percent)
                            .font(.headline)
                        if let battery = store.battery.reading, !battery.pluggedIn, let minutes = battery.minutesRemaining {
                            let remaining = Duration.seconds(minutes * 60)
                                .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
                            detail(store.battery.detail + " · " + String(localized: "\(remaining) remaining"))
                        } else if let battery = store.battery.reading, battery.isPausedAtLimit, let limit = battery.chargeLimit {
                            detail(String(localized: "Charging paused · Limit \(limit)%"))
                        } else {
                            detail(store.battery.detail)
                        }
                    }
                }
                if preferences.showsChargeAction {
                    FullChargeRow(actions: batteryActions, reading: store.battery.reading, compact: true,
                                  onSystemSettings: { onSystemSettings(.battery) })
                }
                if preferences.showsPowerMode, let error = batteryActions.modeError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        case .network:
            VStack(alignment: .leading, spacing: 8) {
                let wireless = store.network.showsWiFi
                summaryRow(.network, settings: wireless ? .wifi : .network,
                           label: wireless ? "System Wi-Fi Settings…" : "System Network Settings…",
                           wifiPower: wireless && preferences.showsWiFiPower ? store.network.wifiPowered : nil) {
                    row(symbol: networkSymbol(wireless: wireless)) {
                        Text(networkTitle(wireless: wireless))
                            .font(.headline)
                            .fontWeight(.regular)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if wireless && store.network.wifiPowerFailed {
                            subtitle(String(localized: "Could not change Wi-Fi power"))
                        } else if let text = networkSubtitle(wireless: wireless) {
                            // Addresses and interface names keep both ends readable.
                            let showsAddress = preferences.showsLocalIP && store.localIP != nil
                            subtitle(text, truncation: showsAddress || !wireless ? .middle : .tail)
                        }
                    }
                }
                if !wireless && store.network.wifiPowerFailed {
                    detail(String(localized: "Could not change Wi-Fi power"))
                }
                if preferences.showsVPN && store.vpn.visible {
                    vpnRow
                }
            }
        case .audio:
            audioSection
        }
    }

    private var vpnRow: some View {
        let vpn = store.vpn
        let service = vpn.target
        let connected = service.map { $0.state == .connected } ?? (vpn.tunnel || !vpn.services.isEmpty)
        let changing = vpnBusy || service?.state == .connecting || service?.state == .disconnecting
        let proxyOnly = !connected && service == nil && vpn.proxy != nil
        let tint: Color = if vpnError != nil {
            .red
        } else if changing {
            .orange
        } else if connected {
            .green.opacity(0.72)
        } else {
            .secondary
        }
        let title = service?.name ?? (vpn.tunnel ? "TUN" : vpn.services.first) ?? String(localized: "System proxy")
        let status: String = if changing {
            String(localized: "Updating VPN…")
        } else if connected {
            [
                String(localized: "Connected"),
                vpn.tunnel && service != nil ? "TUN" : nil,
                vpn.tunnel && service == nil && !vpn.services.isEmpty
                    ? String(localized: "VPN: \(vpn.services.joined(separator: ", "))") : nil,
                vpn.proxy.map { String(localized: "Proxy: \($0.displayValue)") }
            ].compactMap { $0 }.joined(separator: " · ")
        } else {
            vpn.proxy?.displayValue ?? String(localized: "Not connected")
        }
        return HStack(spacing: Self.summaryActionSpacing) {
            row(symbol: proxyOnly ? "arrow.left.arrow.right" : "lock.shield", tint: tint) {
                Text(title)
                    .font(.headline)
                    .fontWeight(.regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                subtitle(status, truncation: vpn.proxy == nil ? .tail : .middle)
                if let vpnError {
                    Text(vpnError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .frame(minHeight: 31)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("RingABar.summary.vpn")
            .help(service == nil
                  ? Text(status + "\n" + String(localized: "TrioRing can show this connection but cannot turn it on or off."))
                  : Text(status))
            if let service {
                Button {
                    vpnError = nil
                    vpnBusy = true
                    Task {
                        let result = await SystemVPNService.set(service.state == .disconnected, service: service)
                        store.vpn = await network.vpnStatus()
                        vpnBusy = false
                        if result == .rejected { vpnError = "macOS did not accept the VPN request." }
                        if result == .unconfirmed { vpnError = "The VPN change was not confirmed." }
                    }
                } label: {
                    Image(systemName: "power")
                        .font(.callout)
                        .foregroundStyle(service.state == .connected ? Color.accentColor : .secondary)
                        .frame(width: Self.summaryActionWidth, height: Self.summaryActionWidth)
                }
                .buttonStyle(PanelActionStyle())
                .disabled(vpnBusy || !service.enabled || !service.state.stable)
                .accessibilityLabel(service.state == .connected ? Text("Disconnect VPN") : Text("Connect VPN"))
                .accessibilityIdentifier("RingABar.summary.vpnPower")
                .help(changing ? Text("Updating VPN…")
                      : service.state == .connected ? Text("Disconnect VPN") : Text("Connect VPN"))
                Button { onSystemSettings(.vpn) } label: {
                    Image(systemName: "gearshape")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.summaryActionWidth, height: Self.summaryActionWidth)
                }
                .buttonStyle(PanelActionStyle())
                .accessibilityLabel("Open System VPN Settings")
                .help("Open System VPN Settings")
            }
        }
    }

    private func networkSymbol(wireless: Bool) -> String {
        guard wireless else { return store.network.effectivePath.symbol }
        if store.network.wifiPowered == false { return "wifi.slash" }
        return wifiConnected ? "wifi" : "wifi.exclamationmark"
    }

    private func networkTitle(wireless: Bool) -> String {
        guard wireless else { return store.network.effectivePath.title }
        guard wifiConnected, let name = store.network.wifiName, !name.isEmpty else { return "Wi-Fi" }
        return name
    }

    /// Wi-Fi joined to a network, including when a tunnel is the primary path.
    private var wifiConnected: Bool {
        let network = store.network
        guard network.wifiPowered != false else { return false }
        return network.effectivePath == .wifi || network.signalDBm != nil || network.wifiName?.isEmpty == false
    }

    private func networkSubtitle(wireless: Bool) -> String? {
        let network = store.network
        if wireless {
            if network.wifiPowered == false { return String(localized: "Wi-Fi is off") }
            guard wifiConnected else {
                return network.wifiPowered == nil ? nil : String(localized: "Not connected")
            }
            if preferences.showsLocalIP, let ip = store.localIP { return ip }
            let state = network.wifiIsHotspot ? String(localized: "Personal Hotspot") : String(localized: "Connected")
            guard let signal = network.signalDBm else { return state }
            return state + " · " + String(localized: "Signal \(signal) dBm")
        }
        switch network.effectivePath {
        case .ethernet, .other, .tunnel:
            if preferences.showsLocalIP, let ip = store.localIP { return ip }
            guard let interface = network.physicalInterfaceName ?? network.interfaceName, !interface.isEmpty else {
                return String(localized: "Connected")
            }
            return String(localized: "Connected") + " · " + interface
        case .offline:
            return String(localized: "No network connection")
        case .unknown, .wifi:
            if preferences.showsLocalIP, let ip = store.localIP { return ip }
            return nil
        }
    }

    private func summaryRow<Content: View>(_ section: PanelSection, settings: SystemSettingsPane,
                                          label: LocalizedStringKey, wifiPower: Bool? = nil,
                                          @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: Self.summaryActionSpacing) {
            Button { openSummaryDetails(section) } label: {
                HStack(spacing: 8) {
                    content().frame(minHeight: 31)
                    Spacer()
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .panelSecondaryText()
                        .frame(width: Self.summaryDisclosureWidth)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(PanelActionStyle(highlightBleed: EdgeInsets(
                top: 2, leading: 6, bottom: 2, trailing: 4
            )))
            .focused($navigationFocus, equals: .summary(section))
            .accessibilityIdentifier("RingABar.\(section.rawValue)Details")

            ZStack {
                Color.clear
                if let wifiPower {
                    Button(action: toggleWiFi) {
                        Image(systemName: "power")
                            .font(.callout)
                            .foregroundStyle(wifiPower ? Color.accentColor : .secondary)
                            .frame(width: Self.summaryActionWidth, height: Self.summaryActionWidth)
                    }
                    .buttonStyle(PanelActionStyle())
                    .accessibilityLabel(wifiPower ? Text("Turn Wi-Fi off") : Text("Turn Wi-Fi on"))
                    .accessibilityIdentifier("RingABar.summary.wifiPower")
                    .disabled(store.wifiConnection.busy)
                } else if section == .battery {
                    batteryModeQuickActions
                }
            }
            .frame(width: Self.summaryActionWidth, height: Self.summaryActionWidth)
        }
    }

    @ViewBuilder private var batteryModeQuickActions: some View {
        if preferences.showsPowerMode, let reading = store.battery.reading,
           let state = batteryActions.modes, let current = state.current,
           state.supportsLow || state.supportsHigh {
            if batteryActions.powerAuthorization.state != .ready {
                Button(action: onBatterySettings) {
                    Image(systemName: "lock.shield")
                        .frame(width: Self.summaryActionWidth, height: Self.summaryActionWidth)
                }
                .buttonStyle(PanelActionStyle())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Power Mode Access")
                .accessibilityIdentifier("RingABar.summary.powerAccess")
                .help("Set up power mode access")
            } else if state.supportsLow && state.supportsHigh {
                Menu {
                    ForEach(PowerMode.allCases, id: \.rawValue) { mode in
                        Button { batteryActions.setMode(mode, pluggedIn: reading.pluggedIn) } label: {
                            Label(mode.title, systemImage: mode == current ? "checkmark" : mode.symbol)
                        }
                    }
                } label: {
                    Image(systemName: current.symbol)
                        .foregroundStyle(current == .low ? Color.yellow : current == .high ? .orange : .secondary)
                        .frame(width: Self.summaryActionWidth, height: Self.summaryActionWidth)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .disabled(batteryActions.modeBusy)
                .accessibilityLabel("Power Mode")
                .accessibilityValue(Text(current.title))
                .accessibilityIdentifier("RingABar.summary.powerMode.menu")
            } else {
                batteryModeButton(state.supportsLow ? .low : .high, current: current, pluggedIn: reading.pluggedIn)
            }
        }
    }

    private func batteryModeButton(_ mode: PowerMode, current: PowerMode, pluggedIn: Bool) -> some View {
        let active = mode == current
        let label: LocalizedStringKey = mode == .low ? "Low Power Mode" : "High Power Mode"
        return Button {
            batteryActions.setMode(active ? .automatic : mode, pluggedIn: pluggedIn)
        } label: {
            Image(systemName: mode.symbol)
                .font(.callout)
                .foregroundStyle(active ? (mode == .low ? Color.yellow : .orange) : .secondary)
                .frame(width: Self.summaryActionWidth, height: Self.summaryActionWidth)
        }
        .buttonStyle(PanelActionStyle())
        .disabled(batteryActions.modeBusy)
        .accessibilityLabel(Text(label))
        .accessibilityValue(active ? Text("On") : Text("Off"))
        .accessibilityIdentifier("RingABar.summary.powerMode.\(mode.rawValue)")
        .help(Text(label))
    }

    private func openSummaryDetails(_ section: PanelSection) {
        if section == .network {
            let modifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            if modifiers.contains(.option) { store.connectionDetailsExpanded = true }
        }
        store.navigate(to: .details(section), fromKeyboard: isKeyboardAction)
    }

    private var audioDetailsButton: some View {
        Button {
            store.audioDirection = .output
            openSummaryDetails(.audio)
        } label: {
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .panelSecondaryText()
                .frame(width: Self.summaryActionWidth, height: Self.summaryActionWidth)
        }
        .buttonStyle(PanelActionStyle())
        .focused($navigationFocus, equals: .summary(.audio))
        .accessibilityLabel("Audio details")
        .accessibilityIdentifier("RingABar.audioDetails")
        .help("Audio details")
    }

    private var batteryTint: Color {
        switch store.battery.accent {
        case .charging: .green
        case .lowPower: .yellow
        case .critical: .red
        case nil: .secondary
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onSettings) {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape")
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    Text("Settings…").lineLimit(1)
                }
                .padding(.trailing, 6)
                .frame(height: Self.summaryActionWidth)
                .contentShape(Rectangle())
            }
            .buttonStyle(PanelActionStyle(highlightBleed: EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 0)))
            .help("Open TrioRing settings (⌘,)")
            .accessibilityIdentifier("RingABar.openSettings")

            Spacer(minLength: 0)
            Menu {
                Button("About TrioRing", action: onAbout)
                Button("Open Menu Bar Settings") { onSystemSettings(.menuBar) }
                Divider()
                Button("Quit TrioRing", action: onQuit)
                    .accessibilityIdentifier("RingABar.quit")
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: Self.summaryActionWidth, height: Self.summaryActionWidth)
                    .accessibilityLabel("More actions")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .frame(width: Self.summaryActionWidth, height: Self.summaryActionWidth)
            .accessibilityIdentifier("RingABar.summary.moreActions")
            .help("More actions")
        }
        .font(.callout)
        .panelSecondaryText()
    }

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Self.summaryActionSpacing) {
                if let device = store.audio.deviceID, store.audio.canMute {
                    muteButton(device: device, muted: store.audio.muted == true)
                } else {
                    Image(systemName: store.audio.deviceSymbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                }
                if let device = store.audio.deviceID, store.audio.canSetVolume, let volume = store.audio.volume {
                    volumeSlider(device: device, volume: volume).id(device)
                    audioDisclosure(percent: store.audio.percent)
                } else {
                    audioDisclosure(percent: nil)
                }
                audioDetailsButton
            }
            .frame(minHeight: 31)

            if store.audio.controlFailed {
                audioControlError
                    .padding(.leading, 34)
            }
            if audioDevicesVisible, let routes = devicePicker.routes {
                VStack(alignment: .leading, spacing: 6) {
                    let outputs = preferences.audioDevices(in: routes, for: .output)
                    if outputs.isEmpty {
                        detail(String(localized: "No available devices"))
                    } else {
                        summaryDeviceRows(outputs, selectedID: routes.selectedID(for: .output))
                        if outputs.count > Self.summaryOutputLimit { summaryOutputDisclosure }
                    }
                    if devicePicker.failedDirection == .output {
                        Text("Could not switch audio device.")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 7)
                    }
                }
                .transition(PanelMotion.disclosureTransition(reduceMotion: reduceMotion))
            }
        }
        .clipped()
        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: audioDevicesVisible)
        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: store.showsAllSummaryOutputs)
    }

    private func audioDisclosure(percent: Int?) -> some View {
        let deviceName = store.audio.deviceName ?? String(localized: "Output unavailable")
        let help = audioDisclosureLoading ? String(localized: "Cancel opening audio devices")
            : audioDevicesVisible ? String(localized: "Collapse audio devices") : String(localized: "Expand audio devices")
        return Button {
            store.audioExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                if let percent {
                    Text(Double(percent) / 100, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .fixedSize()
                        .frame(minWidth: Self.summaryActionWidth, alignment: .trailing)
                } else {
                    Text(verbatim: audioDevicesVisible && store.audio.deviceID != nil
                         ? String(localized: "Volume controlled by device") : deviceName)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ZStack {
                    if audioDisclosureLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(audioDevicesVisible ? 180 : 0))
                            .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: audioDevicesVisible)
                    }
                }
                .frame(width: Self.summaryDisclosureWidth, height: Self.summaryDisclosureWidth)
                .accessibilityHidden(true)
            }
            .panelSecondaryText()
            .frame(minHeight: Self.summaryActionWidth)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelActionStyle())
        .focused($navigationFocus, equals: .audioDisclosure)
        .accessibilityLabel(Text(verbatim: String(localized: "Audio devices") + ": " + deviceName))
        .accessibilityValue(audioDisclosureLoading ? Text("Loading") : audioDevicesVisible ? Text("Expanded") : Text("Collapsed"))
        .accessibilityIdentifier("RingABar.audio.toggleDevices")
        .help(Text(verbatim: deviceName + "\n" + help))
    }

    private func summaryDeviceRows(_ devices: [AudioRoute], selectedID: AudioRoute.ID?) -> some View {
        var visible = store.showsAllSummaryOutputs ? devices : Array(devices.prefix(Self.summaryOutputLimit))
        if visible.count < devices.count, let selectedID, !visible.contains(where: { $0.id == selectedID }),
           let selected = devices.first(where: { $0.id == selectedID }) {
            visible[visible.count - 1] = selected
        }
        let airPods = devicePicker.airPodsOutput
        return AudioDeviceRows(devices: visible, direction: .output, picker: devicePicker, monitor: audio,
                               showsSummaryChips: true,
                               inlineAirPods: airPods?.deviceID == selectedID ? airPods : nil,
                               isPanelVisible: store.panelVisible)
    }

    private var summaryOutputDisclosure: some View {
        Button {
            store.showsAllSummaryOutputs.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: store.showsAllSummaryOutputs ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
                Text(store.showsAllSummaryOutputs ? "Show fewer devices" : "Show more devices")
                Spacer(minLength: 0)
            }
            .font(.callout)
            .panelSecondaryText()
            .padding(.horizontal, 7)
            .frame(minHeight: AudioDeviceRows.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelActionStyle())
        .accessibilityValue(store.showsAllSummaryOutputs ? Text("Expanded") : Text("Collapsed"))
        .accessibilityIdentifier("RingABar.audio.outputOverflow")
    }

    private func volumeSlider(device: UInt32, volume: Double) -> some View {
        Slider(value: Binding(
            get: { store.audio.deviceID == device ? store.audio.volume ?? volume : volume },
            set: { newValue in
                let step = Int((min(1, max(0, newValue)) * 16).rounded())
                let previousStep = lastVolumeHapticStep ?? Int((min(1, max(0, store.audio.volume ?? volume)) * 16).rounded())
                if !reduceMotion, step != previousStep {
                    let pattern: NSHapticFeedbackManager.FeedbackPattern = (step == 0 || step == 16) ? .alignment : .levelChange
                    NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
                }
                lastVolumeHapticStep = step
                onVolume(newValue, device)
            }
        ), in: 0...1) {
            Text("Output volume")
        }
        .labelsHidden()
        .tint(store.audio.muted == true ? .secondary : .accentColor)
        .accessibilityIdentifier("RingABar.volume")
        .help(preferences.scrollToAdjustVolume ? Text("Scroll here to adjust volume") : Text("Output volume"))
        .onHover { store.pointerOverOutputSlider = $0 }
        .onDisappear {
            store.pointerOverOutputSlider = false
            lastVolumeHapticStep = nil
        }
    }

    private var audioControlError: some View {
        Text("Could not change audio. Try again.")
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityIdentifier("RingABar.audioError")
    }

    private var audioControls: some View {
        let audio = store.audio
        return VStack(alignment: .leading, spacing: 5) {
            if let device = audio.deviceID, audio.canSetVolume, let volume = audio.volume {
                HStack(spacing: 8) {
                    if audio.canMute {
                        muteButton(device: device, muted: audio.muted == true)
                    } else {
                        Image(systemName: "speaker.fill")
                            .frame(width: 24)
                            .accessibilityHidden(true)
                    }
                    volumeSlider(device: device, volume: volume)
                    Image(systemName: "speaker.wave.3.fill").accessibilityHidden(true)
                }
                .foregroundStyle(.secondary)
            } else {
                if let device = audio.deviceID, audio.canMute {
                    muteButton(device: device, muted: audio.muted == true)
                }
                if audio.canSetVolume {
                    detail(String(localized: "Volume unavailable"))
                }
            }
            if audio.controlFailed {
                audioControlError
            }
        }
        .id(audio.deviceID)
    }

    private func muteButton(device: UInt32, muted: Bool) -> some View {
        Button {
            onMute(!muted, device)
        } label: {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24, height: 24)
                .foregroundStyle(muted ? Color.red : .secondary)
        }
        .buttonStyle(PanelActionStyle())
        .accessibilityLabel(muted ? Text("Unmute") : Text("Mute"))
        .accessibilityIdentifier("RingABar.mute")
        .help(muted ? Text("Unmute") : Text("Mute"))
    }

    private func row<Content: View>(symbol: String, tint: Color = .secondary, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2, content: content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusLine(_ title: LocalizedStringKey, percent: Int?) -> some View {
        HStack(spacing: 4) {
            Text(title).fontWeight(.medium)
            if let percent {
                Text("·").panelSecondaryText().accessibilityHidden(true)
                Text(Double(percent) / 100, format: .percent.precision(.fractionLength(0)))
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
        }
    }

    /// A summary row's single secondary line, matching the headline's width.
    private func subtitle(_ text: String, truncation: Text.TruncationMode = .tail) -> some View {
        Text(text)
            .font(.caption)
            .panelSecondaryText()
            .lineLimit(1)
            .truncationMode(truncation)
    }

    private func detail(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .panelSecondaryText()
            .lineLimit(2)
    }
}
