import SwiftUI

/// Password draft belongs to this presentation, never the store or preferences.
/// The native association outlives a dismissed panel; the draft does not.
struct WiFiConnectionView: View {
    let controller: WiFiConnectionController
    let onOpenSettings: () -> Void
    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        Group {
            switch controller.phase {
            case .idle:
                EmptyView()
            case .connecting(let row):
                feedbackCard(tint: .primary, backgroundOpacity: 0.05, borderOpacity: 0.08) {
                    ProgressView { Text("Connecting to \(row.name)…").lineLimit(2) }
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("RingABar.network.connecting")
                }
            case .passwordRequired(let row, let error):
                feedbackCard(tint: .primary, backgroundOpacity: 0.05, borderOpacity: 0.08) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Join \(row.name)").fontWeight(.medium).lineLimit(2)
                        if let error { Text(error.message).foregroundStyle(.red) }
                        SecureField("Wi-Fi password", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .focused($passwordFocused)
                            .onSubmit(submit)
                            .accessibilityIdentifier("RingABar.network.password")
                        Text("TrioRing does not store passwords.").foregroundStyle(.secondary)
                        HStack {
                            Button("Cancel") { controller.dismissPrompt() }
                                .accessibilityIdentifier("RingABar.network.cancelJoin")
                            Spacer(minLength: 8)
                            Button("Join", action: submit)
                                .disabled(password.isEmpty)
                                .accessibilityIdentifier("RingABar.network.join")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .onExitCommand { controller.dismissPrompt() }
                    .accessibilityIdentifier("RingABar.network.passwordPrompt")
                }
            case .connected(let row):
                feedbackCard(tint: .green, backgroundOpacity: 0.10, borderOpacity: 0.25) {
                    HStack(alignment: .top, spacing: 8) {
                        Label {
                            Text("Connected to \(row.name)").lineLimit(2)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Spacer(minLength: 0)
                        dismissButton
                    }
                    .accessibilityIdentifier("RingABar.network.joined")
                }
            case .failed(let row, let error):
                feedbackCard(tint: .red, backgroundOpacity: 0.08, borderOpacity: 0.22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Could not join \(row.name)").fontWeight(.medium).lineLimit(2)
                        Text(error.message).foregroundStyle(.red)
                        HStack {
                            if error != .unsupported {
                                Button("Try Again") { Task { await controller.join(row) } }
                                if row.security.requiresPassword {
                                    Button("Enter Password…") { controller.requestPassword(for: row) }
                                }
                            }
                            Spacer(minLength: 0)
                            dismissButton
                        }
                        Button("Open Wi-Fi Settings", action: onOpenSettings)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("RingABar.network.joinError")
                }
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: controller.phase) { _, phase in
            password = ""
            if case .passwordRequired = phase { passwordFocused = true }
            else { passwordFocused = false }
        }
        .onAppear {
            if case .passwordRequired = controller.phase { passwordFocused = true }
        }
        .onDisappear {
            password = ""
            controller.dismissPrompt()
        }
    }

    private func feedbackCard<Content: View>(tint: Color,
                                             backgroundOpacity: Double,
                                             borderOpacity: Double,
                                             @ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(tint.opacity(backgroundOpacity),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint.opacity(borderOpacity), lineWidth: 0.5)
            }
    }

    private var dismissButton: some View {
        Button { controller.clearResult() } label: { Image(systemName: "xmark") }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
    }

    private func submit() {
        guard !password.isEmpty else { return }
        let credential = password
        password = ""
        Task { await controller.submit(password: credential) }
    }
}
