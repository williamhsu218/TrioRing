import SwiftUI

struct SettingsIconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 26

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.54, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.23))
            .accessibilityHidden(true)
    }
}

struct SettingsCard<Content: View>: View {
    let title: LocalizedStringKey?
    @ViewBuilder let content: () -> Content

    init(_ title: LocalizedStringKey? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 11))
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(.primary.opacity(0.09), lineWidth: 1)
                        .allowsHitTesting(false)
                }
        }
    }
}

struct SettingsRule: View {
    var body: some View {
        Divider().padding(.leading, 52).padding(.trailing, 13)
            .accessibilityHidden(true)
    }
}

struct SettingsRow<Control: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    let symbol: String
    let tint: Color
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsIconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(minHeight: 44)
    }
}

struct SettingsToggle: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let symbol: String
    let tint: Color
    @Binding var isOn: Bool
    let id: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, symbol: symbol, tint: tint) {
            Toggle(title, isOn: Binding(
                get: { isOn },
                set: { newValue in
                    if !reduceMotion {
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                    }
                    isOn = newValue
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .accessibilityLabel(Text(title))
            .accessibilityHint(Text(subtitle))
            .accessibilityIdentifier(id)
        }
    }
}

struct SettingsNote: View {
    let title: LocalizedStringKey

    var body: some View {
        Label {
            Text(title).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "info.circle").accessibilityHidden(true)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ShortcutSettingsRow: View {
    let controller: GlobalShortcutController
    let onRecord: () -> Void
    let onCancel: () -> Void

    var body: some View {
        SettingsCard("Keyboard Shortcuts") {
            SettingsRow(title: "Open or close the status panel",
                        subtitle: "Use a shortcut from any app.",
                        symbol: "command", tint: .gray) {
                if controller.isRecording {
                    Text("Type shortcut…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("RingABar.settings.shortcut.recording")
                    Button("Cancel", action: onCancel)
                        .controlSize(.small)
                        .accessibilityIdentifier("RingABar.settings.shortcut.cancel")
                } else {
                    let label = controller.shortcut.map { ShortcutKeyLabel.string(for: $0) }
                    Button(action: onRecord) {
                        if let label { Text(verbatim: label) } else { Text("Record Shortcut") }
                    }
                    .controlSize(.small)
                    .accessibilityLabel(label == nil ? Text("Record Shortcut") : Text("Change shortcut"))
                    .accessibilityValue(Text(verbatim: label ?? ""))
                    .accessibilityIdentifier("RingABar.settings.shortcut.record")
                    if label != nil {
                        Button(action: controller.clearShortcut) {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear shortcut")
                        .accessibilityLabel("Clear shortcut")
                        .accessibilityIdentifier("RingABar.settings.shortcut.clear")
                    }
                }
            }
            if let feedback = controller.feedback {
                SettingsNote(title: message(feedback))
                    .accessibilityIdentifier("RingABar.settings.shortcut.feedback")
            }
        }
    }

    private func message(_ feedback: GlobalShortcutController.Feedback) -> LocalizedStringKey {
        switch feedback {
        case .invalid: "Use Command, Control, or Option with another key."
        case .inputMethodConflict: "Option-Space may be used to switch input methods. Choose a different shortcut."
        case .conflict: "This shortcut is already in use."
        case .failed: "macOS could not register this shortcut."
        case .restorationFailed: "The saved shortcut could not be registered. Record a new shortcut."
        }
    }
}
