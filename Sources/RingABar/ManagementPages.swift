import AppKit
import SwiftUI

enum SystemSettingsPane {
    case battery, network, wifi, vpn, sound, sharing, location, menuBar

    var url: URL {
        let pane = switch self {
        case .battery: "com.apple.Battery-Settings.extension"
        case .network: "com.apple.Network-Settings.extension"
        case .wifi: "com.apple.wifi-settings-extension"
        case .vpn: "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension"
        case .sound: "com.apple.Sound-Settings.extension"
        case .sharing: "com.apple.Sharing-Settings.extension"
        case .location: "com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices"
        case .menuBar: "com.apple.ControlCenter-Settings.extension"
        }
        return URL(string: "x-apple.systempreferences:" + pane)!
    }
}

struct PageHeader<Trailing: View>: View {
    static var height: CGFloat { 32 }

    let title: LocalizedStringKey
    let navigationFocus: FocusState<PanelNavigationFocus?>.Binding
    let onBack: () -> Void
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            backButton
            trailing()
        }
        .frame(height: Self.height)
    }

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.backward")
                    .font(.caption.weight(.semibold))
                    .frame(width: Self.height, height: Self.height)
                    .background {
                        Circle().fill(Color.primary.opacity(hovered ? 0.07 : 0))
                    }
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(hovered ? 0.72 : 1.0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .focused(navigationFocus, equals: .back)
        .accessibilityLabel("Back")
        .accessibilityValue(Text(title))
        .help("Back (⌘[)")
        .accessibilityIdentifier("RingABar.management.back")
    }
}

struct DetailHeaderAction: View {
    let symbol: String
    var isBusy = false

    var body: some View {
        ZStack {
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: StatusPanel.summaryActionWidth, height: StatusPanel.summaryActionWidth)
        .accessibilityHidden(true)
    }
}

struct DetailPanel<Header: View, Content: View>: View {
    let height: PanelHeightReporter
    let headerHeight: CGFloat
    let spacing: CGFloat
    let scrollContentID: String?
    let header: Header
    let content: Content
    @State private var contentScrolled = false
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(height: PanelHeightReporter, headerHeight: CGFloat = PageHeader<EmptyView>.height, spacing: CGFloat = 12,
         scrollContentID: String? = nil, @ViewBuilder header: () -> Header,
         @ViewBuilder content: () -> Content) {
        self.height = height
        self.headerHeight = headerHeight
        self.spacing = spacing
        self.scrollContentID = scrollContentID
        self.header = header()
        self.content = content()
    }

    var body: some View {
        let topInset: CGFloat = 14
        let chromeHeight = topInset + headerHeight + spacing
        let contentWidth = AnchoredPanel.width - 28
        VStack(alignment: .leading, spacing: 0) {
            header.frame(width: contentWidth, height: headerHeight, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, topInset)
                .padding(.bottom, spacing)
                .overlay(alignment: .bottom) {
                    if contentScrolled {
                        Divider().padding(.horizontal, 14)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            .transition(.opacity)
                    }
                }
                .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: contentScrolled)
            ScrollView {
                height.measuring(
                    content.frame(width: contentWidth, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading),
                    adding: chromeHeight
                )
            }
            // Constrain the viewport independently of the document. Overlay
            // scrollers preserve its full width even during a native resize.
            .frame(width: AnchoredPanel.width, alignment: .leading)
            .background(StableScrollViewport())
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 1
            } action: { _, scrolled in
                contentScrolled = scrolled
            }
            .scrollPosition($scrollPosition)
        }
        .frame(width: AnchoredPanel.width, alignment: .leading)
        .onChange(of: scrollContentID) { _, _ in
            contentScrolled = false
            scrollPosition.scrollTo(edge: .top)
        }
    }
}

private struct DetailGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailValue: View {
    let label: LocalizedStringKey
    let value: String
    var copyID: String?
    @State private var copySucceeded: Bool?
    @State private var copyRevision = 0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).panelSecondaryText()
            Spacer(minLength: 0)
            if let copyID {
                Button {
                    NSPasteboard.general.clearContents()
                    copySucceeded = NSPasteboard.general.setString(value, forType: .string)
                    copyRevision += 1
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(value).multilineTextAlignment(.trailing)
                            .monospacedDigit()
                        Image(systemName: copySucceeded == true ? "checkmark" : copySucceeded == false ? "exclamationmark.circle" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                            .font(.caption2)
                            .foregroundStyle(copySucceeded == true ? Color.green : copySucceeded == false ? Color.red : .secondary)
                            .frame(width: 12)
                            .accessibilityHidden(true)
                    }
                    .help(copySucceeded == true ? Text("Copied") : copySucceeded == false ? Text("Copy failed") : Text("Copy"))
                }
                .buttonStyle(PanelActionStyle())
                .accessibilityLabel(Text("\(Text(label)): \(value)"))
                .accessibilityHint("Copy")
                .accessibilityValue(copySucceeded == true ? Text("Copied") : copySucceeded == false ? Text("Copy failed") : Text(""))
                .accessibilityIdentifier(copyID)
                .task(id: copyRevision) {
                    guard copySucceeded != nil else { return }
                    do { try await Task.sleep(for: .seconds(1.5)) }
                    catch { return }
                    copySucceeded = nil
                }
                .onChange(of: value) { _, _ in copySucceeded = nil }
            } else {
                Text(value)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
        .font(.caption)
    }
}

