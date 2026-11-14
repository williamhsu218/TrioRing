import CoreWLAN
import Foundation
import Network
import SystemConfiguration

final class NetworkMonitor: NSObject, CWEventDelegate, @unchecked Sendable {
    struct InterfaceDescriptor: Equatable, Sendable {
        let name: String
        let type: NWInterface.InterfaceType
    }

    struct PathSnapshot: Equatable, Sendable {
        let satisfied: Bool
        let interfaces: [InterfaceDescriptor]
        let usesWiFi: Bool
        let usesWiredEthernet: Bool
        let usesOther: Bool
        let isExpensive: Bool
    }

    struct RouteSelection: Equatable, Sendable {
        let path: NetworkPath
        let primaryPath: NetworkPath
        let interfaceName: String?
        let physicalInterfaceName: String?
    }

    private let queue = DispatchQueue(label: "com.willhsu.ring-a-bar.network", qos: .utility)
    private let monitor = NWPathMonitor()
    private let onChange: @Sendable (NetworkStatus) -> Void

    // CoreWLAN and the last path are used only on the network queue.
    private lazy var wifi = CWWiFiClient()
    private var lastSnapshot: PathSnapshot?
    private var path = NetworkPath.unknown
    private var primaryPath: NetworkPath?
    private var hasWiredUnderlay = false
    private var interfaceName: String?
    private var physicalInterfaceName: String?
    private var wifiPowerFailed = false
    private var wifiIsHotspot = false

