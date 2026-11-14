import AppKit
import Network
import Testing
@testable import RingABar

struct NetworkStatusTests {
    @Test func onlyEnabledSystemProxiesContributeEndpoints() {
        let inactive: [String: Any] = ["HTTPEnable": 0, "HTTPProxy": "localhost", "HTTPPort": 8080]
        #expect(SystemProxy.parse(inactive) == nil)
        let active = inactive.merging([
            "HTTPSEnable": 1, "HTTPSProxy": " ::1 ", "HTTPSPort": 8081, "ProxyAutoConfigEnable": 1
        ]) { _, new in new }
        #expect(SystemProxy.parse(active) == .manual("[::1]:8081"))
        #expect(SystemProxy.parse(["ProxyAutoConfigEnable": 1]) == .automatic)
        #expect(SystemProxy.parse(["ProxyAutoDiscoveryEnable": 1]) == .automatic)
        #expect(SystemProxy.parse(["SOCKSEnable": 1, "SOCKSProxy": "localhost", "SOCKSPort": 65_536]) == nil)
    }

    @Test func onlyUnclaimedInterfacesContributeIndependentTunnel() {
        #expect(!NetworkDetails.hasIndependentTunnel(["utun7"], vpnInterfaces: [["utun7"]]))
        #expect(NetworkDetails.hasIndependentTunnel(["utun7", "utun100"], vpnInterfaces: [["utun7"]]))
        #expect(!NetworkDetails.hasIndependentTunnel(["utun7"], vpnInterfaces: [[]]))
        #expect(NetworkDetails.hasIndependentTunnel(["utun7", "utun100"], vpnInterfaces: [[]]))
    }

    @Test func disconnectedServiceDoesNotReplaceActiveTunnelOrProxy() {
        let service = SystemVPNService(id: "example", name: "Example", enabled: true, state: .disconnected)
        #expect(VPNStatus(controlled: [service]).target == service)
        #expect(VPNStatus(tunnel: true, controlled: [service]).target == nil)
        #expect(VPNStatus(proxy: .automatic, controlled: [service]).target == nil)
        #expect(VPNStatus(services: ["Connected service"], controlled: [service]).target == nil)
    }

    @Test func tunnelOverlayResolvesPrimaryPhysicalRouteForIconAndStatus() {
        let wifiUnderTunnel = NetworkMonitor.PathSnapshot(
            satisfied: true,
            interfaces: [
                .init(name: "utun100", type: .other),
                .init(name: "en0", type: .wifi),
                .init(name: "utun7", type: .other)
            ],
            usesWiFi: false, usesWiredEthernet: false, usesOther: true, isExpensive: false
        )
        let resolvedWiFi = NetworkMonitor.resolveRoute(snapshot: wifiUnderTunnel, primarySystemInterface: "en0")
        #expect(resolvedWiFi.path == .tunnel)
        #expect(resolvedWiFi.primaryPath == .wifi)
        #expect(resolvedWiFi.interfaceName == "utun100")
        #expect(resolvedWiFi.physicalInterfaceName == "en0")

        let ethernetAndWiFiUnderTunnel = NetworkMonitor.PathSnapshot(
            satisfied: true,
            interfaces: [
                .init(name: "utun100", type: .other),
                .init(name: "en4", type: .wiredEthernet),
                .init(name: "en0", type: .wifi)
            ],
            usesWiFi: false, usesWiredEthernet: false, usesOther: true, isExpensive: false
        )
        let resolvedWired = NetworkMonitor.resolveRoute(snapshot: ethernetAndWiFiUnderTunnel, primarySystemInterface: "en4")
        #expect(resolvedWired.path == .tunnel)
        #expect(resolvedWired.primaryPath == .ethernet)
        #expect(resolvedWired.physicalInterfaceName == "en4")

        // When a full-tunnel VPN sets PrimaryInterface to utun4, fall back to the first physical interface.
        let fullTunnelOverWiFi = NetworkMonitor.PathSnapshot(
            satisfied: true,
            interfaces: [
                .init(name: "utun4", type: .other),
                .init(name: "en0", type: .wifi),
                .init(name: "en4", type: .wiredEthernet)
            ],
            usesWiFi: false, usesWiredEthernet: false, usesOther: true, isExpensive: false
        )
        let resolvedFallback = NetworkMonitor.resolveRoute(snapshot: fullTunnelOverWiFi, primarySystemInterface: "utun4")
        #expect(resolvedFallback.path == .tunnel)
        #expect(resolvedFallback.primaryPath == .wifi)
        #expect(resolvedFallback.physicalInterfaceName == "en0")

        // Respect primary route order when both Wi-Fi and Ethernet are active without a tunnel.
        let wifiPrimaryOverEthernet = NetworkMonitor.PathSnapshot(
            satisfied: true,
            interfaces: [.init(name: "en0", type: .wifi), .init(name: "en4", type: .wiredEthernet)],
            usesWiFi: true, usesWiredEthernet: true, usesOther: false, isExpensive: false
        )
        let resolvedWiFiPrimary = NetworkMonitor.resolveRoute(snapshot: wifiPrimaryOverEthernet, primarySystemInterface: "en0")
        #expect(resolvedWiFiPrimary.path == .wifi)
        #expect(resolvedWiFiPrimary.primaryPath == .wifi)

        // Tunnel with no physical underlay keeps .tunnel.
        let tunnelOnly = NetworkMonitor.PathSnapshot(
            satisfied: true,
            interfaces: [.init(name: "utun4", type: .other)],
            usesWiFi: false, usesWiredEthernet: false, usesOther: true, isExpensive: false
        )
        let resolvedTunnelOnly = NetworkMonitor.resolveRoute(snapshot: tunnelOnly, primarySystemInterface: "utun4")
        #expect(resolvedTunnelOnly.path == .tunnel)
        #expect(resolvedTunnelOnly.primaryPath == .tunnel)
    }

