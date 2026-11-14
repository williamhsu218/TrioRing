import SwiftUI

@MainActor
@Observable
final class AudioDevicePicker {
    private(set) var routes: AudioRoutes?
    private(set) var pendingID: AudioRoute.ID?
    private(set) var failedDirection: AudioDirection?
    private(set) var inputGain: AudioInputGain?
    private(set) var failedInputGain = false
    private(set) var inputMute: AudioInputMute?
    private(set) var inputMutePending = false
    private(set) var failedInputMute = false
    private(set) var airPodsOutput: AirPodsOutput?
    private(set) var pendingAirPodsMode: AirPodsListeningMode?
    private(set) var failedAirPodsMode = false
    private var gainDraft: (uid: String, value: Double)?
    @ObservationIgnored private var gainWrite: Task<Void, Never>?
    private var gainRevision = 0
    private var muteRevision = 0
    private var airPodsRevision = 0
    private var selectionGeneration = 0

    func refreshWhileVisible(using monitor: AudioMonitor) async {
        while !Task.isCancelled {
            await refresh(using: monitor)
            try? await Task.sleep(for: .seconds(2))
        }
    }

    func refresh(using monitor: AudioMonitor) async {
        guard pendingID == nil else { return }
        let generation = selectionGeneration
        let gainRevision = self.gainRevision
        let muteRevision = self.muteRevision
        let airPodsRevision = self.airPodsRevision
        let snapshot = await monitor.routes()
        guard !Task.isCancelled, generation == selectionGeneration else { return }
        routes = snapshot
        if gainRevision == self.gainRevision { updateInputGain(snapshot.inputGain) }
        if muteRevision == self.muteRevision, !inputMutePending { updateInputMute(snapshot.inputMute) }
        if airPodsRevision == self.airPodsRevision, pendingAirPodsMode == nil {
            updateAirPodsOutput(snapshot.airPodsOutput)
        }
    }

    func select(_ route: AudioRoute, direction: AudioDirection, using monitor: AudioMonitor) {
        guard pendingID == nil, !inputMutePending, pendingAirPodsMode == nil,
              routes?.selectedID(for: direction) != route.id else { return }
        selectionGeneration += 1
        if direction == .input {
            gainRevision += 1
            gainWrite?.cancel()
            gainDraft = nil
            failedInputGain = false
            failedInputMute = false
        }
        pendingID = route.id
        failedDirection = nil
        Task {
            let accepted = await monitor.select(route, direction: direction)
            var snapshot = await monitor.routes()
            for _ in 0..<5 where accepted && snapshot.selectedID(for: direction) != route.id {
                try? await Task.sleep(for: .milliseconds(150))
                snapshot = await monitor.routes()
            }
            routes = snapshot
            updateInputGain(snapshot.inputGain)
            updateInputMute(snapshot.inputMute)
            updateAirPodsOutput(snapshot.airPodsOutput)
            if !accepted || snapshot.selectedID(for: direction) != route.id {
                failedDirection = direction
            }
            pendingID = nil
        }
    }

    func displayedInputGain(_ gain: AudioInputGain) -> Double {
        if gainDraft?.uid == gain.uid, let draft = gainDraft { return draft.value }
        return inputGain?.uid == gain.uid ? inputGain?.value ?? gain.value ?? 0 : gain.value ?? 0
    }

    func setInputGain(_ value: Double, on gain: AudioInputGain, using monitor: AudioMonitor) {
        guard gain.canSet, pendingID == nil, inputGain?.uid == gain.uid else { return }
        failedInputGain = false
        gainRevision += 1
        let revision = gainRevision
        gainDraft = (gain.uid, value)
        gainWrite?.cancel()
        gainWrite = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(35)) }
            catch { return }
            let result = await monitor.setInputGain(value, on: gain)
            guard let self, revision == gainRevision, !Task.isCancelled else { return }
            gainDraft = nil
            updateInputGain(result.gain)
            failedInputGain = !result.accepted && result.gain?.uid == gain.uid
        }
    }

    private func updateInputGain(_ gain: AudioInputGain?) {
        if gain?.uid != inputGain?.uid {
            failedInputGain = false
        }
        inputGain = gain
    }

    func toggleInputMute(using monitor: AudioMonitor) {
        guard pendingID == nil, !inputMutePending, let inputMute, inputMute.canSet else { return }
        inputMutePending = true
        failedInputMute = false
        muteRevision += 1
        Task {
            let result = await monitor.setInputMuted(inputMute.state != .muted, on: inputMute)
            // Drop any refresh that began while the write was pending.
            muteRevision += 1
            updateInputMute(result.mute)
            failedInputMute = !result.accepted && result.mute?.uid == inputMute.uid
            inputMutePending = false
        }
    }

    private func updateInputMute(_ mute: AudioInputMute?) {
        if mute?.uid != inputMute?.uid { failedInputMute = false }
        inputMute = mute
    }

    func selectAirPodsMode(_ mode: AirPodsListeningMode, using monitor: AudioMonitor) {
        guard pendingID == nil, pendingAirPodsMode == nil, let target = airPodsOutput,
              target.currentMode != mode, target.supportedModes.contains(mode) else { return }
        pendingAirPodsMode = mode
        failedAirPodsMode = false
        airPodsRevision += 1
        Task {
            let accepted = await monitor.setAirPodsListeningMode(mode, on: target)
            let snapshot = await monitor.routes()
            airPodsRevision += 1
            updateAirPodsOutput(snapshot.airPodsOutput)
            failedAirPodsMode = airPodsOutput?.uid == target.uid && (!accepted || airPodsOutput?.currentMode != mode)
            pendingAirPodsMode = nil
        }
    }

    private func updateAirPodsOutput(_ output: AirPodsOutput?) {
        if output?.uid != airPodsOutput?.uid { failedAirPodsMode = false }
        airPodsOutput = output
    }
}

struct AudioDeviceRows: View {
    static let rowHeight: CGFloat = 28
    let devices: [AudioRoute]
    let direction: AudioDirection
    let picker: AudioDevicePicker
    let monitor: AudioMonitor
    var showsSummaryChips = false
    var inlineAirPods: AirPodsOutput? = nil
    var isPanelVisible = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(devices) { route in
                let selected = picker.routes?.selectedID(for: direction) == route.id
                let airPods = direction == .output && selected && picker.airPodsOutput?.deviceID == route.id
                    ? picker.airPodsOutput : nil
                Button {
                    picker.select(route, direction: direction, using: monitor)
                } label: {
                    AudioDeviceRowLabel(route: route, selected: selected, showsSummaryChips: showsSummaryChips) {
                        if picker.pendingID == route.id {
                            ProgressView().controlSize(.small).accessibilityHidden(true)
                        } else if let airPods {
                            AirPodsBatteryStatus(output: airPods, deviceSymbol: route.symbol, isVisible: isPanelVisible)
                                .id(airPods.uid)
                        } else if selected && !showsSummaryChips {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .buttonStyle(PanelActionStyle(highlightBleed: showsSummaryChips
                    ? EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6)
                    : EdgeInsets()))
                .disabled(picker.pendingID != nil || picker.inputMutePending || picker.pendingAirPodsMode != nil)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("RingABar.audio.\(direction.rawValue).\(route.id)")
                if let inlineAirPods, inlineAirPods.deviceID == route.id {
                    AirPodsControls(output: inlineAirPods, picker: picker, monitor: monitor)
                        .id(inlineAirPods.uid)
                        .padding(.vertical, 2)
                }
            }
        }
    }
}