private struct DetailSettingsLink: View {
    let title: LocalizedStringKey
    let accessibilityID: String
    let action: () -> Void

    init(_ title: LocalizedStringKey, id: String, action: @escaping () -> Void) {
        self.title = title
        self.accessibilityID = id
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        }
        .buttonStyle(PanelActionStyle())
        .accessibilityIdentifier(accessibilityID)
    }
}

struct BatteryPage: View {
    let store: StatusStore
    let preferences: Preferences
    let actions: BatteryActions
    let height: PanelHeightReporter
    let navigationFocus: FocusState<PanelNavigationFocus?>.Binding
    let onBack: () -> Void
    let onOpenSettings: () -> Void
    let onOpenAppSettings: () -> Void
    let cache: BatteryPageCache
    private var details: BatteryDetails? {
        cache.pluggedIn == store.battery.reading?.pluggedIn ? cache.details : nil
    }
    private var power: BatteryPowerSnapshot? {
        cache.pluggedIn == store.battery.reading?.pluggedIn ? cache.power : nil
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DetailPanel(height: height) {
            let title = store.battery.percent.map { String(localized: "Battery · \($0)%") } ?? String(localized: "Battery")
            PageHeader(title: LocalizedStringKey(title), navigationFocus: navigationFocus, onBack: onBack) {
                Button(action: onOpenAppSettings) {
                    DetailHeaderAction(symbol: "gearshape")
                }
                .buttonStyle(PanelActionStyle(cornerRadius: StatusPanel.summaryActionWidth / 2))
                .help("Open App Battery Settings")
                .accessibilityLabel("Open App Battery Settings")
                .accessibilityIdentifier("RingABar.battery.appSettingsShortcut")

                Button { store.batteryInfoVisible.toggle() } label: {
                    DetailHeaderAction(symbol: "info.circle")
                }
                .buttonStyle(PanelActionStyle(cornerRadius: StatusPanel.summaryActionWidth / 2))
                .help("About these readings")
                .accessibilityLabel("About these readings")
                .accessibilityIdentifier("RingABar.battery.info")
                .popover(isPresented: Binding(get: { store.batteryInfoVisible },
                                              set: { store.batteryInfoVisible = $0 }), arrowEdge: .bottom) {
                    batteryReadingInfo
                        .padding(12)
                        .frame(width: 282)
                }
            }
        } content: {
            batteryContent
                .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: batteryLayoutReady)
        }
        .onDisappear { store.batteryInfoVisible = false }
        .preference(key: PanelReadyLayoutKey.self, value: batteryLayoutReady ? store.panelLayout : nil)
        .task(id: store.battery.reading?.pluggedIn) {
            guard let reading = store.battery.reading else { return }
            cache.prepare(pluggedIn: reading.pluggedIn)
            let result = await Task.detached(priority: .utility) { BatteryDetails.read() }.value
            if !Task.isCancelled { cache.details = result }
        }
        .task(id: store.battery.reading?.pluggedIn) {
            guard let reading = store.battery.reading else { return }
            cache.prepare(pluggedIn: reading.pluggedIn)
            while !Task.isCancelled {
                let previous = power?.breakdown
                let pluggedIn = reading.pluggedIn
                let result = await Task.detached(priority: .utility) {
                    BatteryPowerSnapshot.read(pluggedIn: pluggedIn, previous: previous)
                }.value
                guard !Task.isCancelled else { return }
                cache.power = result
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var batteryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let battery = store.battery.reading {
                if preferences.showsPowerFlow, let flow = power?.flow {
                    BatteryPowerFlowView(state: flow)
                        .accessibilityIdentifier("RingABar.battery.powerFlow")
                }
                DetailGroup {
                    DetailValue(label: "Battery level", value: (Double(battery.percent) / 100).formatted(.percent))
                        .accessibilityIdentifier("RingABar.battery.charge")
                    DetailValue(label: "Power status", value: store.battery.detail)
                    if let minutes = battery.minutesRemaining {
                        let remaining = Duration.seconds(minutes * 60)
                            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
                        DetailValue(label: battery.charging ? "Estimated time until charged" : "Estimated time remaining", value: remaining)
                    }
                }
                chargingManagement(battery)
                if let modes = actions.modes, modes.supportsLow || modes.supportsHigh, modes.current != nil {
                    Divider()
                    detailPowerMode(battery, modes: modes)
                } else if actions.modes == nil {
                    DetailValue(label: "Low Power Mode", value: battery.lowPower ? String(localized: "On") : String(localized: "Off"))
                }
                Divider()
                batteryReadings(isPluggedIn: battery.pluggedIn)
            } else {
                Text(store.battery.detail).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                DetailSettingsLink("System Battery Settings…", id: "RingABar.battery.systemSettings", action: onOpenSettings)
                DetailSettingsLink("Open App Battery Settings", id: "RingABar.battery.appSettingsLink", action: onOpenAppSettings)
            }
        }
    }

