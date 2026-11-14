import AppKit
import SwiftUI

enum SettingsCategory: String, CaseIterable, Identifiable {
    case icon, battery, network, audio, panel, general

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .icon: "App Icon"
        case .battery: "Battery"
        case .network: "Network"
        case .audio: "Audio"
        case .panel: "Status Panel"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .icon: "macwindow.on.rectangle"
        case .battery: "battery.100percent"
        case .network: "wifi"
        case .audio: "speaker.wave.2.fill"
        case .panel: "list.bullet.rectangle"
        case .general: "gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .icon: .indigo
        case .battery: .green
        case .network: .blue
        case .audio: .cyan
        case .panel: .purple
        case .general: .gray
        }
    }
}

struct SettingsView: View {
    static let windowSize = CGSize(width: 720, height: 530)
    @Bindable var preferences: Preferences
    let store: StatusStore
    let audio: AudioMonitor
    let batteryActions: BatteryActions
    let wifiAccess: WiFiLocationAccess
    let globalShortcut: GlobalShortcutController
    let onRecordShortcut: () -> Void
    let onCancelShortcut: () -> Void
    var automaticallyChecksForUpdates: Binding<Bool>? = nil
    @State private var previewIsDark = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var contentID: String {
        let category = store.settingsCategory ?? .icon
        return category == .icon ? "icon.\(store.settingsIconLeaf.rawValue)" : category.rawValue
    }

    enum SidebarSelection: Hashable {
        case icon(AppIconLeaf)
        case category(SettingsCategory)
    }

