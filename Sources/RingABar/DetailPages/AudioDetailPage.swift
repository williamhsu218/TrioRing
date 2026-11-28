import AppKit
import SwiftUI

private struct AudioDirectionControl: NSViewRepresentable {
    @Binding var selection: AudioDirection
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: AudioDirection.allCases.map(\.title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.select(_:))
        )
        control.segmentDistribution = .fillEqually
        control.setAccessibilityLabel(String(localized: "Audio direction"))
        control.setAccessibilityIdentifier("RingABar.audio.direction")
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = selection == .output ? 0 : 1
        control.isEnabled = isEnabled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<AudioDirection>

        init(selection: Binding<AudioDirection>) {
            self.selection = selection
        }

        @objc func select(_ sender: NSSegmentedControl) {
            let segment = sender.selectedSegment
            guard AudioDirection.allCases.indices.contains(segment) else { return }
            selection.wrappedValue = AudioDirection.allCases[segment]
        }
    }
}

struct AudioPage<OutputControls: View>: View {
    let store: StatusStore
    let preferences: Preferences
    let monitor: AudioMonitor
    let picker: AudioDevicePicker
    let outputControls: OutputControls
    let height: PanelHeightReporter
    let navigationFocus: FocusState<PanelNavigationFocus?>.Binding
    let onBack: () -> Void
    let onOpenSettings: () -> Void
    let onOpenAppSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var direction: AudioDirection { store.audioDirection }

    var body: some View {
        @Bindable var store = store
        let spacing: CGFloat = 10
        let selectorHeight: CGFloat = 24
        return DetailPanel(height: height, headerHeight: PageHeader<EmptyView>.height + spacing + selectorHeight,
                           spacing: spacing, scrollContentID: direction.rawValue) {
            VStack(alignment: .leading, spacing: spacing) {
                PageHeader(title: "Audio", navigationFocus: navigationFocus, onBack: onBack) {
                    Button(action: onOpenAppSettings) {
                        DetailHeaderAction(symbol: "gearshape")
                    }
                    .buttonStyle(PanelActionStyle(cornerRadius: StatusPanel.summaryActionWidth / 2))
                    .help("TrioRing Audio Settings…")
                    .accessibilityLabel("TrioRing Audio Settings…")
                    .accessibilityIdentifier("RingABar.audio.appSettings")
                }
                AudioDirectionControl(selection: $store.audioDirection)
                    .frame(maxWidth: .infinity)
                    .frame(height: selectorHeight)
                    .disabled(picker.pendingID != nil || picker.inputMutePending)
            }
        } content: {
            audioContent
                .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: direction)
        }
        .preference(key: PanelReadyLayoutKey.self, value: picker.routes != nil ? store.panelLayout : nil)
    }

    private var audioContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if direction == .output {
                if !store.audio.canSetVolume, store.audio.deviceID != nil {
                    Text("Volume controlled by device").font(.callout).foregroundStyle(.secondary)
                }
                outputControls
            } else if let mute = picker.inputMute {
                inputControls(mute)
                    .id(mute.uid)
            }

            if let routes = picker.routes {
                let devices = preferences.audioDevices(in: routes, for: direction)
                if direction == .input {
                    inputDeviceList(devices, current: routes.inputs.first { $0.id == routes.inputID }?.name)
                } else {
                    deviceList(devices)
                    if let output = picker.airPodsOutput, output.deviceID == store.audio.deviceID {
                        AirPodsControls(output: output, picker: picker, monitor: monitor)
                            .id(output.uid)
                    }
                }
            } else {
                ProgressView("Reading audio devices…").controlSize(.small)
            }

            if picker.failedDirection == direction {
                Text("Could not switch audio device.").font(.caption).foregroundStyle(.red)
            }
            Divider()
            DetailSettingsLink("System Sound Settings…", id: "RingABar.audio.systemSettings", action: onOpenSettings)
        }
    }

    private func inputDeviceList(_ devices: [AudioRoute], current: String?) -> some View {
        let expanded = store.inputDevicesExpanded
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                store.inputDevicesExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Text("Input devices")
                    Spacer(minLength: 0)
                    if !expanded, let current {
                        Text(current)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: expanded)
                        .accessibilityHidden(true)
                }
                .font(.callout)
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PanelActionStyle())
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
            .accessibilityIdentifier("RingABar.audio.inputDisclosure")
            if expanded {
                deviceList(devices)
                    .transition(PanelMotion.disclosureTransition(reduceMotion: reduceMotion))
            }
        }
        .clipped()
        .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: expanded)
    }

    @ViewBuilder private func deviceList(_ devices: [AudioRoute]) -> some View {
        if devices.isEmpty {
            Text("No available devices").font(.callout).foregroundStyle(.secondary)
        } else if devices.count <= 5 {
            deviceRows(devices)
        } else {
            ScrollView { deviceRows(devices) }
                .frame(height: 5 * AudioDeviceRows.rowHeight)
                .background(StableScrollViewport())
        }
    }

    private func deviceRows(_ devices: [AudioRoute]) -> some View {
        AudioDeviceRows(devices: devices, direction: direction, picker: picker, monitor: monitor,
                        isPanelVisible: store.panelVisible)
    }

    private func inputControls(_ mute: AudioInputMute) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                inputMuteButton(mute)
                if let gain = picker.inputGain, gain.uid == mute.uid, gain.canSet {
                    Slider(value: Binding(
                        get: { picker.displayedInputGain(gain) },
                        set: { picker.setInputGain($0, on: gain, using: monitor) }
                    ), in: 0...1) {
                        Text("Microphone gain")
                    }
                    .labelsHidden()
                    .tint(mute.state == .muted ? .secondary : .accentColor)
                    .disabled(picker.pendingID != nil)
                    .accessibilityIdentifier("RingABar.audio.inputGain")
                    Text(picker.displayedInputGain(gain), format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .frame(minWidth: 32, alignment: .trailing)
                        .accessibilityHidden(true)
                } else {
                    Text("Microphone gain controlled by device")
                        .font(.caption)
                        .accessibilityIdentifier("RingABar.audio.inputGainUnavailable")
                }
            }
            .foregroundStyle(.secondary)
            if picker.failedInputGain {
                Text("Could not change microphone gain.").font(.caption).foregroundStyle(.red)
            }
            if picker.failedInputMute {
                Text("Could not change microphone mute.").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func inputMuteButton(_ mute: AudioInputMute) -> some View {
        let action: LocalizedStringKey = mute.state == .muted ? "Unmute microphone" : "Mute microphone"
        let state: LocalizedStringKey = switch mute.state {
        case .muted: "Muted"
        case .unmuted: "Not muted"
        case .partial: "Partially muted"
        case nil: "Unavailable"
        }
        return Button { picker.toggleInputMute(using: monitor) } label: {
            ZStack {
                if picker.inputMutePending {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: mute.state == .muted ? "mic.slash.fill" : "mic.fill")
                        .foregroundStyle(mute.state == .muted ? Color.accentColor : .secondary)
                    if mute.state == .partial {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 8, weight: .bold))
                            .offset(x: 7, y: -6)
                    }
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
        }
        .buttonStyle(PanelActionStyle())
        .disabled(!mute.canSet || picker.inputMutePending || picker.pendingID != nil)
        .help(mute.canSet ? Text(action) : Text("Microphone mute unavailable"))
        .accessibilityLabel(mute.canSet ? Text(action) : Text("Microphone mute unavailable"))
        .accessibilityValue(Text(state))
        .accessibilityIdentifier("RingABar.audio.inputMute")
    }
}