    @Test @MainActor func statusIconUsesPrimaryRouteInsteadOfTunnelOverlay() throws {
        _ = NSApplication.shared
        let preferences = IconPreferences()
        let battery = BatteryStatus.battery(.init(percent: 80, pluggedIn: true, chargeLimit: 80))
        let audio = AudioStatus(volume: 0.5)

        let tunnelOverWiFi = NetworkStatus(
            path: .tunnel, primaryPath: .wifi, signalDBm: -45,
            interfaceName: "utun100", physicalInterfaceName: "en0", wifiPowered: true
        )
        let directWiFi = NetworkStatus(path: .wifi, primaryPath: .wifi, signalDBm: -45, interfaceName: "en0", wifiPowered: true)
        let tunnelOnly = NetworkStatus(path: .tunnel, primaryPath: .tunnel, interfaceName: "utun100")

        let overWiFiPNG = try #require(StatusIcon(battery: battery, network: tunnelOverWiFi, audio: audio, preferences: preferences)
            .image(layer: .template)?.tiffRepresentation)
        let directWiFiPNG = try #require(StatusIcon(battery: battery, network: directWiFi, audio: audio, preferences: preferences)
            .image(layer: .template)?.tiffRepresentation)
        let tunnelOnlyPNG = try #require(StatusIcon(battery: battery, network: tunnelOnly, audio: audio, preferences: preferences)
            .image(layer: .template)?.tiffRepresentation)

        #expect(overWiFiPNG == directWiFiPNG)
        #expect(overWiFiPNG != tunnelOnlyPNG)

        // Ethernet primary under tunnel with Wi-Fi powered on still shows Ethernet, not Wi-Fi or tunnel.
        let tunnelOverWiredWithWiFiOn = NetworkStatus(
            path: .tunnel, primaryPath: .ethernet, hasWiredUnderlay: true,
            interfaceName: "utun100", physicalInterfaceName: "en4", wifiPowered: true
        )
        let directWired = NetworkStatus(path: .ethernet, primaryPath: .ethernet, interfaceName: "en4", wifiPowered: true)
        #expect(!tunnelOverWiredWithWiFiOn.showsWiFi)
        let overWiredPNG = try #require(StatusIcon(battery: battery, network: tunnelOverWiredWithWiFiOn, audio: audio, preferences: preferences)
            .image(layer: .template)?.tiffRepresentation)
        let directWiredPNG = try #require(StatusIcon(battery: battery, network: directWired, audio: audio, preferences: preferences)
            .image(layer: .template)?.tiffRepresentation)
        #expect(overWiredPNG == directWiredPNG)
    }
}
