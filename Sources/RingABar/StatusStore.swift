import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class StatusStore {
    // MARK: - Telemetry State
    var battery = BatteryStatus.unavailable
    var network = NetworkStatus()
    var audio = AudioStatus()
    var vpn = VPNStatus()
    var localIP: String?
    var maximumMenuBarIconSize = IconPreferences.menuBarSizes.upperBound
    var iconInputSource: String?
    var iconSystemWatts: Int?

    // MARK: - Panel Navigation & Presentation State
    let wifiConnection = WiFiConnectionController()
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
    var connectionDisclosureOverride: Bool?
    var showsMoreConnectionDetails = false
    var batteryReadingsExpanded = false
    var batteryInfoVisible = false {
        didSet {
            if oldValue != batteryInfoVisible { batteryInfoFocusChange = ProcessInfo.processInfo.systemUptime }
        }
    }
    private(set) var batteryInfoFocusChange: TimeInterval = -.infinity

    // MARK: - Settings Window Navigation State
    var settingsIconLeaf = AppIconLeaf.overall
    var settingsCategory: SettingsCategory? = .icon
    var settingsVisible = false

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