    init(onChange: @escaping @Sendable (NetworkStatus) -> Void) {
        self.onChange = onChange
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.receive(path)
        }
        monitor.start(queue: queue)
        queue.async {
            self.wifi.delegate = self
            for event: CWEventType in [.powerDidChange, .linkDidChange] {
                try? self.wifi.startMonitoringEvent(with: event)
            }
        }
    }

    func stop() {
        monitor.cancel()
        queue.async {
            try? self.wifi.stopMonitoringAllEvents()
            self.wifi.delegate = nil
        }
    }

    func refresh() {
        queue.async { self.publish() }
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        refresh()
    }

    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        refresh()
    }

    private func receive(_ update: NWPath) {
        lastSnapshot = PathSnapshot(
            satisfied: update.status == .satisfied,
            interfaces: update.availableInterfaces.map { InterfaceDescriptor(name: $0.name, type: $0.type) },
            usesWiFi: update.usesInterfaceType(.wifi),
            usesWiredEthernet: update.usesInterfaceType(.wiredEthernet),
            usesOther: update.usesInterfaceType(.other),
            isExpensive: update.isExpensive
        )
        publish()
    }

    private func applyLatestRoute() {
        guard let snapshot = lastSnapshot else { return }
        let route = Self.resolveRoute(snapshot: snapshot, primarySystemInterface: Self.readPrimarySystemInterface())
        path = route.path
        primaryPath = route.primaryPath
        interfaceName = route.interfaceName
        physicalInterfaceName = route.physicalInterfaceName
        hasWiredUnderlay = [.other, .tunnel].contains(route.path) && route.primaryPath == .ethernet
        wifiIsHotspot = snapshot.satisfied && (snapshot.usesWiFi || route.primaryPath == .wifi) && snapshot.isExpensive
    }

    private func publish() {
        applyLatestRoute()
        let effective = primaryPath ?? path
        let wireless = effective == .wifi
            ? (physicalInterfaceName.flatMap { wifi.interface(withName: $0) } ?? wifi.interface())
            : wifi.interface()
        let signal = wireless?.rssiValue()
        onChange(NetworkStatus(
            path: path, primaryPath: primaryPath,
            signalDBm: signal.flatMap { $0 < 0 ? $0 : nil },
            hasWiredUnderlay: hasWiredUnderlay,
            interfaceName: interfaceName,
            physicalInterfaceName: physicalInterfaceName,
            wifiPowered: wireless?.powerOn(), wifiName: wireless?.ssid(),
            wifiPowerFailed: wifiPowerFailed, wifiIsHotspot: wifiIsHotspot
        ))
    }

    static func resolveRoute(snapshot: PathSnapshot, primarySystemInterface: String?) -> RouteSelection {
        guard snapshot.satisfied else {
            return RouteSelection(path: .offline, primaryPath: .offline, interfaceName: nil, physicalInterfaceName: nil)
        }
        let preferred = snapshot.interfaces.first
        let interfaceName = preferred?.name
        let physical = snapshot.interfaces.filter { !($0.type == .other && isTunnel($0.name)) }
        let chosenPhysical = primarySystemInterface.flatMap { name in
            physical.first { $0.name == name }
        } ?? physical.first

        func networkPath(for type: NWInterface.InterfaceType) -> NetworkPath {
            switch type {
            case .wiredEthernet: .ethernet
            case .wifi: .wifi
            default: .other
            }
        }

        let path: NetworkPath
        if let preferred, preferred.type == .other, snapshot.usesOther, isTunnel(preferred.name) {
            path = .tunnel
        } else if let chosenPhysical {
            if chosenPhysical.type == .wiredEthernet, snapshot.usesWiredEthernet {
                path = .ethernet
            } else if chosenPhysical.type == .wifi, snapshot.usesWiFi {
                path = .wifi
            } else if snapshot.usesWiredEthernet && !snapshot.usesWiFi {
                path = .ethernet
            } else if snapshot.usesWiFi && !snapshot.usesWiredEthernet {
                path = .wifi
            } else {
                path = networkPath(for: chosenPhysical.type)
            }
        } else if snapshot.usesWiredEthernet {
            path = .ethernet
        } else if snapshot.usesWiFi {
            path = .wifi
        } else {
            path = .other
        }

        let primaryPath: NetworkPath
        if let chosenPhysical {
            primaryPath = networkPath(for: chosenPhysical.type)
        } else if path != .tunnel && path != .other {
            primaryPath = path
        } else if snapshot.usesWiredEthernet {
            primaryPath = .ethernet
        } else if snapshot.usesWiFi {
            primaryPath = .wifi
        } else {
            primaryPath = path
        }

        return RouteSelection(
            path: path,
            primaryPath: primaryPath,
            interfaceName: interfaceName,
            physicalInterfaceName: chosenPhysical?.name ?? interfaceName
        )
    }

    private static func readPrimarySystemInterface() -> String? {
        func read(_ key: String) -> String? {
            let dict = SCDynamicStoreCopyValue(nil, ("State:/Network/" + key) as CFString) as? [String: Any]
            return dict?["PrimaryInterface"] as? String
        }
        return read("Global/IPv4") ?? read("Global/IPv6")
    }

    func vpnStatus() async -> VPNStatus {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: NetworkDetails.vpn(pathTunnel: self.path == .tunnel ? self.interfaceName : nil))
            }
        }
    }

    func setWiFiPower(_ enabled: Bool) {
        queue.async {
            if let interface = self.wifi.interface() {
                do {
                    try interface.setPower(enabled)
                    self.wifiPowerFailed = false
                } catch {
                    self.wifiPowerFailed = true
                }
            } else {
                self.wifiPowerFailed = true
            }
            self.publish()
        }
    }

    static func isTunnel(_ name: String) -> Bool {
        ["utun", "ppp", "ipsec", "tun", "tap"].contains { prefix in
            name.hasPrefix(prefix) && Int(name.dropFirst(prefix.count)) != nil
        }
    }

    func details() async -> NetworkDetails {
        await withCheckedContinuation { continuation in
            queue.async {
                let effective = self.primaryPath ?? self.path
                let wireless = effective == .ethernet ? nil : self.wifi.interface()
                let wifiChannel = wireless?.wlanChannel()
                let channel = wifiChannel?.channelNumber
                let band: String? = switch wifiChannel?.channelBand.rawValue {
                case 1: "2.4 GHz"
                case 2: "5 GHz"
                case 3: "6 GHz"
                default: nil
                }
                let rate = wireless?.transmitRate()
                let noise = wireless?.noiseMeasurement()
                continuation.resume(returning: NetworkDetails.read(
                    routeInterface: self.interfaceName,
                    wifiChannel: channel.flatMap { $0 > 0 ? $0 : nil },
                    wifiBand: band,
                    wifiRate: rate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                    wifiNoise: noise.flatMap { $0 < 0 ? $0 : nil }
                ))
            }
        }
    }
}
