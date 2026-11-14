import Foundation
import OSLog
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    @Published private(set) var errorMessage: String?
    private let logger = Logger(subsystem: "com.willhsu.ring-a-bar", category: "LoginItem")

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
