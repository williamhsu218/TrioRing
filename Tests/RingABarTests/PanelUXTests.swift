import Foundation
import Testing
@testable import RingABar

@MainActor
struct PanelUXTests {
    @Test func unsetScrollScopeDefaultsToSliderWithoutChangingOtherDefaults() throws {
        let suite = "TrioRingTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.scrollOnVolumeSliderOnly)
        #expect(preferences.scrollToAdjustVolume)
        #expect(!preferences.naturalVolumeScroll)
        // Reading an unset preference must not manufacture an explicit choice.
        #expect(defaults.object(forKey: "audio.scrollOnSliderOnly") == nil)
    }

    @Test(arguments: [true, false])
    func savedScrollScopeIsPreservedAndChangesRoundTrip(sliderOnly: Bool) throws {
        let suite = "TrioRingTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(sliderOnly, forKey: "audio.scrollOnSliderOnly")
        let preferences = Preferences(defaults: defaults)
        #expect(preferences.scrollOnVolumeSliderOnly == sliderOnly)
        preferences.scrollOnVolumeSliderOnly.toggle()
        #expect(Preferences(defaults: defaults).scrollOnVolumeSliderOnly == !sliderOnly)
    }

    @Test func layoutPreviewOrderAndVisibilitySharePersistedSummaryPreferences() throws {
        let suite = "TrioRingTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.move(.audio, by: -1)
        preferences.move(.audio, by: -1)
        preferences.setVisible(false, section: .network)
        #expect(preferences.visibleSections == [.audio, .battery])
        #expect(Preferences(defaults: defaults).visibleSections == [.audio, .battery])
        for section in PanelSection.allCases { preferences.setVisible(false, section: section) }
        #expect(preferences.visibleSections.isEmpty)
    }

    @Test func mutedVolumeKeepsItsRestoreLevel() {
        var audio = AudioStatus(volume: 0.625, muted: true)
        #expect(audio.percent == 63)
        audio.muted = false
        #expect(audio.percent == 63)
        audio.volume = nil
        #expect(audio.percent == nil)
    }

    @Test(arguments: Array(0...6))
    func diagramHeightDependsOnCountNotPowerShare(count: Int) {
        func diagram(_ watts: Double) -> BatteryPowerFlowView {
            BatteryPowerFlowView(state: BatteryPowerFlowState(
                input: .init(label: "Charger input", value: "100 W", watts: 100, kind: .input),
                destinations: (0..<count).map { index in
                    .init(label: "USB-C \(index)", value: "\(watts) W", watts: watts, kind: .usb)
                }))
        }
        let small = diagram(0.2).diagramHeight
        #expect(small == diagram(80).diagramHeight)
        #expect(small >= 84)
        #expect(small >= Double(count) * BatteryPowerFlowView.branchRowHeight)
    }

    @Test func splitLabelsIdentifyPortsAndEstimatesWithoutLosingDeviceNames() throws {
        let now = Date()
        let ports = [USBPortOutput(channel: 2, watts: 2, name: "Long accessory name +1",
                                   deviceNames: ["Long accessory name", "Second accessory"])]
        let split = BatteryPowerBreakdown(
            source: .adapter, sourceWatts: 30, chargingWatts: 10,
            display: .init(watts: 0.2, readAt: now),
            usb: .init(watts: 2, readAt: now), usbPorts: ports, inputPortType: "MagSafe 3",
            system: .init(watts: 17.8, readAt: now), readAt: now)
        let snapshot = BatteryPowerSnapshot(inputWatts: 30, battery: nil, systemWatts: 17.8,
            temperatureCelsius: nil, displayWatts: 0.2, usbPorts: ports,
            inputPortType: "MagSafe 3", breakdown: split)
        let flow = try #require(snapshot.flow)
        let usb = try #require(flow.destinations.first { $0.kind == .usb })
        #expect(usb.label == ports[0].channelLabel)
        #expect(usb.help?.contains("Long accessory name") == true)
        #expect(usb.help?.contains("Second accessory") == true)
        #expect(flow.system?.label == String(localized: "System power (est.)"))
        #expect(flow.system?.help == String(localized: "Estimated system power (SoC, DRAM, Display Controller, and residual load)"))
        #expect(flow.input?.detail == "MagSafe 3")
        // Tiny branches still have a name; nothing is removed below 1%.
        #expect(flow.destinations.first { $0.kind == .display }?.label == String(localized: "Display"))
    }

    @Test func measuredFallbackSystemTotalIsNotRelabeledAsEstimate() {
        let snapshot = BatteryPowerSnapshot(inputWatts: nil, battery: nil, systemWatts: 12,
            temperatureCelsius: nil, displayWatts: nil, usbPorts: [], inputPortType: nil, breakdown: nil)
        #expect(snapshot.flow?.system?.label == String(localized: "System total"))
    }

    @Test @MainActor func settingsSidebarSelectionResetsIconLeafToOverallAndCancelsShortcutOutsideGeneral() {
        let store = StatusStore()
        var cancelCalls = 0
        let cancel = { cancelCalls += 1 }

        SettingsView.applySidebarSelection(.icon(.top), to: store, onCancelShortcut: cancel)
        #expect(store.settingsCategory == .icon)
        #expect(store.settingsIconLeaf == .top)
        #expect(SettingsView.resolvedSidebarSelection(store: store) == .icon(.top))
        #expect(cancelCalls == 1)

        // Clicking the top "App Icon" header while already on an icon sub-leaf must reset to .overall
        SettingsView.applySidebarSelection(.category(.icon), to: store, onCancelShortcut: cancel)
        #expect(store.settingsCategory == .icon)
        #expect(store.settingsIconLeaf == .overall)
        #expect(SettingsView.resolvedSidebarSelection(store: store) == .icon(.overall))
        #expect(cancelCalls == 2)

        // Selecting .general must preserve active shortcut recording
        SettingsView.applySidebarSelection(.category(.general), to: store, onCancelShortcut: cancel)
        #expect(store.settingsCategory == .general)
        #expect(SettingsView.resolvedSidebarSelection(store: store) == .category(.general))
        #expect(cancelCalls == 2)

        // Selecting any non-general category must cancel shortcut recording
        SettingsView.applySidebarSelection(.category(.panel), to: store, onCancelShortcut: cancel)
        #expect(store.settingsCategory == .panel)
        #expect(SettingsView.resolvedSidebarSelection(store: store) == .category(.panel))
        #expect(cancelCalls == 3)

        // Nil selection leaves state untouched
        SettingsView.applySidebarSelection(nil, to: store, onCancelShortcut: cancel)
        #expect(store.settingsCategory == .panel)
        #expect(cancelCalls == 3)
    }

    @Test func zhHansStringsContainCurrentSystemPowerEstimateKey() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings")
        let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
        #expect(table["Estimated system power (SoC, DRAM, Display Controller, and residual load)"] != nil)
        #expect(table["Estimated system power (remainder)"] == nil)
    }
}