    @ViewBuilder
    private func chargingManagement(_ battery: BatteryReading) -> some View {
        let showsLimitControls = !actions.availableChargeLimits.isEmpty
        let fallbackLimit = actions.currentChargeLimit == nil || !showsLimitControls
            ? actions.temporarilyOverriddenLimit ?? battery.chargeLimit : nil
        let fullCharge = FullChargeRow(actions: actions, reading: battery, showUnavailable: true,
                                       onSystemSettings: onOpenSettings)
        if showsLimitControls || fallbackLimit.map({ $0 < 100 }) == true || fullCharge.hasContent {
            VStack(alignment: .leading, spacing: 7) {
                Text("Charging Management")
                    .font(.caption.weight(.semibold))
                    .panelSecondaryText()
                    .accessibilityAddTraits(.isHeader)
                if let limit = fallbackLimit, limit < 100 {
                    DetailValue(label: actions.temporarilyOverriddenLimit == nil ? "Charge limit" : "Charge limit (temporarily bypassed)",
                                value: (Double(limit) / 100).formatted(.percent))
                        .accessibilityIdentifier("RingABar.battery.chargeLimit")
                }
                if showsLimitControls {
                    ChargeLimitControls(actions: actions, reading: battery)
                }
                if fullCharge.hasContent { fullCharge }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.primary.opacity(0.09), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("RingABar.battery.chargingManagement")
        }
    }

    private func batteryReadings(isPluggedIn: Bool) -> some View {
        let expanded = store.batteryReadingsExpanded
        return VStack(alignment: .leading, spacing: 7) {
            Button {
                store.batteryReadingsExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path")
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text("Battery Health & Power")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: expanded)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(expanded ? Color.accentColor : .primary)
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(expanded ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(PanelActionStyle())
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityIdentifier("RingABar.battery.readings")
            if expanded {
                batteryDiagnosticValues(isPluggedIn: isPluggedIn)
                    .padding(.horizontal, 7)
                    .transition(PanelMotion.disclosureTransition(reduceMotion: reduceMotion))
            }
        }
        .clipped()
        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: expanded)
    }

    private func batteryDiagnosticValues(isPluggedIn: Bool) -> some View {
        DetailGroup {
            if isPluggedIn, let watts = details?.adapterWatts {
                DetailValue(label: "Adapter rating", value: String(localized: "\(watts) W"))
            }
            if let power {
                if let type = power.inputPortType {
                    DetailValue(label: "Charging port", value: type)
                }
                if let display = power.displayWatts, power.breakdown == nil || !preferences.showsPowerFlow {
                    DetailValue(label: "Built-in display backlight", value: BatteryPowerSnapshot.formatWatts(display))
                }
                ForEach(power.usbPorts, id: \.channel) { port in
                    let label = port.name.map { port.channelLabel + " · " + $0 } ?? port.channelLabel
                    DetailValue(label: LocalizedStringKey(label), value: BatteryPowerSnapshot.formatWatts(port.watts))
                        .help(port.measurementLabel)
                        .accessibilityIdentifier("RingABar.battery.usb.\(port.channel)")
                }
            }
            if let details {
                let unknown = String(localized: "Unavailable")
                DetailValue(label: "Maximum capacity", value: details.maximumCapacity
                    .map { (Double($0) / 100).formatted(.percent) } ?? unknown)
                    .accessibilityIdentifier("RingABar.battery.maximumCapacity")
                DetailValue(label: "Battery status", value: condition(details.condition))
                if let temperature = power?.temperatureCelsius {
                    let value = temperature.formatted(.number.precision(.fractionLength(1)))
                    DetailValue(label: "Battery temperature", value: String(localized: "\(value) °C"))
                }
                DetailValue(label: "Cycle count", value: details.cycleCount?.formatted() ?? unknown)
            } else {
                Text("Reading battery health…").font(.caption).foregroundStyle(.secondary)
            }
            DetailValue(label: "System uptime", value: Duration.seconds(details?.uptime ?? ProcessInfo.processInfo.systemUptime)
                .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
        }
    }

    private var batteryReadingInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("About these readings").font(.headline)
            Text("The system branch estimates the remainder after display, battery charging and USB output.")
            Text("USB readings are per port. Accessories behind a hub share its reading.")
            if let volts = power?.volts {
                DetailValue(label: "Battery voltage", value: String(localized: "\(decimal(volts)) V"))
            }
            if let amps = power?.amps {
                DetailValue(label: "Battery current", value: String(localized: "\(decimal(amps)) A"))
            }
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RingABar.battery.explanation")
    }

    @ViewBuilder private func detailPowerMode(_ battery: BatteryReading, modes: PowerModeState) -> some View {
        if actions.powerAuthorization.state != .ready {
            DetailValue(label: "Low Power Mode", value: battery.lowPower ? String(localized: "On") : String(localized: "Off"))
            Button(action: onOpenAppSettings) {
                Label("Set up power mode access", systemImage: "lock.shield")
            }
            .accessibilityIdentifier("RingABar.battery.powerAccess")
        } else if modes.supportsHigh {
            PowerModeRow(actions: actions, reading: battery)
        } else {
            Toggle("Low Power Mode", isOn: Binding(
                get: { modes.current == .low },
                set: { actions.setMode($0 ? .low : .automatic, pluggedIn: battery.pluggedIn) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(actions.modeBusy)
            .accessibilityIdentifier("RingABar.battery.powerMode")
            if actions.modeBusy {
                ProgressView("Waiting for macOS…").controlSize(.small).font(.caption)
            }
            if let error = actions.modeError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private var batteryLayoutReady: Bool {
        guard store.battery.reading != nil else { return true }
        if store.batteryReadingsExpanded { return details != nil && power != nil }
        return !preferences.showsPowerFlow || power != nil
    }

    private func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1...2)))
    }

    private func condition(_ condition: BatteryDetails.Condition?) -> String {
        switch condition {
        case .normal: String(localized: "Normal")
        case .serviceRecommended: String(localized: "Service Recommended")
        case nil: String(localized: "Unavailable")
        }
    }
}

struct NetworkPage: View {
    let store: StatusStore
    let preferences: Preferences
    let monitor: NetworkMonitor
    let access: WiFiLocationAccess
    let height: PanelHeightReporter
    let navigationFocus: FocusState<PanelNavigationFocus?>.Binding
    let onBack: () -> Void
    let onOpenSettings: (SystemSettingsPane) -> Void
    let onOpenAppSettings: () -> Void
    let onTogglePower: () -> Void
    let cache: NetworkPageCache
    private var identity: NetworkPageIdentity {
        NetworkPageIdentity(status: store.network, locationAllowed: access.allowed)
    }
    private var details: NetworkDetails? { cache.identity == identity ? cache.details : nil }
    private var nearby: NearbyWiFi? { cache.identity == identity ? cache.nearby : nil }
    private var connection: WiFiConnectionController { store.wifiConnection }
    private var connectionPresentationID: String {
        switch connection.phase {
        case .idle: "idle"
        case .connecting(let row): "connecting:" + row.id
        case .passwordRequired(let row, _): "password:" + row.id
        case .connected(let row): "connected:" + row.id
        case .failed(let row, _): "failed:" + row.id
        }
    }
    @State private var refresh = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var scanFailed = false
    @State private var scanning = false

    private struct ScanRequest: Equatable {
        let identity: NetworkPageIdentity
        let refresh: Int
    }

    private var wifi: Bool { store.network.showsWiFi }

    var body: some View {
        // A selection from the bottom of a long list must reveal the prompt,
        // not leave password/progress feedback above the scrolled viewport.
        DetailPanel(height: height, scrollContentID: connectionPresentationID) {
            PageHeader(title: wifi ? "Wi-Fi" : "Ethernet", navigationFocus: navigationFocus, onBack: onBack) {
                Button(action: onOpenAppSettings) {
                    DetailHeaderAction(symbol: "gearshape")
                }
                .buttonStyle(PanelActionStyle(cornerRadius: StatusPanel.summaryActionWidth / 2))
                .help("Open App Network Settings")
                .accessibilityLabel("Open App Network Settings")
                .accessibilityIdentifier("RingABar.network.appSettingsShortcut")
                if wifi {
                    Button {
                        monitor.refresh()
                        refresh += 1
                    } label: {
                        DetailHeaderAction(symbol: "arrow.clockwise", isBusy: scanning)
                    }
                    .buttonStyle(PanelActionStyle(cornerRadius: StatusPanel.summaryActionWidth / 2))
                    .disabled(scanning || connection.busy || store.network.wifiPowered != true)
                    .help("Refresh networks")
                    .accessibilityLabel("Refresh networks")
                    .accessibilityIdentifier("RingABar.network.refresh")
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if wifi { wifiContent }
                else { connectionDisclosure }
                Divider()
                if wifi {
                    DetailSettingsLink("System Wi-Fi Settings…", id: "RingABar.network.systemSettings", action: { onOpenSettings(.wifi) })
                } else {
                    DetailSettingsLink("System Network Settings…", id: "RingABar.network.systemSettings", action: { onOpenSettings(.network) })
                }
                DetailSettingsLink("Share Internet…", id: "RingABar.network.sharing", action: { onOpenSettings(.sharing) })
            }
            .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: networkLayoutReady)
        }
        .preference(key: PanelReadyLayoutKey.self, value: networkLayoutReady ? store.panelLayout : nil)
        .task(id: ScanRequest(identity: identity, refresh: refresh)) {
            cache.prepare(identity: identity)
            while !Task.isCancelled {
                let result = await monitor.details()
                guard !Task.isCancelled else { return }
                cache.details = result
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .task(id: ScanRequest(identity: identity, refresh: refresh)) {
            cache.prepare(identity: identity)
            guard access.allowed, store.network.wifiPowered == true, wifi else {
                cache.nearby = nil
                scanning = false
                return
            }
            // A quick back-and-forth navigation must not launch another costly
            // scan or replace an already usable list with a loading placeholder.
            if refresh == 0, cache.canReuseScan(for: identity) { return }
            scanFailed = false
            scanning = true
            monitor.refresh()
            let result = await Task.detached(priority: .utility) { try? NearbyWiFi.scan() }.value
            guard !Task.isCancelled else { return }
            if let result {
                cache.nearby = result
                cache.scannedAt = .now
                if let connected = connection.connectedNetwork, result.current?.ssidData != connected.ssidData {
                    connection.clearResult()
                }
            }
            scanFailed = result == nil
            scanning = false
        }
        .onChange(of: connection.phase) { _, phase in
            guard case .connected = phase else { return }
            monitor.refresh()
            cache.scannedAt = nil
            refresh += 1
        }
        .onChange(of: store.network.wifiName, initial: true) { _, name in
            if let connected = connection.connectedNetwork, connected.name != name { connection.clearResult() }
        }
        .onChange(of: store.network.wifiPowered) { _, powered in
            if powered != true { connection.clearResult() }
        }
        .onChange(of: access.allowed) { _, allowed in
            if !allowed { connection.dismissPrompt() }
        }
    }

    private var networkLayoutReady: Bool {
        // A transient password/error/progress block must not replace the cached
        // height of the ordinary network layout for the next presentation.
        guard connection.phase == .idle else { return false }
        let connectionReady = !store.connectionDetailsExpanded || details != nil
        if !wifi { return connectionReady }
        let wifiReady = !access.allowed || store.network.wifiPowered != true || nearby != nil || scanFailed
        return wifiReady && connectionReady
    }

    @ViewBuilder private var wifiContent: some View {
        if preferences.showsWiFiPower {
            Toggle("Wi-Fi", isOn: Binding(get: { store.network.wifiPowered == true }, set: { _ in onTogglePower() }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(connection.busy || store.network.wifiPowered == nil)
                .accessibilityIdentifier("RingABar.network.wifiPower")
        }
        if store.network.wifiPowerFailed {
            Text("Could not change Wi-Fi power").font(.caption).foregroundStyle(.red)
        }
        WiFiConnectionView(controller: connection, onOpenSettings: { onOpenSettings(.wifi) })
        connectionDisclosure
        if store.network.wifiPowered == false {
            Text("Wi-Fi is off").font(.caption).foregroundStyle(.secondary)
        } else if !access.allowed {
            Button {
                if !access.request() { onOpenSettings(.location) }
            } label: {
                Text("Allow location to show Wi-Fi networks")
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            }
            .buttonStyle(PanelActionStyle())
            .accessibilityIdentifier("RingABar.network.location")
        } else if let nearby {
            VStack(alignment: .leading, spacing: 10) {
                if scanFailed {
                    Text("Could not refresh Wi-Fi networks").font(.caption).foregroundStyle(.secondary)
                }
                let hotspot = store.network.wifiIsHotspot ? nearby.current : nil
                if let hotspot {
                    networkGroup("Personal Hotspots", rows: [hotspot], current: hotspot.id)
                }
                let known = (hotspot == nil ? nearby.current.map { [$0] } ?? [] : []) + nearby.known
                if !known.isEmpty || hotspot == nil {
                    VStack(alignment: .leading, spacing: 4) {
                        networkGroup("Known Networks", rows: known, current: nearby.current?.id, showWhenEmpty: true)
                    }
                }
                networkGroup("Other Networks", rows: nearby.other)
                if nearby.current == nil && nearby.known.isEmpty && nearby.other.isEmpty {
                    Text("No Wi-Fi networks found").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            Text(scanFailed ? "Could not refresh Wi-Fi networks" : "Reading Wi-Fi networks…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var connectionDisclosure: some View {
        let expanded = store.connectionDetailsExpanded
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                store.connectionDetailsExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: wifi ? "wifi" : "cable.connector")
                        .font(.callout)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text("Connection Details")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: expanded)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(expanded ? Color.accentColor : .primary)
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(expanded ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(PanelActionStyle())
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityIdentifier("RingABar.network.disclosure")

            if expanded {
                VStack(alignment: .leading, spacing: 5) {
                    connectionRows(more: !wifi || store.showsMoreConnectionDetails)
                    if wifi, details != nil {
                        Button(store.showsMoreConnectionDetails ? "Show Less" : "Show More") {
                            store.showsMoreConnectionDetails.toggle()
                        }
                        .buttonStyle(PanelActionStyle())
                        .font(.caption)
                        .accessibilityValue(store.showsMoreConnectionDetails ? Text("Expanded") : Text("Collapsed"))
                        .accessibilityIdentifier("RingABar.network.more")
                    }
                }
                .padding(.leading, 26)
                .transition(PanelMotion.disclosureTransition(reduceMotion: reduceMotion))
            }
        }
        .clipped()
        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: expanded)
        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: store.showsMoreConnectionDetails)
    }

    @ViewBuilder private func networkGroup(_ title: LocalizedStringKey, rows: [NearbyWiFi.Row],
                                            current: String? = nil, showWhenEmpty: Bool = false) -> some View {
        if !rows.isEmpty || showWhenEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                VStack(spacing: 2) {
                    ForEach(rows) { row in
                        let isCurrent = connection.isCurrent(row, scannedCurrentID: current)
                        wifiRow(row, current: isCurrent)
                            .accessibilityIdentifier(isCurrent ? "RingABar.network.current" : "RingABar.network.nearby")
                    }
                }
            }
        }
    }

    private func wifiRow(_ row: NearbyWiFi.Row, current: Bool) -> some View {
        let signal = row.signal
        let bars: Double = signal >= 0 ? 0 : signal >= -70 ? 1 : signal >= -78 ? 0.67 : signal >= -88 ? 0.33 : 0
        let connecting = if case .connecting(let target) = connection.phase { target.id == row.id } else { false }
        let status: LocalizedStringKey = if connecting {
            "Connecting"
        } else if current {
            "Connected"
        } else {
            row.secured ? "Secured network" : "Wi-Fi network"
        }
        return Button {
            Task { await connection.join(row, currentSSID: nearby?.current?.ssidData) }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    if current {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: 16)
                .accessibilityHidden(true)
                Text(row.name)
                    .fontWeight(current ? .medium : .regular)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if row.secured {
                    Image(systemName: "lock.fill").font(.caption2)
                        .frame(width: 16)
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                }
                ZStack {
                    if connecting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: current && store.network.wifiIsHotspot ? "personalhotspot" : "wifi", variableValue: bars)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16)
                .accessibilityHidden(true)
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(PanelActionStyle())
        .disabled(current || connection.busy || scanning)
        .accessibilityLabel(Text(row.name))
        .accessibilityValue(Text(status))
        .accessibilityHint(row.security.supportsDirectJoin ? Text("Joins this Wi-Fi network.") : Text("Shows system Wi-Fi setup requirements."))
        .help(Text(verbatim: (current ? String(localized: "Connected") : row.security.supportsDirectJoin
                    ? String(localized: "Joins this Wi-Fi network.") : String(localized: "Shows system Wi-Fi setup requirements."))
                    + "\n" + String(localized: "Signal \(row.signal) dBm")))
    }

    @ViewBuilder private func connectionRows(more: Bool) -> some View {
        if let details {
            DetailGroup {
                if let interface = details.interface {
                    DetailValue(label: "Primary interface", value: interface, copyID: "RingABar.network.interface")
                }
                if let address = details.ipv4 {
                    DetailValue(label: "IPv4 address", value: address, copyID: "RingABar.network.copyIPv4")
                }
                if let address = details.ipv6 {
                    DetailValue(label: "IPv6 address", value: address, copyID: "RingABar.network.copyIPv6")
                }
                if let signal = store.network.signalDBm, wifi {
                    DetailValue(label: "Signal strength", value: String(localized: "\(signal) dBm"))
                }
                if more {
                    if let interface = store.network.interfaceName, interface != details.interface {
                        DetailValue(label: "Preferred path interface", value: interface)
                    }
                    if let router = details.router {
                        DetailValue(label: "Router", value: router, copyID: "RingABar.network.copyRouter")
                    }
                    if !details.dns.isEmpty {
                        DetailValue(label: "DNS servers", value: details.dns.joined(separator: "\n"), copyID: "RingABar.network.copyDNS")
                    }
                    if let channel = details.wifiChannel {
                        DetailValue(label: "Channel", value: [channel.formatted(), details.wifiBand].compactMap { $0 }.joined(separator: " · "))
                    }
                    if let rate = details.wifiRate {
                        DetailValue(label: "Link rate", value: String(localized: "\(Int(rate.rounded())) Mbps"))
                    }
                    if let noise = details.wifiNoise {
                        DetailValue(label: "Noise", value: String(localized: "\(noise) dBm"))
                    }
                    if !details.activeVPNs.isEmpty {
                        DetailValue(label: "System VPN", value: details.activeVPNs.joined(separator: ", "))
                    }
                    DetailValue(label: "System proxy", value: details.systemProxy?.displayValue ?? String(localized: "Off"))
                }
            }
        } else {
            ProgressView("Reading network details…").controlSize(.small)
        }
    }
}

private struct AudioDirectionControl: NSViewRepresentable {
    @Binding var selection: AudioDirection
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: AudioDirection.allCases.map(\.title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.select(_:))
        )
        control.segmentDistribution = .fillEqually
        control.setAccessibilityLabel(String(localized: "Audio direction"))
        control.setAccessibilityIdentifier("RingABar.audio.direction")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = selection == .output ? 0 : 1
        control.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<AudioDirection>

        init(selection: Binding<AudioDirection>) {
            self.selection = selection
        }

        @objc func select(_ sender: NSSegmentedControl) {
            let segment = sender.selectedSegment
            guard AudioDirection.allCases.indices.contains(segment) else { return }
            selection.wrappedValue = AudioDirection.allCases[segment]
        }
    }
}

struct AudioPage<OutputControls: View>: View {
    let store: StatusStore
    let preferences: Preferences
    let monitor: AudioMonitor
    let picker: AudioDevicePicker
    let outputControls: OutputControls
    let height: PanelHeightReporter
    let navigationFocus: FocusState<PanelNavigationFocus?>.Binding
    let onBack: () -> Void
    let onOpenSettings: () -> Void
    let onOpenAppSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var direction: AudioDirection { store.audioDirection }

    var body: some View {
        @Bindable var store = store
        let spacing: CGFloat = 10
        let selectorHeight: CGFloat = 24
        return DetailPanel(height: height, headerHeight: PageHeader<EmptyView>.height + spacing + selectorHeight,
                           spacing: spacing, scrollContentID: direction.rawValue) {
            VStack(alignment: .leading, spacing: spacing) {
                PageHeader(title: "Audio", navigationFocus: navigationFocus, onBack: onBack) {
                    Button(action: onOpenAppSettings) {
                        DetailHeaderAction(symbol: "gearshape")
                    }
                    .buttonStyle(PanelActionStyle(cornerRadius: StatusPanel.summaryActionWidth / 2))
                    .help("TrioRing Audio Settings…")
                    .accessibilityLabel("TrioRing Audio Settings…")
                    .accessibilityIdentifier("RingABar.audio.appSettings")
                }
                AudioDirectionControl(selection: $store.audioDirection)
                    .frame(maxWidth: .infinity)
                    .frame(height: selectorHeight)
                    .disabled(picker.pendingID != nil || picker.inputMutePending)
            }
        } content: {
            audioContent
                .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: direction)
        }
        .preference(key: PanelReadyLayoutKey.self, value: picker.routes != nil ? store.panelLayout : nil)
    }

    private var audioContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if direction == .output {
                if !store.audio.canSetVolume, store.audio.deviceID != nil {
                    Text("Volume controlled by device").font(.callout).foregroundStyle(.secondary)
                }
                outputControls
            } else if let mute = picker.inputMute {
                inputControls(mute)
                    .id(mute.uid)
            }

            if let routes = picker.routes {
                let devices = preferences.audioDevices(in: routes, for: direction)
                if direction == .input {
                    inputDeviceList(devices, current: routes.inputs.first { $0.id == routes.inputID }?.name)
                } else {
                    deviceList(devices)
                    if let output = picker.airPodsOutput, output.deviceID == store.audio.deviceID {
                        AirPodsControls(output: output, picker: picker, monitor: monitor)
                            .id(output.uid)
                    }
                }
            } else {
                ProgressView("Reading audio devices…").controlSize(.small)
            }

            if picker.failedDirection == direction {
                Text("Could not switch audio device.").font(.caption).foregroundStyle(.red)
            }
            Divider()
            DetailSettingsLink("System Sound Settings…", id: "RingABar.audio.systemSettings", action: onOpenSettings)
        }
    }

    private func inputDeviceList(_ devices: [AudioRoute], current: String?) -> some View {
        let expanded = store.inputDevicesExpanded
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                store.inputDevicesExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text("Input devices")
                    Spacer(minLength: 0)
                    if !expanded, let current {
                        Text(current)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: expanded)
                        .accessibilityHidden(true)
                }
                .font(.callout)
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PanelActionStyle())
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityIdentifier("RingABar.audio.inputDisclosure")
            if expanded {
                deviceList(devices)
                    .transition(PanelMotion.disclosureTransition(reduceMotion: reduceMotion))
            }
        }
        .clipped()
        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: expanded)
    }

    @ViewBuilder private func deviceList(_ devices: [AudioRoute]) -> some View {
        if devices.isEmpty {
            Text("No available devices").font(.callout).foregroundStyle(.secondary)
        } else if devices.count <= 5 {
            deviceRows(devices)
        } else {
            ScrollView { deviceRows(devices) }
                .frame(height: 5 * AudioDeviceRows.rowHeight)
                .background(StableScrollViewport())
        }
    }

    private func deviceRows(_ devices: [AudioRoute]) -> some View {
        AudioDeviceRows(devices: devices, direction: direction, picker: picker, monitor: monitor,
                        isPanelVisible: store.panelVisible)
    }

    private func inputControls(_ mute: AudioInputMute) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                inputMuteButton(mute)
                if let gain = picker.inputGain, gain.uid == mute.uid, gain.canSet {
                    Slider(value: Binding(
                        get: { picker.displayedInputGain(gain) },
                        set: { picker.setInputGain($0, on: gain, using: monitor) }
                    ), in: 0...1) {
                        Text("Microphone gain")
                    }
                    .labelsHidden()
                    .tint(mute.state == .muted ? .secondary : .accentColor)
                    .disabled(picker.pendingID != nil)
                    .accessibilityIdentifier("RingABar.audio.inputGain")
                    Text(picker.displayedInputGain(gain), format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 32, alignment: .trailing)
                        .accessibilityHidden(true)
                } else {
                    Text("Microphone gain controlled by device")
                        .font(.caption)
                        .accessibilityIdentifier("RingABar.audio.inputGainUnavailable")
                }
            }
            .foregroundStyle(.secondary)
            if picker.failedInputGain {
                Text("Could not change microphone gain.").font(.caption).foregroundStyle(.red)
            }
            if picker.failedInputMute {
                Text("Could not change microphone mute.").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func inputMuteButton(_ mute: AudioInputMute) -> some View {
        let action: LocalizedStringKey = mute.state == .muted ? "Unmute microphone" : "Mute microphone"
        let state: LocalizedStringKey = switch mute.state {
        case .muted: "Muted"
        case .unmuted: "Not muted"
        case .partial: "Partially muted"
        case nil: "Unavailable"
        }
        return Button { picker.toggleInputMute(using: monitor) } label: {
            ZStack {
                if picker.inputMutePending {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: mute.state == .muted ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(mute.state == .muted ? Color.accentColor : .secondary)
                    if mute.state == .partial {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 8, weight: .bold))
                            .offset(x: 7, y: -6)
                    }
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
        }
        .buttonStyle(PanelActionStyle())
        .disabled(!mute.canSet || picker.inputMutePending || picker.pendingID != nil)
        .help(mute.canSet ? Text(action) : Text("Microphone mute unavailable"))
        .accessibilityLabel(mute.canSet ? Text(action) : Text("Microphone mute unavailable"))
        .accessibilityValue(Text(state))
        .accessibilityIdentifier("RingABar.audio.inputMute")
    }
}
