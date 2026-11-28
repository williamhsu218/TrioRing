import Foundation
import Observation
import OSLog
import ServiceManagement

@MainActor
@Observable
final class LoginItemManager {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var errorMessage: String?
    @ObservationIgnored private let logger = AppIdentity.logger(category: "LoginItem")

    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    var needsApproval: Bool {
        status == .requiresApproval
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        let service = SMAppService.mainApp
        errorMessage = nil
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            logger.error("Failed to update login item (\(enabled)): \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        status = service.status
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
