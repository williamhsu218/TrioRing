import AppKit

@MainActor
final class VolumeScrollController {
    private let store: StatusStore
    private let preferences: Preferences
    private let audio: AudioMonitor
    private let panel: AnchoredPanel
    private var volumeWrite: Task<Void, Never>?
    private var queuedVolume: (value: Double, device: UInt32)?

    init(store: StatusStore, preferences: Preferences, audio: AudioMonitor, panel: AnchoredPanel) {
        self.store = store
        self.preferences = preferences
        self.audio = audio
        self.panel = panel
    }

    func scheduleVolume(_ value: Double, on device: UInt32) {
        queuedVolume = (value, device)
        volumeWrite?.cancel()
        volumeWrite = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
            self?.queuedVolume = nil
            self?.audio.setVolume(value, on: device)
        }
    }

    func handleScroll(_ event: NSEvent) -> Bool {
        let pointer = NSEvent.mouseLocation
        let overScrollableSummary = store.page == .summary && store.summaryCanScroll
            && pointer.y >= panel.frame.minY + StatusPanel.summaryFooterHeight
        let sliderOnly = preferences.scrollOnVolumeSliderOnly || store.page != .summary || overScrollableSummary
        let showsOutput = store.page == .summary || (store.page == .details(.audio) && store.audioDirection == .output)
        guard showsOutput, !sliderOnly || store.pointerOverOutputSlider,
              preferences.scrollToAdjustVolume, !preferences.hiddenSections.contains(.audio),
              panel.frame.contains(pointer),
              store.audio.canSetVolume, let device = store.audio.deviceID, let level = store.audio.volume,
              abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return false }
        if !event.momentumPhase.isEmpty { return true }

        let current = queuedVolume.flatMap { $0.device == device ? $0.value : nil } ?? level
        let scroll = preferences.naturalVolumeScroll && event.isDirectionInvertedFromDevice
            ? -event.scrollingDeltaY : event.scrollingDeltaY
        let delta = event.hasPreciseScrollingDeltas ? scroll / 240 : (scroll > 0 ? 1.0 / 16 : -1.0 / 16)
        let next = min(1, max(0, current + delta))
        VolumeHaptics.performIfStepChanged(
            from: VolumeHaptics.step(for: current),
            to: next,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        scheduleVolume(next, on: device)
        return true
    }

    func resetIfDeviceChanged(from oldDevice: UInt32?, to newDevice: UInt32?) {
        guard oldDevice != newDevice else { return }
        cancel()
    }

    func cancel() {
        volumeWrite?.cancel()
        volumeWrite = nil
        queuedVolume = nil
    }
}
