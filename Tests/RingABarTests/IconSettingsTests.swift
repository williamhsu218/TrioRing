import Foundation
import Testing
@testable import RingABar

@MainActor
struct IconSettingsTests {
    @Test func legacyPreferencesKeepTheirAppearanceAndNewSettingsRoundTrip() throws {
        let suite = "TrioRingTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(false, forKey: "icon.showsBatteryValue")
        defaults.set("bold", forKey: "icon.ringWeight")
        defaults.set("arc", forKey: "icon.volumeIndicator")
        defaults.set(true, forKey: "icon.showsWiFiForWired")
        let old = IconPreferences(defaults: defaults)
        #expect(old.onBatteryMarker == .hidden)
        #expect(old.chargingMarker == .bolt)
        #expect(old.connectedMarker == .plug)
        #expect(old.ringWeight == .bold)
        #expect(old.volumeIndicator == .arc)
        #expect(old.showsWiFiForWired)
        #expect(old.showsWiFiForHotspot)
        #expect(old.menuBarSize == 24)
        #expect(old.middleSize == 160)

        var updated = old
        updated.onBatteryMarker = .percentage
        updated.connectedMarker = .percentage
        updated.menuBarSize = 36
        updated.middleSource = .power
        updated.middleSize = 100
        updated.splitsProgress = true
        updated.usesBlueForBluetoothVolume = true
        updated.save(to: defaults)
        #expect(IconPreferences(defaults: defaults) == updated)
        #expect(defaults.bool(forKey: "icon.showsBatteryValue"))
    }

    @Test func accentLayerTracksChargingAndBluetoothIndependently() {
        var preferences = IconPreferences()
        let battery = BatteryReading(percent: 80, pluggedIn: true, chargeLimit: 80)
        let audio = AudioStatus(volume: 0.5, isBluetooth: true)
        func icon(_ reading: BatteryReading) -> StatusIcon {
            StatusIcon(battery: .battery(reading), network: .init(), audio: audio, preferences: preferences)
        }

        #expect(icon(battery).image(layer: .accent) == nil)
        var charging = battery
        charging.charging = true
        #expect(icon(charging).image(layer: .accent) != nil)
        preferences.monochromeCharging = true
        #expect(icon(charging).image(layer: .accent) == nil)
        preferences.usesBlueForBluetoothVolume = true
        #expect(icon(battery).image(layer: .accent) != nil)
    }

    @Test func splitProgressDoesNotSpendChargeInTheMarkerGap() {
        let gap = StatusIconGeometry.batteryValueTopGapWidth
        #expect(StatusIconGeometry.splitFillProgress(0, topGapWidth: gap) == 0)
        #expect(StatusIconGeometry.splitFillProgress(1, topGapWidth: gap) == 1)
        #expect(StatusIconGeometry.splitFillProgress(0.49, topGapWidth: gap) < 0.49)
        #expect(StatusIconGeometry.splitFillProgress(0.51, topGapWidth: gap) > 0.51)
        #expect(StatusIconGeometry.splitFillProgress(0.8, topGapWidth: 0) == 0.8)
    }
}
