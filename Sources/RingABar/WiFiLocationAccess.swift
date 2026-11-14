import CoreLocation
import CoreWLAN
import Observation

@MainActor
@Observable
final class WiFiLocationAccess: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var didRequest = false
    private(set) var status: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        status = manager.authorizationStatus
        manager.delegate = self
    }

    var allowed: Bool { status == .authorizedAlways }

    func request() -> Bool {
        guard status == .notDetermined, !didRequest else { return false }
        didRequest = true
        manager.requestWhenInUseAuthorization()
        return true
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in self?.status = status }
    }
}

/// Keep authentication types distinct: an open AP must never replace a secured
/// AP with the same name, including between the list scan and the join scan.
enum WiFiSecurity: Int, Hashable, Sendable {
    case open = 0, wep, wpaPersonal, wpaPersonalMixed, wpa2Personal, personal
    case dynamicWEP, wpaEnterprise, wpaEnterpriseMixed, wpa2Enterprise, enterprise
    case wpa3Personal, wpa3Enterprise, wpa3Transition, owe, oweTransition
    case unknown = -1

    var requiresPassword: Bool {
        [.wep, .wpaPersonal, .wpaPersonalMixed, .wpa2Personal, .personal,
         .wpa3Personal, .wpa3Transition].contains(self)
    }
    var supportsDirectJoin: Bool { self == .open || self == .owe || self == .oweTransition || requiresPassword }
    var native: CWSecurity { CWSecurity(rawValue: rawValue) ?? .unknown }

    static func detect(_ network: CWNetwork) -> Self {
        let priority: [Self] = [.wpa3Enterprise, .wpa2Enterprise, .wpaEnterpriseMixed, .wpaEnterprise,
                                .enterprise, .dynamicWEP, .wpa3Transition, .wpa3Personal, .wpa2Personal,
                                .wpaPersonalMixed, .wpaPersonal, .personal, .wep, .owe, .oweTransition, .open]
        return priority.first { network.supportsSecurity($0.native) } ?? .unknown
    }
}

struct NearbyWiFi: Sendable {
    struct Row: Identifiable, Hashable, Sendable {
        var id: String { ssidData.base64EncodedString() + ":\(security.rawValue)" }
        let name: String
        let ssidData: Data
        let signal: Int
        let security: WiFiSecurity
        var secured: Bool { security != .open }

        init(name: String, signal: Int, security: WiFiSecurity, ssidData: Data? = nil) {
            self.name = name
            self.ssidData = ssidData ?? Data(name.utf8)
            self.signal = signal
            self.security = security
        }

        init?(_ network: CWNetwork) {
            guard let name = network.ssid, !name.isEmpty, let data = network.ssidData else { return nil }
            self.init(name: name, signal: network.rssiValue, security: WiFiSecurity.detect(network), ssidData: data)
        }
    }
    let current: Row?
    let known: [Row]
    let other: [Row]

    static func scan() throws -> Self {
        guard let interface = CWWiFiClient.shared().interface() else {
            return Self(current: nil, known: [], other: [])
        }
        let profiles = Set(interface.configuration()?.networkProfiles.compactMap { ($0 as? CWNetworkProfile)?.ssidData } ?? [])
        var best: [String: Row] = [:]
        for item in try interface.scanForNetworks(withName: nil) {
            guard let candidate = Row(item) else { continue }
            if let old = best[candidate.id], old.signal >= candidate.signal { continue }
            best[candidate.id] = candidate
        }
        let current = interface.ssid().flatMap { name -> Row? in
            guard let data = interface.ssidData() else { return nil }
            return Row(name: name, signal: interface.rssiValue(),
                       security: WiFiSecurity(rawValue: interface.security().rawValue) ?? .unknown, ssidData: data)
        }
        let rows = best.values.filter { $0.ssidData != current?.ssidData }.sorted {
            if $0.signal != $1.signal { return $0.signal > $1.signal }
            return $0.id < $1.id
        }
        return Self(current: current,
                    known: rows.filter { profiles.contains($0.ssidData) },
                    other: rows.filter { !profiles.contains($0.ssidData) })
    }
}
