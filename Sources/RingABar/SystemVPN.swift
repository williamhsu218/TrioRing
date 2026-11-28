import Foundation
import SystemConfiguration

struct SystemVPNService: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case invalid, disconnected, connecting, connected, disconnecting

        init(_ status: SCNetworkConnectionStatus) {
            switch status {
            case .disconnected: self = .disconnected
            case .connecting: self = .connecting
            case .connected: self = .connected
            case .disconnecting: self = .disconnecting
            default: self = .invalid
            }
        }

        var stable: Bool { self == .connected || self == .disconnected }
    }

    let id: String
    let name: String
    let enabled: Bool
    let state: State

    static func read() -> [Self] {
        guard let preferences = SCPreferencesCreate(nil, "TrioRing" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { return [] }
        return services.compactMap { service in
            guard let interface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String?,
                  let id = SCNetworkServiceGetServiceID(service) as String?,
                  let name = SCNetworkServiceGetName(service) as String?, !name.isEmpty else { return nil }
            // NetworkExtension profiles owned by other apps are status only.
            guard [kSCNetworkInterfaceTypePPP as String, kSCNetworkInterfaceTypeIPSec as String,
                   kSCNetworkInterfaceTypeL2TP as String].contains(type) else { return nil }
            return Self(id: id, name: name, enabled: SCNetworkServiceGetEnabled(service),
                        state: Self.connection(id).map { State(SCNetworkConnectionGetStatus($0)) } ?? .invalid)
        }
    }

    private static func connection(_ id: String) -> SCNetworkConnection? {
        SCNetworkConnectionCreateWithServiceID(nil, id as CFString, nil, nil)
    }

    enum Result: Equatable, Sendable { case confirmed, rejected, unconfirmed }
    private static let queue = DispatchQueue(label: "com.willhsu.ring-a-bar.vpn", qos: .utility)

    private final class ConnectionBox: @unchecked Sendable {
        let connection: SCNetworkConnection
        init(_ connection: SCNetworkConnection) { self.connection = connection }
    }

    static func set(_ requested: Bool, service: Self) async -> Result {
        let started: ConnectionBox? = await withCheckedContinuation { continuation in
            queue.async {
                guard let current = read().first(where: { $0.id == service.id }), current.enabled,
                      current.state == service.state, current.state.stable,
                      let connection = connection(service.id) else {
                    continuation.resume(returning: nil)
                    return
                }
                let accepted = requested ? SCNetworkConnectionStart(connection, nil, true)
                                         : SCNetworkConnectionStop(connection, false)
                continuation.resume(returning: accepted ? ConnectionBox(connection) : nil)
            }
        }
        guard let started else { return .rejected }
        let target: SCNetworkConnectionStatus = requested ? .connected : .disconnected
        // A true return from Start/Stop only acknowledges submission.
        // Poll cooperatively without blocking the serial utility queue.
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !Task.isCancelled {
            let status: SCNetworkConnectionStatus = await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: SCNetworkConnectionGetStatus(started.connection))
                }
            }
            if status == target { return .confirmed }
            if status == .invalid { return .unconfirmed }
            if ContinuousClock.now >= deadline { break }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return .unconfirmed
            }
        }
        return .unconfirmed
    }
}
