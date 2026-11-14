import AppKit
import SwiftUI
import ServiceManagement

struct GeneralSettingsPane: View {
    let globalShortcut: GlobalShortcutController
    let onRecordShortcut: () -> Void
    let onCancelShortcut: () -> Void
    var automaticallyChecksForUpdates: Binding<Bool>? = nil
    @StateObject private var loginItemManager = LoginItemManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard("Startup") {
                SettingsToggle(title: "Launch at login",
                               subtitle: "Start TrioRing automatically when you log in.",
                               symbol: "airplane.departure", tint: .gray,
                               isOn: Binding(
                                   get: { loginItemManager.isEnabled },
                                   set: { loginItemManager.setEnabled($0) }
                               ), id: "RingABar.settings.launchAtLogin")

                if loginItemManager.needsApproval {
                    SettingsRule()
                    SettingsRow(title: "Approval required",
                                subtitle: "Allow TrioRing in System Settings → Login Items & Extensions.",
                                symbol: "exclamationmark.triangle.fill", tint: .orange) {
                        Button("Open Login Items…") {
                            loginItemManager.openSystemSettings()
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier("RingABar.settings.openLoginItems")
                    }
                }

                if let error = loginItemManager.errorMessage {
                    SettingsRule()
                    SettingsNote(title: LocalizedStringKey(error))
                }
            }

            if let automaticallyChecksForUpdates {
                SettingsCard("Updates") {
                    SettingsToggle(title: "Automatically Check for Updates",
                                   subtitle: "Get a reminder when a new version is available. You choose when to install it.",
                                   symbol: "arrow.triangle.2.circlepath", tint: .blue,
                                   isOn: automaticallyChecksForUpdates, id: "RingABar.settings.automaticUpdates")
                }
            }

            ShortcutSettingsRow(controller: globalShortcut, onRecord: onRecordShortcut, onCancel: onCancelShortcut)
        }
        .onAppear { loginItemManager.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItemManager.refresh()
        }
    }
}
