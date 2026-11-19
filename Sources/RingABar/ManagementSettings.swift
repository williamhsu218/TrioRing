import AppKit
import SwiftUI

struct BatterySettingsPane: View {
    @Bindable var preferences: Preferences
    let store: StatusStore
    let actions: BatteryActions

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard {
                if let reading = store.battery.reading {
                    SettingsRow(title: "Current charge", subtitle: "The ring shows actual charge on a 0–100% scale.",
                                symbol: "battery.100percent", tint: .green) {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(Double(reading.percent) / 100, format: .percent).monospacedDigit()
                            if let limit = actions.temporarilyOverriddenLimit ?? actions.currentChargeLimit ?? reading.chargeLimit,
                               limit < 100 {
                                Text("Limit \(limit)%").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    SettingsRule()
                }
                PowerModeAccessRow(authorization: actions.powerAuthorization)
            }
            SettingsCard("Panel") {
                SettingsToggle(title: "Show Battery in the status panel",
                               subtitle: "Control whether this module appears in the status panel.",
                               symbol: "battery.100percent", tint: .green, isOn: Binding(
                                   get: { preferences.visibleSections.contains(.battery) },
                                   set: { preferences.setVisible($0, section: .battery) }
                               ), id: "RingABar.settings.showBattery")
            }
            SettingsCard("Charging Management") {
                SettingsToggle(title: "Show Charge to Full Now in the summary",
                               subtitle: "Show the macOS action to temporarily charge past an eligible limit or pause.",
                               symbol: "bolt.badge.clock.fill", tint: .green,
                               isOn: $preferences.showsChargeAction, id: "RingABar.settings.showChargeAction")
                if actions.showsCalibrationStatus {
                    SettingsRule()
                    BatteryCalibrationRow(status: actions.calibration.status)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                }
                if let reading = store.battery.reading, !actions.availableChargeLimits.isEmpty {
                    SettingsRule()
                    ChargeLimitControls(actions: actions, reading: reading)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                }
                FullChargeRow(actions: actions, reading: store.battery.reading,
                              onSystemSettings: { NSWorkspace.shared.open(SystemSettingsPane.battery.url) })
                    .padding(.horizontal, 13)
            }
            SettingsCard("Power Modes") {
                SettingsToggle(title: "Show Power Mode in the summary",
                               subtitle: "Change the current power profile from the status panel.",
                               symbol: "leaf.fill", tint: .green,
                               isOn: $preferences.showsPowerMode, id: "RingABar.settings.showPowerMode")
                SettingsRule()
                PowerModeRow(actions: actions, reading: store.battery.reading, showsContext: true)
                    .padding(.horizontal, 13).padding(.vertical, 9)
            }
            SettingsCard("Power Flow") {
                SettingsToggle(title: "Show power flow diagram",
                               subtitle: "Show input and output power in Battery Details.",
                               symbol: "arrow.triangle.branch", tint: .orange,
                               isOn: $preferences.showsPowerFlow, id: "RingABar.settings.showPowerFlow")
                SettingsNote(title: "USB readings are per port. Accessories behind a hub share its reading.")
            }
        }
        .task(id: store.settingsVisible) {
            while store.settingsVisible && !Task.isCancelled {
                await actions.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

struct NetworkSettingsPane: View {
    @Bindable var preferences: Preferences
    let access: WiFiLocationAccess
    let store: StatusStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if store.network.wifiPowered != nil && !access.allowed {
                SettingsCard {
                    SettingsRow(title: "Wi-Fi Access",
                                subtitle: "macOS requires Location Services to show Wi-Fi names and nearby networks.",
                                symbol: "location.fill", tint: .blue) {
                        Button(access.status == .notDetermined ? "Allow Access…" : "Open Location Settings…") {
                            if !access.request() { NSWorkspace.shared.open(SystemSettingsPane.location.url) }
                        }
                        .accessibilityIdentifier("RingABar.settings.wifiLocation")
                    }
                }
            }
            SettingsCard("Panel") {
                SettingsToggle(title: "Show Network in the status panel",
                               subtitle: "Control whether this module appears in the status panel.",
                               symbol: "wifi", tint: .blue, isOn: Binding(
                                   get: { preferences.visibleSections.contains(.network) },
                                   set: { preferences.setVisible($0, section: .network) }
                               ), id: "RingABar.settings.showNetwork")
                if store.network.wifiPowered != nil {
                    SettingsRule()
                    SettingsToggle(title: "Show Wi-Fi power control",
                                   subtitle: "Show the Wi-Fi switch in the summary and details.",
                                   symbol: "power.circle", tint: .blue,
                                   isOn: $preferences.showsWiFiPower, id: "RingABar.settings.showWiFiPower")
                    SettingsRule()
                    SettingsToggle(title: "Confirm before turning off connected Wi-Fi",
                                   subtitle: "Ask before disconnecting from the current Wi-Fi network.",
                                   symbol: "exclamationmark.circle", tint: .blue,
                                   isOn: $preferences.confirmsWiFiOff, id: "RingABar.settings.confirmWiFiOff")
                        .disabled(!preferences.showsWiFiPower)
                }
                SettingsRule()
                SettingsToggle(title: "Show local IP in the summary",
                               subtitle: "Show the current local IP below the network name.",
                               symbol: "network", tint: .cyan,
                               isOn: $preferences.showsLocalIP, id: "RingABar.settings.showLocalIP")
                SettingsRule()
                SettingsToggle(title: "Show VPN and proxy status",
                               subtitle: "Show a separate row for VPN or proxy status.",
                               symbol: "shield.lefthalf.filled", tint: .indigo,
                               isOn: $preferences.showsVPN, id: "RingABar.settings.showVPN")
            }
            SettingsCard("System Settings") {
                HStack(spacing: 8) {
                    Button("Open Wi-Fi Settings") { NSWorkspace.shared.open(SystemSettingsPane.wifi.url) }
                    Button("Open Network Settings") { NSWorkspace.shared.open(SystemSettingsPane.network.url) }
                    Button("Open System VPN Settings") { NSWorkspace.shared.open(SystemSettingsPane.vpn.url) }
                }
                .padding(13)
            }
        }
    }
}
