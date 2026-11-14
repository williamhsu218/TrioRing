import SwiftUI

struct AirPodsControls: View {
    let output: AirPodsOutput
    let picker: AudioDevicePicker
    let monitor: AudioMonitor
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            VStack(alignment: .leading, spacing: 3) {
                if output.supportedModes.count <= 3 {
                    modeRow(output.supportedModes[...])
                } else {
                    modeRow(output.supportedModes.prefix(2))
                    modeRow(output.supportedModes.dropFirst(2))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Listening mode")
            .accessibilityValue(output.currentMode?.title ?? String(localized: "Unavailable"))

            if output.currentMode == .off || picker.failedAirPodsMode {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    if output.currentMode == .off { Text("Off").panelSecondaryText() }
                    if picker.failedAirPodsMode {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Could not change listening mode.")
                            .accessibilityIdentifier("RingABar.audio.airpods.modeError")
                            .help(Text("Could not change listening mode."))
                    }
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 7)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("RingABar.audio.airpods.controls")
    }

    private func modeRow(_ modes: ArraySlice<AirPodsListeningMode>) -> some View {
        HStack(spacing: 0) {
            ForEach(modes) { mode in
                modeButton(mode)
                    .background {
                        if output.currentMode == mode {
                            modeThumb.matchedGeometryEffect(id: "thumb", in: selection)
                        }
                    }
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: Capsule(style: .circular))
        .clipShape(Capsule(style: .circular))
        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: output.currentMode)
    }

    private var modeThumb: some View {
        Capsule(style: .circular)
            .fill(Color.accentColor.opacity(0.18))
            .overlay {
                Capsule(style: .circular).strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
            }
            .clipShape(Capsule(style: .circular))
            .allowsHitTesting(false)
    }

    private func modeButton(_ mode: AirPodsListeningMode) -> some View {
        let selected = output.currentMode == mode
        let pending = picker.pendingAirPodsMode == mode
        return Button {
            picker.selectAirPodsMode(mode, using: monitor)
        } label: {
            Group {
                if pending {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: modeSymbol(mode))
                        .font(.system(size: 16, weight: .medium))
                        .symbolRenderingMode(.monochrome)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 28)
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(AirPodsSegmentButtonStyle())
        .disabled(picker.pendingAirPodsMode != nil || picker.pendingID != nil)
        .help(Text(mode.title))
        .accessibilityLabel(Text(mode.title))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(picker.pendingAirPodsMode == mode ? Text("Applying…") : selected ? Text("Selected") : Text(""))
        .accessibilityIdentifier("RingABar.audio.airpods.mode.\(mode.rawValue)")
    }

    private func modeSymbol(_ mode: AirPodsListeningMode) -> String {
        switch mode {
        case .off: "power"
        case .noiseCancellation: "person.crop.circle.fill"
        case .transparency: "person.and.background.dotted"
        case .adaptive: "sparkles"
        }
    }
}

private struct AirPodsSegmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SegmentBody(configuration: configuration)
    }

    private struct SegmentBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .background {
                    if isEnabled, configuration.isPressed || hovering {
                        Capsule(style: .circular)
                            .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.08))
                    }
                }
                .scaleEffect(isEnabled && configuration.isPressed && !reduceMotion ? 0.96 : 1)
                .onHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
        }
    }
}
