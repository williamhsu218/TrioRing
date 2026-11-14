import CoreWLAN
import Foundation
import Observation
import Security

protocol WiFiJoining: Sendable {
    func join(_ network: NearbyWiFi.Row, password: String?) async throws
}

enum WiFiJoinError: Error, Equatable, Sendable {
    case passwordRequired, authentication, unavailable, poweredOff, notFound, unsupported
    case permission, timedOut, unconfirmed, system(Int)

    var message: String {
        switch self {
        case .passwordRequired: String(localized: "Enter the password for this network.")
        case .authentication: String(localized: "Could not authenticate. Check the password and try again.")
        case .unavailable: String(localized: "No Wi-Fi interface is available.")
        case .poweredOff: String(localized: "Turn on Wi-Fi before joining a network.")
        case .notFound: String(localized: "This network is no longer available with the same security. Refresh the list.")
        case .unsupported: String(localized: "This network requires enterprise authentication or system configuration. Use Wi-Fi Settings.")
        case .permission: String(localized: "macOS denied this connection. Check Wi-Fi and location access in System Settings.")
        case .timedOut: String(localized: "The connection timed out. Move closer to the network and try again.")
        case .unconfirmed: String(localized: "The selected network could not be confirmed. Refresh or check Wi-Fi Settings.")
        case .system(let code): String(localized: "Could not join this network (error \(code)). Try again or use Wi-Fi Settings.")
        }
    }

    static func association(_ error: NSError) -> Self {
        guard error.domain == CWErrorDomain, let code = CWErr(rawValue: error.code) else { return .system(error.code) }
        switch code {
        case .cwInvalidParameterErr, .cwInvalidFormatErr, .cwChallengeFailureErr,
             .cwInvalidPMKErr, .cweapolErr: return .authentication
        case .cwTimeoutErr, .cwSupplicantTimeoutErr: return .timedOut
        case .cwOperationNotPermittedErr: return .permission
        case .cwNotSupportedErr, .cwUnsupportedCapabilitiesErr,
             .cwAuthenticationAlgorithmUnsupportedErr: return .unsupported
        default: return .system(error.code)
        }
    }
}

/// All blocking CoreWLAN/Keychain work runs on one dedicated queue, never on
/// the main actor or the cooperative executor. No shell, admin helper, stored
/// credentials, explicit disassociation, or global network configuration edits.
final class CoreWLANJoiner: WiFiJoining, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.willhsu.ring-a-bar.wifi-join", qos: .userInitiated)

    func join(_ network: NearbyWiFi.Row, password: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try Self.associate(network, password: password)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func associate(_ row: NearbyWiFi.Row, password: String?) throws {
        guard row.security.supportsDirectJoin else { throw WiFiJoinError.unsupported }
        let client = CWWiFiClient()
        defer { withExtendedLifetime(client) {} }
        guard let interface = client.interface() else { throw WiFiJoinError.unavailable }
        guard interface.powerOn() else { throw WiFiJoinError.poweredOff }
        // Clicking the currently connected network must never reassociate it.
        if interface.ssidData() == row.ssidData {
            guard WiFiSecurity(rawValue: interface.security().rawValue) == row.security else { throw WiFiJoinError.unconfirmed }
            return
        }
        let networks: Set<CWNetwork>
        do { networks = try interface.scanForNetworks(withSSID: row.ssidData) }
        catch { throw WiFiJoinError.association(error as NSError) }
        // Resolve a fresh native object and require the exact SSID bytes AND
        // advertised authentication type selected by the user. Never send a
        // password to an open or changed-security AP with the same display name.
        guard let target = networks.filter({ NearbyWiFi.Row($0)?.id == row.id })
            .max(by: { $0.rssiValue < $1.rssiValue }) else { throw WiFiJoinError.notFound }
        let credential: String?
        if row.security.requiresPassword {
            credential = password ?? savedPassword(ssid: row.ssidData)
            guard let credential, !credential.isEmpty else { throw WiFiJoinError.passwordRequired }
        } else {
            credential = nil
        }
        // Do not turn the radio on or disconnect the old network in advance.
        guard interface.powerOn() else { throw WiFiJoinError.poweredOff }
        do { try interface.associate(to: target, password: credential) }
        catch { throw WiFiJoinError.association(error as NSError) }
        guard interface.ssidData() == row.ssidData else { throw WiFiJoinError.unconfirmed }
    }

    private static func savedPassword(ssid: Data) -> String? {
        // A user-initiated join may cause a native Keychain authorization dialog.
        // If access is denied/cancelled, do not prompt through another domain;
        // offer an in-app SecureField instead. Never change any Keychain ACL.
        for domain: CWKeychainDomain in [.user, .system] {
            var password: NSString?
            let status = CWKeychainFindWiFiPassword(domain, ssid, &password)
            if status == errSecSuccess { return password as String? }
            if status != errSecItemNotFound { return nil }
        }
        return nil
    }
}