    var body: some View {
        let category = store.settingsCategory ?? .icon
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar(category)
                .navigationSplitViewColumnWidth(min: 182, ideal: 196, max: 224)
        } detail: {
            GeometryReader { geometry in
                let inset: CGFloat = 24
                let columnWidth = max(1, geometry.size.width - 2 * inset)
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        if category == .icon {
                            livePreview
                                .frame(width: columnWidth)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 12)
                                .padding(.bottom, 10)
                        }
                        ScrollView {
                            pane(category)
                                .frame(width: columnWidth, alignment: .leading)
                                .frame(minWidth: 0, maxWidth: .infinity)
                                .padding(.top, 10)
                                .padding(.bottom, 24)
                        }
                        .background(StableScrollViewport())
                        .id(store.settingsVisible)
                        .accessibilityLabel(Text(category.title))
                    }
                    .id(contentID)
                    .transition(reduceMotion ? .identity : .opacity)
                }
                .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: contentID)
            }
            .navigationTitle(Text(category.title))
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 580, idealWidth: Self.windowSize.width,
               minHeight: 420, idealHeight: Self.windowSize.height)
    }

    private func sidebar(_ selected: SettingsCategory) -> some View {
        List(selection: sidebarSelection) {
            iconSectionRow()
                .tag(SidebarSelection.category(.icon))
            if selected == .icon {
                ForEach(AppIconLeaf.allCases) { leaf in
                    iconLeafRow(leaf, selected: store.settingsIconLeaf == leaf)
                        .tag(SidebarSelection.icon(leaf))
                }
            }
            Section {
                ForEach(SettingsCategory.allCases.filter { $0 != .general && $0 != .icon }) { category in
                    sidebarRow(category, selected: selected)
                        .tag(SidebarSelection.category(category))
                }
            }
            Section {
                sidebarRow(.general, selected: selected)
                    .tag(SidebarSelection.category(.general))
            }
        }
        .listStyle(.sidebar)
    }

    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding {
            Self.resolvedSidebarSelection(store: store)
        } set: { selection in
            Self.applySidebarSelection(selection, to: store, onCancelShortcut: onCancelShortcut)
        }
    }

    static func resolvedSidebarSelection(store: StatusStore) -> SidebarSelection {
        let category = store.settingsCategory ?? .icon
        return category == .icon ? .icon(store.settingsIconLeaf) : .category(category)
    }

    static func applySidebarSelection(_ selection: SidebarSelection?,
                                      to store: StatusStore,
                                      onCancelShortcut: () -> Void) {
        switch selection {
        case let .icon(leaf):
            onCancelShortcut()
            store.settingsCategory = .icon
            store.settingsIconLeaf = leaf
        case let .category(category):
            if category != .general { onCancelShortcut() }
            if category == .icon {
                store.settingsIconLeaf = .overall
            }
            store.settingsCategory = category
        case nil:
            break
        }
    }

    private func iconSectionRow() -> some View {
        HStack(spacing: 10) {
            SettingsIconTile(symbol: SettingsCategory.icon.symbol, tint: .indigo, size: 22)
            Text("App Icon").font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .contentShape(Rectangle())
        .accessibilityLabel("App Icon")
        .accessibilityIdentifier("RingABar.settings.section.icon")
    }

    private func iconLeafRow(_ leaf: AppIconLeaf, selected: Bool) -> some View {
        Text(leaf.title)
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 26)
            .padding(.leading, 34)
            .contentShape(Rectangle())
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("RingABar.settings.icon.page.\(leaf.rawValue)")
    }

    private func sidebarRow(_ category: SettingsCategory, selected: SettingsCategory) -> some View {
        HStack(spacing: 10) {
            SettingsIconTile(symbol: category.symbol, tint: category.tint, size: 22)
            Text(category.title)
                .font(.system(size: 13, weight: selected == category ? .semibold : .regular))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected == category ? .isSelected : [])
        .accessibilityIdentifier("RingABar.settings.section.\(category.rawValue)")
    }

    @ViewBuilder private func pane(_ category: SettingsCategory) -> some View {
        switch category {
        case .icon:
            AppIconSettingsPane(preferences: preferences, store: store, leaf: store.settingsIconLeaf, previewIsDark: previewIsDark)
        case .battery: BatterySettingsPane(preferences: preferences, store: store, actions: batteryActions)
        case .network: NetworkSettingsPane(preferences: preferences, access: wifiAccess, store: store)
        case .audio: AudioSettingsPane(preferences: preferences, monitor: audio, isVisible: store.settingsVisible)
        case .panel: panelSettings
        case .general: GeneralSettingsPane(globalShortcut: globalShortcut,
                                           onRecordShortcut: onRecordShortcut,
                                           onCancelShortcut: onCancelShortcut,
                                           automaticallyChecksForUpdates: automaticallyChecksForUpdates)
        }
    }

    private var panelSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard("Summary sections") {
                ForEach(preferences.panelOrder) { section in
                    if section != preferences.panelOrder.first { SettingsRule() }
                    SettingsRow(title: LocalizedStringKey(section.title), symbol: section.symbol, tint: section.settingsTint) {
                        Toggle(section.title, isOn: Binding(
                            get: { !preferences.hiddenSections.contains(section) },
                            set: { preferences.setVisible($0, section: section) }
                        ))
                        .toggleStyle(.switch).labelsHidden()
                        .controlSize(.small)
                        .accessibilityIdentifier("RingABar.settings.visibility.\(section.rawValue)")
                        moveButton(section, up: true)
                        moveButton(section, up: false)
                    }
                }
            }
            SettingsCard("Audio") {
                SettingsToggle(title: "Expand audio devices when opening the panel",
                               subtitle: "Start with the output device list visible.",
                               symbol: "speaker.wave.2.fill", tint: .cyan,
                               isOn: $preferences.opensWithExpandedAudio, id: "RingABar.settings.expandAudio")
                    .disabled(preferences.hiddenSections.contains(.audio))
                SettingsRule()
                SettingsToggle(title: "Scroll over the panel to adjust volume",
                               subtitle: "Use the scroll area selected in Audio settings.",
                               symbol: "scroll", tint: .cyan,
                               isOn: $preferences.scrollToAdjustVolume, id: "RingABar.settings.scrollVolume")
                    .disabled(preferences.hiddenSections.contains(.audio))
            }
            PanelSettingsPreview(preferences: preferences)
                .frame(maxWidth: 232)
        }
    }

    private func moveButton(_ section: PanelSection, up: Bool) -> some View {
        let title = up ? Text("Move \(section.title) up") : Text("Move \(section.title) down")
        let canMove = up ? preferences.panelOrder.first != section : preferences.panelOrder.last != section
        return Button {
            preferences.move(section, by: up ? -1 : 1)
        } label: {
            Image(systemName: up ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(PanelActionStyle())
        .disabled(!canMove)
        .opacity(canMove ? 1 : 0.30)
        .accessibilityLabel(title)
        .help(title)
        .accessibilityIdentifier("RingABar.settings.move.\(section.rawValue).\(up ? "up" : "down")")
    }

    private var livePreview: some View {
        let current = store.statusIcon(preferences.icon)
        let foreground: Color = previewIsDark ? .white : .black
        return VStack(spacing: 8) {
            HStack(spacing: 14) {
                Label("Finder", systemImage: "apple.logo")
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityHidden(true)
                Spacer(minLength: 16)
                if let image = current.image(layer: .preview, previewForeground: previewIsDark ? .white : .black) {
                    Image(nsImage: image)
                        .accessibilityLabel("Current menu bar icon")
                        .accessibilityIdentifier("RingABar.settings.icon.livePreview")
                }
                HStack(spacing: 6) {
                    Image(systemName: "switch.2").font(.system(size: 10))
                    Text(verbatim: "9:41").font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundStyle(foreground.opacity(0.65))
                .accessibilityHidden(true)
                Button {
                    previewIsDark.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: previewIsDark ? "moon.fill" : "sun.max").font(.system(size: 10))
                        Text(verbatim: previewIsDark ? String(localized: "Dark")
                            : String(localized: "Light preview appearance", defaultValue: "Light"))
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(foreground.opacity(0.85))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(foreground.opacity(previewIsDark ? 0.15 : 0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Switch the preview appearance")
                .accessibilityIdentifier("RingABar.settings.previewAppearance")
            }
            .foregroundStyle(foreground.opacity(0.78))
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.linearGradient(
                        colors: previewIsDark ? [Color(white: 0.16), Color(white: 0.10)]
                            : [Color(white: 0.98), Color(white: 0.91)],
                        startPoint: .top, endPoint: .bottom
                    ))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(foreground.opacity(previewIsDark ? 0.12 : 0.08), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 2)
            Text("Live Preview")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

private extension PanelSection {
    var settingsTint: Color {
        switch self {
        case .battery: .green
        case .network: .blue
        case .audio: .cyan
        }
    }
}
