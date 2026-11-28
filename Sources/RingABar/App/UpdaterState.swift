import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class UpdaterState {
    private let updater: SPUUpdater
    private(set) var canCheckForUpdates: Bool
    private(set) var automaticallyChecksForUpdates: Bool

    @ObservationIgnored private var autoCheckObservation: NSKeyValueObservation?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    init(updater: SPUUpdater) {
        self.updater = updater
        self.canCheckForUpdates = updater.canCheckForUpdates
        self.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates

        autoCheckObservation = updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.automaticallyChecksForUpdates = self.updater.automaticallyChecksForUpdates
            }
        }
        canCheckObservation = updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.canCheckForUpdates = self.updater.canCheckForUpdates
            }
        }
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        if updater.automaticallyChecksForUpdates != enabled {
            updater.automaticallyChecksForUpdates = enabled
        }
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
    }
}
