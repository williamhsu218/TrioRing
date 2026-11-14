import Foundation
import Observation

enum VolumeIndicator: String, CaseIterable, Identifiable {
    case dots, arc

    var id: String { rawValue }
    var title: String {
        switch self {
        case .dots: String(localized: "Dots")
        case .arc: String(localized: "Arc")
        }
    }
}

enum RingWeight: String, CaseIterable, Identifiable {
    case light, regular, bold

    var id: String { rawValue }
    var scale: CGFloat {
        switch self {
        case .light: 1
        case .regular: 1.25
        case .bold: 1.5
        }
    }
    var title: String {
        switch self {
        case .light: String(localized: "Light")
        case .regular: String(localized: "Regular")
        case .bold: String(localized: "Bold")
        }
    }
}

enum TopMarker: String, CaseIterable, Identifiable {
    case percentage, bolt, plug, hidden

    var id: Self { self }
    var title: String {
        switch self {
        case .percentage: String(localized: "Percentage")
        case .bolt: String(localized: "Bolt")
        case .plug: String(localized: "Plug")
        case .hidden: String(localized: "Hidden")
        }
    }
}

enum MiddleIconSource: String, CaseIterable, Identifiable {
    case network, bluetooth, inputSource, batteryPercentage, power, chargingStatus

    var id: Self { self }
    var title: String {
        switch self {
        case .network: String(localized: "Network")
        case .bluetooth: String(localized: "Bluetooth Device")
        case .inputSource: String(localized: "Current Input Source")
        case .batteryPercentage: String(localized: "Battery Percentage")
        case .power: String(localized: "Power (Watts)")
        case .chargingStatus: String(localized: "Charging status")
        }
    }
}

struct IconPreferences: Equatable {
    var menuBarSize = 24
    var ringWeight = RingWeight.regular
    var onBatteryMarker = TopMarker.percentage
    var chargingMarker = TopMarker.bolt
    var connectedMarker = TopMarker.plug
    var noBatteryMarker = TopMarker.plug
    var markerSize = 100
    var splitsProgress = false
    var usesBatteryColors = true
    var monochromeCharging = false
    var criticalLevel = 20
    var middleSource = MiddleIconSource.network
    var middleSize = 160
    var prioritizesNetworkWarnings = true
    var showsWiFiForWired = false
    var showsWiFiForHotspot = false
    var volumeIndicator = VolumeIndicator.dots
    var usesBlueForBluetoothVolume = false

    static let menuBarSizes = 16...36
    static let markerSizes = 90...110
    static let middleSizes = 100...180
    static let criticalLevels = 0...100

    init() {}

    init(defaults: UserDefaults) {
        func option<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            defaults.string(forKey: "icon." + key).flatMap(T.init(rawValue:)) ?? fallback
        }
        func bounded(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
            let value = defaults.object(forKey: "icon." + key) as? Int ?? fallback
            return min(range.upperBound, max(range.lowerBound, value))
        }
        menuBarSize = bounded("menuBarSize", menuBarSize, Self.menuBarSizes)
        ringWeight = option("ringWeight", ringWeight)
        let legacyBatteryValue = defaults.object(forKey: "icon.showsBatteryValue") as? Bool ?? true
        onBatteryMarker = option("onBatteryMarker", legacyBatteryValue ? .percentage : .hidden)
        chargingMarker = option("chargingMarker", chargingMarker)
        connectedMarker = option("connectedMarker", connectedMarker)
        noBatteryMarker = option("noBatteryMarker", noBatteryMarker)
        markerSize = bounded("markerSize", markerSize, Self.markerSizes)
        splitsProgress = defaults.bool(forKey: "icon.splitsProgress")
        usesBatteryColors = defaults.object(forKey: "icon.usesBatteryColors") as? Bool ?? true
        monochromeCharging = defaults.bool(forKey: "icon.monochromeCharging")
        criticalLevel = bounded("criticalLevel", criticalLevel, Self.criticalLevels)
        middleSource = option("middleSource", middleSource)
        middleSize = bounded("middleSize", middleSize, Self.middleSizes)
        prioritizesNetworkWarnings = defaults.object(forKey: "icon.prioritizesNetworkWarnings") as? Bool ?? true
        showsWiFiForWired = defaults.bool(forKey: "icon.showsWiFiForWired")
        // Existing builds used the standard Wi-Fi glyph for hotspots.
        showsWiFiForHotspot = defaults.object(forKey: "icon.showsWiFiForHotspot") as? Bool ?? true
        volumeIndicator = option("volumeIndicator", volumeIndicator)
        usesBlueForBluetoothVolume = defaults.bool(forKey: "icon.usesBlueForBluetoothVolume")
    }

    func save(to defaults: UserDefaults) {
        defaults.set(menuBarSize, forKey: "icon.menuBarSize")
        defaults.set(ringWeight.rawValue, forKey: "icon.ringWeight")
        defaults.set(onBatteryMarker.rawValue, forKey: "icon.onBatteryMarker")
        defaults.set(onBatteryMarker == .percentage, forKey: "icon.showsBatteryValue")
        defaults.set(chargingMarker.rawValue, forKey: "icon.chargingMarker")
        defaults.set(connectedMarker.rawValue, forKey: "icon.connectedMarker")
        defaults.set(noBatteryMarker.rawValue, forKey: "icon.noBatteryMarker")
        defaults.set(markerSize, forKey: "icon.markerSize")
        defaults.set(splitsProgress, forKey: "icon.splitsProgress")
        defaults.set(usesBatteryColors, forKey: "icon.usesBatteryColors")
        defaults.set(monochromeCharging, forKey: "icon.monochromeCharging")
        defaults.set(criticalLevel, forKey: "icon.criticalLevel")
        defaults.set(middleSource.rawValue, forKey: "icon.middleSource")
        defaults.set(middleSize, forKey: "icon.middleSize")
        defaults.set(prioritizesNetworkWarnings, forKey: "icon.prioritizesNetworkWarnings")
        defaults.set(showsWiFiForWired, forKey: "icon.showsWiFiForWired")
        defaults.set(showsWiFiForHotspot, forKey: "icon.showsWiFiForHotspot")
        defaults.set(volumeIndicator.rawValue, forKey: "icon.volumeIndicator")
        defaults.set(usesBlueForBluetoothVolume, forKey: "icon.usesBlueForBluetoothVolume")
    }
}

