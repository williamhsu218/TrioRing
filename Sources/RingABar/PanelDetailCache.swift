import Foundation
import Observation

/// Scoped to a single panel presentation, not a persistent source of telemetry.
/// Navigating back to a page can reuse its last sample while it refreshes.
@MainActor @Observable
final class BatteryPageCache {
    var pluggedIn: Bool?
    var details: BatteryDetails?
    var power: BatteryPowerSnapshot?

    func prepare(pluggedIn: Bool) {
        guard self.pluggedIn != pluggedIn else { return }
        self.pluggedIn = pluggedIn
        details = nil
        power = nil
    }
}

struct NetworkPageIdentity: Equatable {
    let path: NetworkPath
    let interface: String?
    let name: String?
    let powered: Bool?
    let locationAllowed: Bool

    init(status: NetworkStatus, locationAllowed: Bool) {
        path = status.path
        interface = status.interfaceName
        name = status.wifiName
        powered = status.wifiPowered
        self.locationAllowed = locationAllowed
    }
}

@MainActor @Observable
final class NetworkPageCache {
    var identity: NetworkPageIdentity?
    var details: NetworkDetails?
    var nearby: NearbyWiFi?
    var scannedAt: Date?

    func prepare(identity: NetworkPageIdentity) {
        guard self.identity != identity else { return }
        self.identity = identity
        details = nil
        nearby = nil
        scannedAt = nil
    }

    func canReuseScan(for identity: NetworkPageIdentity, now: Date = .now) -> Bool {
        guard self.identity == identity, nearby != nil, let scannedAt else { return false }
        let age = now.timeIntervalSince(scannedAt)
        return (0..<30).contains(age)
    }
}