/// Owned by StatusStore, so dismissing/reopening the panel cannot start a second
/// association while a native join is still in progress. Only explicit user
/// actions call the service; merely constructing/rendering this model is inert.
@MainActor @Observable
final class WiFiConnectionController {
    enum Phase: Equatable {
        case idle
        case connecting(NearbyWiFi.Row)
        case passwordRequired(NearbyWiFi.Row, WiFiJoinError?)
        case connected(NearbyWiFi.Row)
        case failed(NearbyWiFi.Row, WiFiJoinError)
    }
    private(set) var phase = Phase.idle
    private let joiner: any WiFiJoining
    private let connectedBannerDuration: Duration?
    private let bannerSleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private(set) var autoDismissTask: Task<Void, Never>?
    @ObservationIgnored private var connectedGeneration: UInt64 = 0

    init(joiner: any WiFiJoining = CoreWLANJoiner(),
         connectedBannerDuration: Duration? = .seconds(4),
         bannerSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.joiner = joiner
        self.connectedBannerDuration = connectedBannerDuration
        self.bannerSleep = bannerSleep
    }

    var busy: Bool { if case .connecting = phase { true } else { false } }
    var connectedNetwork: NearbyWiFi.Row? {
        if case .connected(let network) = phase { network } else { nil }
    }

    func isCurrent(_ row: NearbyWiFi.Row, scannedCurrentID: String?) -> Bool {
        guard let selected = connectedNetwork else { return row.id == scannedCurrentID }
        // Before the rescan, mark only the selected security variant, not an
        // open AP sharing its SSID. Afterwards accept the native current row:
        // negotiated WPA3 can differ from the advertised transition-mode type.
        return row.id == selected.id || (row.id == scannedCurrentID && row.ssidData == selected.ssidData)
    }

    func join(_ row: NearbyWiFi.Row, currentSSID: Data? = nil) async {
        guard !busy, row.ssidData != currentSSID else { return }
        guard row.security.supportsDirectJoin else {
            cancelAutoDismiss()
            phase = .failed(row, .unsupported)
            return
        }
        await perform(row, password: nil)
    }

    func submit(password: String) async {
        guard case .passwordRequired(let row, _) = phase, !password.isEmpty else { return }
        await perform(row, password: password)
    }

    func requestPassword(for row: NearbyWiFi.Row) {
        guard !busy, row.security.requiresPassword else { return }
        cancelAutoDismiss()
        phase = .passwordRequired(row, nil)
    }

    func dismissPrompt() {
        guard case .passwordRequired = phase else { return }
        cancelAutoDismiss()
        phase = .idle
    }

    func clearResult() {
        guard !busy else { return }
        cancelAutoDismiss()
        phase = .idle
    }

    private func perform(_ row: NearbyWiFi.Row, password: String?) async {
        cancelAutoDismiss()
        phase = .connecting(row)
        do {
            try await joiner.join(row, password: password)
            phase = .connected(row)
            scheduleConnectedAutoDismiss()
        } catch {
            let failure = error as? WiFiJoinError ?? .system((error as NSError).code)
            if row.security.requiresPassword && [.passwordRequired, .authentication].contains(failure) {
                phase = .passwordRequired(row, failure == .authentication ? failure : nil)
            } else {
                phase = .failed(row, failure)
            }
        }
    }

    private func scheduleConnectedAutoDismiss() {
        guard let duration = connectedBannerDuration else { return }
        connectedGeneration &+= 1
        let expectedGeneration = connectedGeneration
        let sleep = bannerSleep
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            do {
                try await sleep(duration)
            } catch {
                return
            }
            guard let self, self.connectedGeneration == expectedGeneration,
                  case .connected = self.phase else { return }
            self.autoDismissTask = nil
            self.phase = .idle
        }
    }

    private func cancelAutoDismiss() {
        connectedGeneration &+= 1
        autoDismissTask?.cancel()
        autoDismissTask = nil
    }
}
