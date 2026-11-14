import Darwin
import Foundation
import SystemConfiguration

struct NetworkDetails: Sendable {
    let interface: String?
    let ipv4: String?
    let ipv6: String?
    let router: String?
    let dns: [String]
    let systemProxy: SystemProxy?
    let activeVPNs: [String]
    let wifiChannel: Int?
    let wifiBand: String?
    let wifiRate: Double?
    let wifiNoise: Int?

    static func read(routeInterface: String?, wifiChannel: Int?, wifiBand: String?, wifiRate: Double?, wifiNoise: Int?) -> Self {
        func networkState(_ key: String) -> [String: Any] {
            SCDynamicStoreCopyValue(nil, ("State:/Network/" + key) as CFString) as? [String: Any] ?? [:]
        }
        let global4 = networkState("Global/IPv4")
        let global6 = networkState("Global/IPv6")
        let primary4 = global4["PrimaryInterface"] as? String
        let primary6 = global6["PrimaryInterface"] as? String
        let interface = primary4 ?? primary6 ?? routeInterface
        let service = global4["PrimaryService"] as? String ?? global6["PrimaryService"] as? String
        let dns = networkState("Global/DNS")["ServerAddresses"] as? [String]
            ?? service.flatMap { networkState("Service/\($0)/DNS")["ServerAddresses"] as? [String] }
            ?? []
        let ip4 = interface.flatMap { networkState("Interface/\($0)/IPv4")["Addresses"] as? [String] }
        let ip6 = interface.flatMap { networkState("Interface/\($0)/IPv6")["Addresses"] as? [String] }
        return Self(
            interface: interface,
            ipv4: ip4?.first,
            ipv6: ip6?.first { !$0.lowercased().hasPrefix("fe80:") },
            router: global4["Router"] as? String ?? global6["Router"] as? String,
            dns: dns,
            systemProxy: SystemProxy.read(),
            activeVPNs: activeVPNs().map(\.name),
            wifiChannel: wifiChannel,
            wifiBand: wifiBand,
            wifiRate: wifiRate,
            wifiNoise: wifiNoise
        )
    }

    static func vpn(pathTunnel: String?) -> VPNStatus {
        let services = activeVPNs()
        var tunnels = addressedTunnels()
        if let pathTunnel { tunnels.insert(pathTunnel) }
        return VPNStatus(
            tunnel: hasIndependentTunnel(tunnels, vpnInterfaces: services.map(\.interfaces)),
            services: services.map(\.name),
            proxy: SystemProxy.read(),
            controlled: SystemVPNService.read()
        )
    }

    static func hasIndependentTunnel(_ tunnels: Set<String>, vpnInterfaces: [Set<String>]) -> Bool {
        let identified = Set(vpnInterfaces.flatMap { $0 })
        let unassignedServices = vpnInterfaces.filter(\.isEmpty).count
        // A connected service without a published interface could own one of the
        // remaining tunnels. Show an independent TUN when there is still one left.
        return tunnels.subtracting(identified).count > unassignedServices
    }

    private static func addressedTunnels() -> Set<String> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }
        defer { freeifaddrs(head) }
        var next: UnsafeMutablePointer<ifaddrs>? = head
        var tunnels: Set<String> = []
        while let entry = next {
            let interface = entry.pointee
            next = interface.ifa_next
            guard interface.ifa_flags & UInt32(IFF_UP) != 0,
                  let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard NetworkMonitor.isTunnel(name) else { continue }
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let prefix = ipv4 >> 24
            if prefix > 0 && prefix < 224 && prefix != 127 && ipv4 >> 16 != 0xA9FE {
                tunnels.insert(name)
            }
        }
        return tunnels
    }

    private static func activeVPNs() -> [(name: String, interfaces: Set<String>)] {
        guard let preferences = SCPreferencesCreate(nil, "TrioRing" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { return [] }
        return services.compactMap { service in
            guard let interface = SCNetworkServiceGetInterface(service),
                  let type = SCNetworkInterfaceGetInterfaceType(interface),
                  ["PPP", "IPSec", "L2TP", "VPN"].contains(type as String),
                  let id = SCNetworkServiceGetServiceID(service),
                  let name = SCNetworkServiceGetName(service) as String?, !name.isEmpty,
                  let connection = SCNetworkConnectionCreateWithServiceID(nil, id, nil, nil),
                  SCNetworkConnectionGetStatus(connection) == .connected else { return nil }
            let status = SCNetworkConnectionCopyExtendedStatus(connection) as? [String: Any] ?? [:]
            let interfaces = ["IPv4", "IPv6", "PPP", "IPSec"].compactMap { section in
                (status[section] as? [String: Any])?["InterfaceName"] as? String
            }.filter(NetworkMonitor.isTunnel)
            return (name, Set(interfaces))
        }.sorted { $0.name < $1.name }
    }
}

enum SystemProxy: Equatable, Sendable {
    case manual(String)
    case automatic

    var displayValue: String {
        switch self {
        case .manual(let endpoint): endpoint
        case .automatic: String(localized: "Automatic")
        }
    }

    static func read() -> Self? {
        parse(SCDynamicStoreCopyProxies(nil) as? [String: Any] ?? [:])
    }

    static func parse(_ values: [String: Any]) -> Self? {
        func enabled(_ key: String) -> Bool { (values[key] as? NSNumber)?.boolValue == true }
        for protocolName in ["HTTP", "HTTPS", "SOCKS"] {
            guard enabled(protocolName + "Enable"), let rawHost = values[protocolName + "Proxy"] as? String,
                  let port = (values[protocolName + "Port"] as? NSNumber)?.intValue,
                  (1...65_535).contains(port) else { continue }
            let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { continue }
            let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
            return .manual("\(address):\(port)")
        }
        if enabled("ProxyAutoConfigEnable") || enabled("ProxyAutoDiscoveryEnable") { return .automatic }
        return nil
    }
}
