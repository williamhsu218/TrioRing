import SwiftUI

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
        let bars = WiFiSignalStrength.variableValue(for: row.signal)
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
