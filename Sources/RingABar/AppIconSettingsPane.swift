import AppKit
import SwiftUI

enum AppIconLeaf: String, CaseIterable, Identifiable {
    case overall, top, middle, bottom

    var id: Self { self }
    var title: LocalizedStringKey {
        switch self {
        case .overall: "Overall Appearance"
        case .top: "Top Arc"
        case .middle: "Middle Icon"
        case .bottom: "Bottom Indicator"
        }
    }
}

struct AppIconSettingsPane: View {
    @Bindable var preferences: Preferences
    let store: StatusStore
    let leaf: AppIconLeaf
    let previewIsDark: Bool

    @State private var showsGuide = false
    @State private var showsConnectionStyles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch leaf {
            case .overall: overall
            case .top: top
            case .middle: middle
            case .bottom: bottom
            }
        }
    }

    private var overall: some View {
        Group {
            SettingsCard {
                SettingsRow(title: "Meet your icon", symbol: "questionmark.circle", tint: .indigo) {
                    Button {
                        showsGuide.toggle()
                    } label: {
                        Label("Open Guide", systemImage: "macwindow")
                    }
                    .accessibilityIdentifier("RingABar.settings.icon.guide")
                    .popover(isPresented: $showsGuide) {
                        HStack(alignment: .center, spacing: 16) {
                            if let icon = sample().image(size: 64, layer: .preview) {
                                Image(nsImage: icon).accessibilityHidden(true)
                            }
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Top Arc").font(.headline)
                                Text("Battery level and charging state")
                                Text("Middle Icon").font(.headline)
                                Text("Your selected status source")
                                Text("Bottom Indicator").font(.headline)
                                Text("Current output volume")
                            }
                        }
                        .padding(20)
                    }
                }
            }
            SettingsCard("Menu Bar Icon") {
                slider("Icon Size", "Adjusts the menu bar icon render size from 16–36 pt.",
                       symbol: "macwindow", tint: .indigo, value: $preferences.icon.menuBarSize,
                       range: IconPreferences.menuBarSizes, suffix: " pt", id: "icon.size")
                if preferences.icon.menuBarSize > store.maximumMenuBarIconSize {
                    SettingsRule()
                    SettingsNote(title: "This display fits up to \(store.maximumMenuBarIconSize) pt in the menu bar.")
                }
            }
            SettingsCard("Status Icon") {
                SettingsRow(title: "Ring Stroke Width", subtitle: "Adjust the line weight of the status icon.",
                            symbol: "circle.dotted", tint: .indigo) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(RingWeight.allCases) { weight in
                            iconTile(weight.title, id: "ringWeight.\(weight.rawValue)",
                                     selected: preferences.icon.ringWeight == weight,
                                     icon: sample { $0.ringWeight = weight }) {
                                preferences.icon.ringWeight = weight
                            }
                        }
                    }
                }
            }
        }
    }

    private var top: some View {
        Group {
            SettingsCard("Top Markers") {
                if store.battery == .noBattery {
                    markerPicker("Without a battery", symbol: "powerplug.fill", tint: .cyan,
                                 selection: $preferences.icon.noBatteryMarker,
                                 options: [.plug, .bolt, .hidden], id: "icon.noBatteryMarker")
                } else {
                    markerPicker("On battery", symbol: "percent", tint: .green,
                                 selection: $preferences.icon.onBatteryMarker,
                                 options: [.percentage, .hidden], id: "batteryValue")
                    SettingsRule()
                    markerPicker("Charging", symbol: "bolt.fill", tint: .yellow,
                                 selection: $preferences.icon.chargingMarker,
                                 options: [.bolt, .plug, .percentage, .hidden], id: "icon.chargingMarker")
                    SettingsRule()
                    markerPicker("Connected, not charging", symbol: "powerplug.fill", tint: .cyan,
                                 selection: $preferences.icon.connectedMarker,
                                 options: [.plug, .bolt, .percentage, .hidden], id: "icon.connectedMarker")
                }
                SettingsRule()
                slider("Percentage/bolt size", "Adjust the size of the marker in the top gap.",
                       symbol: "textformat.size", tint: .blue, value: $preferences.icon.markerSize,
                       range: IconPreferences.markerSizes, suffix: "%", id: "icon.markerSize")
            }
            SettingsCard("Progress") {
                SettingsToggle(title: "Split progress when the top gap is filled",
                               subtitle: "Draw 0–50% on the left and 50–100% on the right while a marker fills the top gap.",
                               symbol: "circle.lefthalf.filled", tint: .blue,
                               isOn: $preferences.icon.splitsProgress, id: "RingABar.settings.icon.splitProgress")
                if let reading = store.battery.reading {
                    SettingsRule()
                    SettingsRow(title: "Battery level",
                                subtitle: "The ring uses the current battery level. A charging limit does not change the scale.",
                                symbol: "battery.100percent", tint: .green) {
                        Text("\(reading.percent)%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            SettingsCard("Colors") {
                SettingsToggle(title: "Monochrome charging",
                               subtitle: "Use the system foreground color for normal charging.",
                               symbol: "circle.lefthalf.filled", tint: .gray,
                               isOn: $preferences.icon.monochromeCharging, id: "RingABar.settings.icon.monochromeCharging")
                    .disabled(!preferences.icon.usesBatteryColors)
                SettingsRule()
                SettingsToggle(title: "Use battery status colors",
                               subtitle: "Tint the ring when charging, in Low Power Mode or when the battery is low.",
                               symbol: "paintpalette.fill", tint: .orange, isOn: $preferences.icon.usesBatteryColors,
                               id: "RingABar.settings.batteryColors")
                if preferences.icon.usesBatteryColors {
                    SettingsRule()
                    slider("Critical battery level", "The battery arc turns red below this level.",
                           symbol: "battery.25percent", tint: .red, value: $preferences.icon.criticalLevel,
                           range: IconPreferences.criticalLevels, suffix: "%", id: "icon.criticalLevel")
                }
            }
        }
    }

    private var middle: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose what the status icon shows in the middle. Only one source is shown at a time.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 5) {
                    ForEach(MiddleIconSource.allCases) { source in
                        iconTile(source.title, id: "icon.middle.\(source.rawValue)",
                                 selected: preferences.icon.middleSource == source, icon: sample { config in
                            config.middleSource = source
                            config.middleSize = 125
                            if source == .chargingStatus { config.chargingMarker = .percentage }
                        }, width: 59, dark: false) {
                            preferences.icon.middleSource = source
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            SettingsRule().padding(.leading, -39)
            slider("Middle Icon Size", "One size for every middle content: Wi-Fi, Bluetooth, input source, and numbers.",
                   symbol: "circle.circle", tint: .indigo, value: $preferences.icon.middleSize,
                   range: IconPreferences.middleSizes, suffix: "%", id: "icon.middleSize")
            SettingsRule()
            if preferences.icon.middleSource == .network {
                connectionStyles
            } else {
                SettingsToggle(title: "Prioritize network warnings",
                               subtitle: "Show the disconnected network icon when the Mac is offline.",
                               symbol: "wifi.exclamationmark", tint: .blue, isOn: $preferences.icon.prioritizesNetworkWarnings,
                               id: "RingABar.settings.icon.networkWarnings")
                if preferences.icon.middleSource == .bluetooth {
                    SettingsRule()
                    SettingsNote(title: "Shows the active Bluetooth audio output.")
                }
            }
        }
    }

    private var connectionStyles: some View {
        Group {
            Button {
                showsConnectionStyles.toggle()
            } label: {
                SettingsRow(title: "Connection Icon Style",
                            subtitle: "Use the standard Wi-Fi signal icon in place of a special connection icon.",
                            symbol: "cable.connector", tint: .cyan) {
                    Image(systemName: showsConnectionStyles ? "chevron.up" : "chevron.down")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsConnectionStyles ? Text("Expanded") : Text("Collapsed"))
            .accessibilityIdentifier("RingABar.settings.icon.connectionStyle")
            if showsConnectionStyles {
                SettingsRule()
                SettingsToggle(title: "Use Wi-Fi glyph for Ethernet",
                               subtitle: "Use the Wi-Fi symbol for a wired network connection.",
                               symbol: "cable.connector", tint: .cyan, isOn: $preferences.icon.showsWiFiForWired,
                               id: "RingABar.settings.icon.wired")
                SettingsRule()
                SettingsToggle(title: "Use Wi-Fi glyph for Personal Hotspot",
                               subtitle: "Show signal bars when connected to a Personal Hotspot.",
                               symbol: "personalhotspot", tint: .blue, isOn: $preferences.icon.showsWiFiForHotspot,
                               id: "RingABar.settings.icon.hotspot")
            }
        }
    }

    private var bottom: some View {
        SettingsCard("Volume Indicator Style") {
            SettingsRow(title: "Display Style", subtitle: "Choose whether volume displays as four discrete dots or a continuous bottom arc.",
                        symbol: "waveform", tint: .indigo) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(VolumeIndicator.allCases) { style in
                        iconTile(style.title, id: "volumeIndicator.\(style.rawValue)",
                                 selected: preferences.icon.volumeIndicator == style,
                                 icon: sample { $0.volumeIndicator = style }) {
                            preferences.icon.volumeIndicator = style
                        }
                    }
                }
            }
            SettingsRule()
            SettingsToggle(title: "Use blue for Bluetooth volume",
                           subtitle: "The active dots or arc turn blue when the audio output is Bluetooth.",
                           symbol: "speaker.wave.2.fill", tint: .cyan,
                           isOn: $preferences.icon.usesBlueForBluetoothVolume, id: "RingABar.settings.icon.blueBluetooth")
        }
    }

    private func markerPicker(_ title: LocalizedStringKey, symbol: String, tint: Color,
                              selection: Binding<TopMarker>, options: [TopMarker], id: String) -> some View {
        SettingsRow(title: title, symbol: symbol, tint: tint) {
            Picker(title, selection: selection) {
                ForEach(options) { Text(verbatim: $0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 160)
            .buttonSizing(.flexible)
            .accessibilityIdentifier("RingABar.settings.\(id)")
        }
    }

    private func slider(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey, symbol: String, tint: Color,
                        value: Binding<Int>, range: ClosedRange<Int>, suffix: String, id: String) -> some View {
        SettingsRow(title: title, subtitle: subtitle, symbol: symbol, tint: tint) {
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound)) {
                Text(title)
            }
            .labelsHidden()
            .frame(width: 130)
            .controlSize(.small)
            .accessibilityIdentifier("RingABar.settings.\(id)")
            Text(verbatim: "\(value.wrappedValue)\(suffix)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }

    private func iconTile(_ title: String, id: String, selected: Bool, icon: StatusIcon,
                          width: CGFloat = 68, dark: Bool? = nil, action: @escaping () -> Void) -> some View {
        let dark = dark ?? previewIsDark
        return Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.linearGradient(
                            colors: dark ? [Color(white: 0.16), Color(white: 0.10)]
                                : [Color(white: 0.94), Color(white: 0.88)],
                            startPoint: .top, endPoint: .bottom
                        ))
                    if let image = icon.image(size: width < 60 ? 36 : 30, layer: .preview, previewForeground: dark ? .white : .black) {
                        Image(nsImage: image)
                    }
                }
                .frame(width: width, height: 44)
                .overlay {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.1))
                }
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(-5)
                    }
                }
                Text(verbatim: title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: width + 10)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("RingABar.settings.\(id)")
    }

    private func sample(_ modify: (inout IconPreferences) -> Void = { _ in }) -> StatusIcon {
        var config = IconPreferences()
        modify(&config)
        return StatusIcon(battery: .battery(.init(percent: 68, pluggedIn: true, charging: true)),
                          network: .init(path: .wifi, signalDBm: -71),
                          audio: .init(volume: 0.5, isBluetooth: true, deviceSymbol: "headphones"),
                          preferences: config, inputSource: "中", systemWatts: 24)
    }
}
