import SwiftUI

struct AudioSettingsPane: View {
    @Bindable var preferences: Preferences
    let monitor: AudioMonitor
    let isVisible: Bool
    @State private var routes: AudioRoutes?
    @State private var direction: AudioDirection = .output

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard("Volume scrolling") {
                SettingsToggle(title: "Scroll to adjust output volume",
                               subtitle: "Use the mouse wheel or trackpad to change the current output volume.",
                               symbol: "speaker.wave.2.fill", tint: .cyan,
                               isOn: $preferences.scrollToAdjustVolume, id: "RingABar.settings.audio.scrollEnabled")
                SettingsRule()
                SettingsRow(title: "Scroll area", symbol: "rectangle.and.hand.point.up.left", tint: .cyan) {
                    Picker("Scroll area", selection: $preferences.scrollOnVolumeSliderOnly) {
                        Text("Entire panel").tag(false)
                        Text("Volume slider only").tag(true)
                    }
                    .labelsHidden()
                    .disabled(!preferences.scrollToAdjustVolume)
                    .accessibilityIdentifier("RingABar.settings.audio.scrollScope")
                }
                if preferences.scrollToAdjustVolume && !preferences.scrollOnVolumeSliderOnly {
                    SettingsNote(title: "Panel-wide scrolling can change volume outside the slider. Overflowing content still scrolls normally.")
                }
                SettingsRule()
                SettingsToggle(title: "Follow natural scroll direction",
                               subtitle: "Use the direction configured in macOS.",
                               symbol: "arrow.up.arrow.down", tint: .cyan,
                               isOn: $preferences.naturalVolumeScroll, id: "RingABar.settings.audio.naturalScroll")
                    .disabled(!preferences.scrollToAdjustVolume)
            }

            SettingsCard("Device order and visibility") {
                VStack(alignment: .leading, spacing: 5) {
                    Picker("Audio direction", selection: $direction) {
                        ForEach(AudioDirection.allCases) { direction in Text(direction.title).tag(direction) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("RingABar.settings.audio.direction")

                    if let routes {
                        let devices = preferences.audioDevices(in: routes, for: direction, includeHidden: true)
                        if devices.isEmpty {
                            Text("No available devices").foregroundStyle(.secondary)
                        }
                        ForEach(devices) { device in
                            deviceRow(device, routes: routes, first: devices.first?.uid, last: devices.last?.uid)
                        }
                        Text("The current device remains visible.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        ProgressView("Reading audio devices…").controlSize(.small)
                    }
                }
                .padding(13)
            }
        }
        .task(id: isVisible) {
            guard isVisible else { return }
            while !Task.isCancelled {
                let snapshot = await monitor.routes()
                guard !Task.isCancelled else { return }
                routes = snapshot
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func deviceRow(_ device: AudioRoute, routes: AudioRoutes, first: String?, last: String?) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { !(preferences.hiddenAudio[direction]?.contains(device.uid) ?? false) },
                set: { preferences.setAudioDeviceVisible($0, uid: device.uid, direction: direction) }
            )) {
                Label(device.name, systemImage: device.symbol)
                    .lineLimit(1)
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("RingABar.settings.audio.visible.\(direction.rawValue).\(device.id)")

            Spacer(minLength: 0)
            if routes.selectedID(for: direction) == device.id {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Current device")
            }
            moveButton(device, up: true, enabled: device.uid != first, routes: routes)
            moveButton(device, up: false, enabled: device.uid != last, routes: routes)
        }
    }

    private func moveButton(_ device: AudioRoute, up: Bool, enabled: Bool, routes: AudioRoutes) -> some View {
        let title = up ? Text("Move \(device.name) up") : Text("Move \(device.name) down")
        return Button {
            preferences.moveAudioDevice(device, by: up ? -1 : 1, in: routes, direction: direction)
        } label: {
            Image(systemName: up ? "chevron.up" : "chevron.down")
                .font(.caption.weight(.semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(PanelActionStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.30)
        .accessibilityLabel(title)
        .help(title)
        .accessibilityIdentifier("RingABar.settings.audio.move.\(direction.rawValue).\(device.id).\(up ? "up" : "down")")
    }
}