enum PanelSection: String, CaseIterable, Identifiable, Sendable {
    case battery, network, audio

    var id: Self { self }

    var title: String {
        switch self {
        case .battery: String(localized: "Battery")
        case .network: String(localized: "Network")
        case .audio: String(localized: "Audio")
        }
    }

    var symbol: String {
        switch self {
        case .battery: "battery.100percent"
        case .network: "wifi"
        case .audio: "speaker.wave.2.fill"
        }
    }
}

@MainActor
@Observable
final class Preferences {
    private let defaults: UserDefaults
    @ObservationIgnored var onIconChange: (() -> Void)?

    private static let panelShortcutKey = "general.panelShortcut"

    var panelShortcut: StatusPanelShortcut? {
        didSet {
            guard let panelShortcut else {
                defaults.removeObject(forKey: Self.panelShortcutKey)
                return
            }
            if let encoded = try? JSONEncoder().encode(panelShortcut) {
                defaults.set(encoded, forKey: Self.panelShortcutKey)
            }
        }
    }

    var icon: IconPreferences {
        didSet {
            guard icon != oldValue else { return }
            icon.save(to: defaults)
            onIconChange?()
        }
    }

    var showsChargeAction: Bool {
        didSet { defaults.set(showsChargeAction, forKey: "battery.showsChargeAction") }
    }
    var showsPowerMode: Bool {
        didSet { defaults.set(showsPowerMode, forKey: "battery.showsPowerMode") }
    }
    var showsPowerFlow: Bool {
        didSet { defaults.set(showsPowerFlow, forKey: "battery.showsPowerFlow") }
    }
    var showsWiFiPower: Bool {
        didSet { defaults.set(showsWiFiPower, forKey: "network.showsWiFiPower") }
    }
    var confirmsWiFiOff: Bool {
        didSet { defaults.set(confirmsWiFiOff, forKey: "network.confirmsWiFiOff") }
    }
    var showsLocalIP: Bool {
        didSet { defaults.set(showsLocalIP, forKey: "network.showsLocalIP") }
    }
    var showsVPN: Bool {
        didSet { defaults.set(showsVPN, forKey: "network.showsVPN") }
    }

    var scrollToAdjustVolume: Bool {
        didSet { defaults.set(scrollToAdjustVolume, forKey: "panel.scrollToAdjustVolume") }
    }
    var scrollOnVolumeSliderOnly: Bool {
        didSet { defaults.set(scrollOnVolumeSliderOnly, forKey: "audio.scrollOnSliderOnly") }
    }
    var naturalVolumeScroll: Bool {
        didSet { defaults.set(naturalVolumeScroll, forKey: "audio.naturalVolumeScroll") }
    }
    private(set) var audioOrder: [AudioDirection: [String]]
    private(set) var hiddenAudio: [AudioDirection: Set<String>]
    var opensWithExpandedAudio: Bool {
        didSet { defaults.set(opensWithExpandedAudio, forKey: "panel.opensWithExpandedAudio") }
    }
    private(set) var panelOrder: [PanelSection] {
        didSet { defaults.set(panelOrder.map(\.rawValue), forKey: "panel.order") }
    }
    private(set) var hiddenSections: Set<PanelSection> {
        didSet {
            defaults.set(PanelSection.allCases.filter(hiddenSections.contains).map(\.rawValue), forKey: "panel.hiddenSections")
        }
    }

    var visibleSections: [PanelSection] {
        panelOrder.filter { !hiddenSections.contains($0) }
    }

