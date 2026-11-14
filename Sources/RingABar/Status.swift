import Foundation

enum BatteryStatus: Equatable {
    case unavailable
    case noBattery
    case battery(BatteryReading)

    var reading: BatteryReading? {
        guard case let .battery(reading) = self else { return nil }
        return reading
    }

    var percent: Int? {
        reading?.percent
    }

    var detail: String {
        switch self {
        case .unavailable: String(localized: "Status unavailable")
        case .noBattery: String(localized: "No internal battery")
        case let .battery(battery):
            if battery.charging { String(localized: "Charging") }
            else if !battery.pluggedIn { String(localized: "On battery power") }
            else if battery.percent == 100 { String(localized: "Fully charged") }
            else if let limit = battery.chargeLimit, limit < 100, battery.percent >= limit {
                String(localized: "Charging paused at limit")
            } else { String(localized: "Charging paused") }
        }
    }

    var symbol: String {
        switch self {
        case let .battery(battery) where battery.charging: "battery.100percent.bolt"
        case let .battery(battery) where battery.pluggedIn: "powerplug"
        case .noBattery: "powerplug"
        default: "battery.100percent"
        }
    }

    var accent: BatteryAccent? {
        guard let reading else { return nil }
        if reading.percent < 20 { return .critical }
        if reading.lowPower { return .lowPower }
        if reading.charging { return .charging }
        return nil
    }
}

struct BatteryReading: Equatable {
    var percent: Int
    var pluggedIn: Bool
    var charging = false
    var lowPower = false
    var chargeLimit: Int?
    var minutesRemaining: Int?

    var isPausedAtLimit: Bool {
        guard pluggedIn, !charging, let chargeLimit else { return false }
        return chargeLimit < 100 && percent >= chargeLimit && percent < 100
    }
}

enum BatteryAccent: Equatable {
    case charging, lowPower, critical
}

enum NetworkPath: String, Sendable {
    case unknown, wifi, ethernet, tunnel, other, offline

    var title: String {
        switch self {
        case .unknown: String(localized: "Checking connection")
        case .wifi: "Wi-Fi"
        case .ethernet: String(localized: "Ethernet")
        case .tunnel: String(localized: "Tunnel")
        case .other: String(localized: "Other network")
        case .offline: String(localized: "Offline")
        }
    }

    var symbol: String {
        switch self {
        case .unknown: "ellipsis"
        case .wifi: "wifi"
        case .ethernet: "cable.connector"
        case .tunnel: "point.3.connected.trianglepath.dotted"
        case .other: "network"
        case .offline: "wifi.slash"
        }
    }
}

struct NetworkStatus: Equatable, Sendable {
    var path = NetworkPath.unknown
    var primaryPath: NetworkPath?
    var signalDBm: Int?
    var hasWiredUnderlay = false
    var interfaceName: String?
    var physicalInterfaceName: String?
    var wifiPowered: Bool?
    var wifiName: String?
    var wifiPowerFailed = false
    var wifiIsHotspot = false

    /// Primary transport route for UI and status icon display, resolving
    /// through VPN/TUN overlays to the underlying Wi-Fi or Ethernet line.
    var effectivePath: NetworkPath {
        primaryPath ?? (hasWiredUnderlay ? .ethernet : path)
    }

    var showsWiFi: Bool {
        effectivePath == .wifi || (effectivePath != .ethernet && wifiPowered != nil)
    }
}

struct VPNStatus: Equatable, Sendable {
    var tunnel = false
    var services: [String] = []
    var proxy: SystemProxy?
    var controlled: [SystemVPNService] = []
    var target: SystemVPNService? {
        if let active = controlled.first(where: { $0.state == .connected || $0.state == .connecting || $0.state == .disconnecting }) {
            return active
        }
        guard !tunnel, proxy == nil, services.isEmpty else { return nil }
        return controlled.first { $0.enabled && $0.state == .disconnected }
    }
    var visible: Bool { tunnel || proxy != nil || !services.isEmpty || target != nil }
}

struct AudioStatus: Equatable, Sendable {
    var deviceID: UInt32?
    var deviceName: String?
    var volume: Double?
    var muted: Bool?
    var canSetVolume = false
    var canMute = false
    var controlFailed = false
    var isBluetooth = false
    var deviceSymbol = "speaker.wave.2.fill"

    var percent: Int? {
        volume.map { Int(($0 * 100).rounded()) }
    }
}
