import SwiftUI

/// An intentionally non-interactive layout preview. It shares the summary's
/// visibility/order source, without starting device monitors or writing hardware.
struct PanelSettingsPreview: View {
    let preferences: Preferences

    var body: some View {
        SettingsCard("Panel preview") {
            VStack(alignment: .leading, spacing: 4) {
                if preferences.visibleSections.isEmpty {
                    Text("No summary sections selected")
                        .foregroundStyle(.secondary)
                }
                ForEach(preferences.visibleSections) { section in
                    HStack(spacing: 7) {
                        Label {
                            Text(LocalizedStringKey(section.title)).fontWeight(.medium)
                        } icon: {
                            Image(systemName: section.symbol)
                                .frame(width: 16)
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.forward")
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 16)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("RingABar.settings.panelPreview.\(section.rawValue)")
                }
                Divider()
                HStack(spacing: 7) {
                    Label {
                        Text("Settings…")
                    } icon: {
                        Image(systemName: "gearshape")
                            .frame(width: 16)
                            .accessibilityHidden(true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "ellipsis").accessibilityHidden(true)
                }
                .frame(minHeight: 16)
                .foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(9)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RingABar.settings.panelPreview")
    }
}