    func setVisible(_ visible: Bool, section: PanelSection) {
        if visible { hiddenSections.remove(section) }
        else { hiddenSections.insert(section) }
    }

    func move(_ section: PanelSection, by offset: Int) {
        guard let index = panelOrder.firstIndex(of: section), panelOrder.indices.contains(index + offset) else { return }
        panelOrder.swapAt(index, index + offset)
    }

    func audioDevices(in routes: AudioRoutes, for direction: AudioDirection, includeHidden: Bool = false) -> [AudioRoute] {
        let devices = routes.devices(for: direction)
        let saved = audioOrder[direction] ?? []
        let positions = saved.enumerated().reduce(into: [String: Int]()) { result, pair in
            if result[pair.element] == nil { result[pair.element] = pair.offset }
        }
        let ordered = devices.enumerated().sorted { lhs, rhs in
            let left = positions[lhs.element.uid] ?? Int.max
            let right = positions[rhs.element.uid] ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
        if includeHidden { return ordered }
        let hidden = hiddenAudio[direction] ?? []
        return ordered.filter { $0.id == routes.selectedID(for: direction) || !hidden.contains($0.uid) }
    }

    func setAudioDeviceVisible(_ visible: Bool, uid: String, direction: AudioDirection) {
        var hidden = hiddenAudio[direction] ?? []
        if visible { hidden.remove(uid) } else { hidden.insert(uid) }
        hiddenAudio[direction] = hidden
        defaults.set(hidden.sorted(), forKey: "audio.\(direction.rawValue).hidden")
    }

    func moveAudioDevice(_ device: AudioRoute, by offset: Int, in routes: AudioRoutes, direction: AudioDirection) {
        var connected = audioDevices(in: routes, for: direction, includeHidden: true).map(\.uid)
        guard let index = connected.firstIndex(of: device.uid), connected.indices.contains(index + offset) else { return }
        connected.swapAt(index, index + offset)
        let online = Set(connected)
        var saved = audioOrder[direction] ?? []
        let ranked = Set(saved)
        saved.append(contentsOf: connected.filter { !ranked.contains($0) })
        var newOrder = connected.makeIterator()
        saved = saved.map { online.contains($0) ? newOrder.next() ?? $0 : $0 }
        audioOrder[direction] = saved
        defaults.set(saved, forKey: "audio.\(direction.rawValue).order")
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        panelShortcut = defaults.data(forKey: Self.panelShortcutKey).flatMap {
            try? JSONDecoder().decode(StatusPanelShortcut.self, from: $0)
        }
        icon = IconPreferences(defaults: defaults)
        showsChargeAction = defaults.object(forKey: "battery.showsChargeAction") as? Bool ?? true
        showsPowerMode = defaults.object(forKey: "battery.showsPowerMode") as? Bool ?? true
        showsPowerFlow = defaults.object(forKey: "battery.showsPowerFlow") as? Bool ?? true
        showsWiFiPower = defaults.object(forKey: "network.showsWiFiPower") as? Bool ?? true
        confirmsWiFiOff = defaults.object(forKey: "network.confirmsWiFiOff") as? Bool ?? true
        showsLocalIP = defaults.bool(forKey: "network.showsLocalIP")
        showsVPN = defaults.object(forKey: "network.showsVPN") as? Bool ?? true
        scrollToAdjustVolume = defaults.object(forKey: "panel.scrollToAdjustVolume") as? Bool ?? true
        // Keep an explicitly chosen panel-wide scope, but make new/unset
        // preferences safe against scrolling over unrelated status controls.
        scrollOnVolumeSliderOnly = defaults.object(forKey: "audio.scrollOnSliderOnly") as? Bool ?? true
        naturalVolumeScroll = defaults.bool(forKey: "audio.naturalVolumeScroll")
        audioOrder = Dictionary(uniqueKeysWithValues: AudioDirection.allCases.map { direction in
            let stored = defaults.stringArray(forKey: "audio.\(direction.rawValue).order") ?? []
            var seen = Set<String>()
            return (direction, stored.filter { seen.insert($0).inserted })
        })
        hiddenAudio = Dictionary(uniqueKeysWithValues: AudioDirection.allCases.map { direction in
            (direction, Set(defaults.stringArray(forKey: "audio.\(direction.rawValue).hidden") ?? []))
        })
        opensWithExpandedAudio = defaults.bool(forKey: "panel.opensWithExpandedAudio")
        var order: [PanelSection] = []
        for rawValue in defaults.stringArray(forKey: "panel.order") ?? [] {
            if let section = PanelSection(rawValue: rawValue), !order.contains(section) {
                order.append(section)
            }
        }
        panelOrder = order + PanelSection.allCases.filter { !order.contains($0) }
        hiddenSections = Set((defaults.stringArray(forKey: "panel.hiddenSections") ?? []).compactMap(PanelSection.init(rawValue:)))
    }
}
