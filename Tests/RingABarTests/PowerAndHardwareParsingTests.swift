import Foundation
import Testing
@testable import RingABar

struct PowerAndHardwareParsingTests {
    // MARK: - BatteryPowerBreakdown

    @Test func powerBreakdownSplitsAdapterInputAndClampsTinyNegativeResidual() throws {
        let now = Date()
        let display = SystemPowerSample(watts: 2.5, readAt: now)
        let usb = USBOutputSample(watts: 4.5, readAt: now, ports: [USBPortOutput(channel: 1, watts: 4.5, name: "SSD")])

        let split = try #require(BatteryPowerBreakdown.resolve(
            adapterInput: SystemPowerSample(watts: 30, readAt: now),
            charging: 10,
            discharge: 0,
            display: display,
            usb: usb,
            inputPortType: "MagSafe 3",
            now: now
        ))
        #expect(split.source == .adapter)
        #expect(split.sourceWatts == 30)
        #expect(split.chargingWatts == 10)
        #expect(abs(split.system.watts - 13.0) < 0.001)
        #expect(split.inputPortType == "MagSafe 3")

        // Small negative residual within -0.75 W tolerance clamps system load to 0.
        let tolerant = try #require(BatteryPowerBreakdown.resolve(
            adapterInput: SystemPowerSample(watts: 20, readAt: now),
            charging: 13.5,
            discharge: 0,
            display: SystemPowerSample(watts: 2.5, readAt: now),
            usb: USBOutputSample(watts: 4.5, readAt: now, ports: [USBPortOutput(channel: 1, watts: 4.5)]),
            now: now
        ))
        #expect(tolerant.system.watts == 0)

        // Residual below -0.75 W is physically inconsistent and must return nil.
        let invalid = BatteryPowerBreakdown.resolve(
            adapterInput: SystemPowerSample(watts: 20, readAt: now),
            charging: 15,
            discharge: 0,
            display: SystemPowerSample(watts: 2.5, readAt: now),
            usb: USBOutputSample(watts: 4.5, readAt: now, ports: [USBPortOutput(channel: 1, watts: 4.5)]),
            now: now
        )
        #expect(invalid == nil)
    }

    @Test func powerBreakdownFallsBackToBatteryDischargeAndRejectsStaleRails() throws {
        let now = Date()
        // Adapter below 5 W floor falls back to battery discharge (>= 1 W).
        let batterySplit = try #require(BatteryPowerBreakdown.resolve(
            adapterInput: SystemPowerSample(watts: 1.2, readAt: now),
            charging: 0,
            discharge: 12.5,
            display: SystemPowerSample(watts: 2.5, readAt: now),
            usb: nil,
            inputPortType: "USB-C",
            now: now
        ))
        #expect(batterySplit.source == .battery)
        #expect(batterySplit.sourceWatts == 12.5)
        #expect(batterySplit.chargingWatts == 0)
        #expect(abs(batterySplit.system.watts - 10.0) < 0.001)

        // Discharge below 1 W floor returns nil.
        #expect(BatteryPowerBreakdown.resolve(
            adapterInput: nil, charging: nil, discharge: 0.5, display: nil, usb: nil, now: now
        ) == nil)

        // Stale USB sample (> 30 s old) invalidates breakdown.
        let staleUSB = USBOutputSample(
            watts: 2.0,
            readAt: now.addingTimeInterval(-35),
            ports: [USBPortOutput(channel: 1, watts: 2.0)]
        )
        #expect(BatteryPowerBreakdown.resolve(
            adapterInput: SystemPowerSample(watts: 30, readAt: now),
            charging: 10,
            discharge: 0,
            display: nil,
            usb: staleUSB,
            now: now
        ) == nil)
    }

    // MARK: - USBPortTopology & USBOutputReader

    @Test func usbTopologyOrdersPortsFiltersInfrastructureAndNamesHubs() {
        let ports: [USBPortTopology.PortNode] = [
            .init(portDescription: "Port-USB-C@3", portNumber: 3, typeDescription: "USB-C"),
            .init(portDescription: "Port-USB-C@1", portNumber: 1, typeDescription: "USB-C")
        ]
        let devices: [USBPortTopology.DeviceNode] = [
            .init(portDescription: "Port-USB-C@1", name: "USB3 Hub", deviceClass: 0x09, locationID: 1),
            .init(portDescription: "Port-USB-C@1", name: "Billboard", deviceClass: 0x11, locationID: 2),
            .init(portDescription: "Port-USB-C@1", name: "Studio SSD", deviceClass: 0x00, locationID: 20),
            .init(portDescription: "Port-USB-C@1", name: "Watch Charger", deviceClass: 0x00, locationID: 10),
            .init(portDescription: "Port-USB-C@1", name: "Watch Charger", deviceClass: 0x00, locationID: 15)
        ]
        let usbCInput = USBPortTopology.PortNode(portDescription: "Port-USB-C@3", portNumber: 3, typeDescription: "USB-C")
        let topology = USBPortTopology.make(usbCPorts: ports, devices: devices, inputPort: usbCInput)

        #expect(topology.ports.map(\.channel) == [1, 2])
        #expect(topology.name(forChannel: 1) == "Watch Charger +1")
        #expect(topology.ports[0].deviceNames == ["Watch Charger", "Studio SSD"])
        #expect(topology.inputPortType == "USB-C")
        #expect(topology.inputChannel == 2)

        let magSafe = USBPortTopology.PortNode(portDescription: "Port-MagSafe@0", portNumber: 0, typeDescription: "MagSafe 3")
        let magSafeTopology = USBPortTopology.make(usbCPorts: ports, devices: devices, inputPort: magSafe)
        #expect(magSafeTopology.inputPortType == "MagSafe 3")
        #expect(magSafeTopology.inputChannel == nil)
    }

    @Test func usbOutputExcludesSinkChannelBeforeCapAndRespectsLiveIdleRails() throws {
        let now = Date()
        let topology = USBPortTopology(
            ports: [
                .init(channel: 1, portDescription: "Port-USB-C@1", deviceNames: ["SSD"]),
                .init(channel: 2, portDescription: "Port-USB-C@2", deviceNames: [])
            ],
            inputPortType: "USB-C",
            inputChannel: 2
        )
        let registry: [String: Any] = [
            "PowerOutDetails": [
                ["PortIndex": 1, "Watts": 4500.0]
            ]
        ]

        // Answered idle SMC rail (< 0.20 W) stays empty and must not fall back to PowerOutDetails.
        let idle = USBOutputReader.resolve(
            portRails: .measured(rails: [.init(channel: 1, watts: 0.12)], readAt: now),
            registry: registry,
            topology: topology,
            now: now
        )
        #expect(idle == nil)

        // Sink channel (280 W) dropped before 300 W sanity cap keeps real accessory channel.
        let withSink = try #require(USBOutputReader.resolve(
            portRails: .measured(rails: [.init(channel: 1, watts: 5.0), .init(channel: 2, watts: 299.0)], readAt: now),
            registry: [:],
            topology: topology,
            now: now
        ))
        #expect(withSink.ports.count == 1)
        #expect(withSink.ports[0].channel == 1)
        #expect(withSink.ports[0].name == "SSD")
        #expect(abs(withSink.watts - 5.0) < 0.001)

        // Unavailable SMC rails fall back to PowerOutDetails.
        let fallback = try #require(USBOutputReader.resolve(
            portRails: .unavailable,
            registry: registry,
            topology: topology,
            now: now
        ))
        #expect(abs(fallback.watts - 4.5) < 0.001)
        #expect(fallback.ports.first?.name == "SSD")
    }

    // MARK: - SystemPowerReader SMC Decoding

    @Test func smcReaderDecodesSensorEncodingsAndDisplayFallback() throws {
        let fltType: UInt32 = 0x666c7420 // "flt "
        let fpe2Type: UInt32 = 0x66706532 // "fpe2"
        let sp78Type: UInt32 = 0x73703738 // "sp78"
        let si16Type: UInt32 = 0x73693136 // "si16"
        let ui16Type: UInt32 = 0x75693136 // "ui16"

        func floatBytes(_ value: Float) -> [UInt8] {
            let bits = value.bitPattern
            return [
                UInt8(truncatingIfNeeded: bits),
                UInt8(truncatingIfNeeded: bits >> 8),
                UInt8(truncatingIfNeeded: bits >> 16),
                UInt8(truncatingIfNeeded: bits >> 24)
            ]
        }

        func mockExchange(_ table: [UInt32: (type: UInt32, size: UInt32, payload: [UInt8])]) -> ([UInt8]) -> [UInt8]? {
            { request in
                guard request.count == 80 else { return nil }
                let key = UInt32(request[0]) | UInt32(request[1]) << 8
                    | UInt32(request[2]) << 16 | UInt32(request[3]) << 24
                guard let entry = table[key] else {
                    var missing = [UInt8](repeating: 0, count: 80)
                    missing[40] = 0x84 // key not found
                    return missing
                }
                var response = request
                response[40] = 0
                if request[42] == 9 {
                    for i in 0..<4 {
                        response[28 + i] = UInt8(truncatingIfNeeded: entry.size >> (i * 8))
                        response[32 + i] = UInt8(truncatingIfNeeded: entry.type >> (i * 8))
                    }
                    return response
                }
                if request[42] == 5 {
                    for (idx, byte) in entry.payload.enumerated() {
                        response[48 + idx] = byte
                    }
                    return response
                }
                return nil
            }
        }

        let exchange = mockExchange([
            SystemPowerReader.Sensor.system.rawValue: (fltType, 4, floatBytes(18.5)),
            SystemPowerReader.Sensor.displayBacklight.rawValue: (fpe2Type, 2, [0x00, 0x0E]), // 14 / 4 = 3.5 W
            SystemPowerReader.batteryTemperatureKey: (sp78Type, 2, [0x20, 0x80]), // 32.5 °C
            SystemPowerReader.Sensor.batteryCurrent.rawValue: (si16Type, 2, [0xF0, 0xF8]), // -1808 mA = -1.808 A
            SystemPowerReader.Sensor.batteryVoltage.rawValue: (ui16Type, 2, [0x88, 0x30]), // 12424 mV = 12.424 V
            SystemPowerReader.portRailKey(channel: 1, voltage: true): (fltType, 4, floatBytes(5.0)),
            SystemPowerReader.portRailKey(channel: 1, voltage: false): (fltType, 4, floatBytes(0.5))
        ])

        #expect(SystemPowerReader.readWatts(exchange: exchange) == 18.5)
        // Missing PDBR falls back to PBLR.
        #expect(SystemPowerReader.readDisplay(exchange: exchange) == 3.5)
        let temp = SystemPowerReader.readScalar(key: SystemPowerReader.batteryTemperatureKey, exchange: exchange)
        #expect(temp.acknowledged)
        #expect(temp.value == 32.5)
        #expect(SystemPowerReader.readValue(sensor: .batteryCurrent, exchange: exchange) == -1.808)
        #expect(SystemPowerReader.readValue(sensor: .batteryVoltage, exchange: exchange) == 12.424)

        let rails = SystemPowerReader.readPortOutput(exchange: exchange)
        guard case let .measured(ports, _) = rails else {
            Issue.record("Expected measured SMC port rails")
            return
        }
        #expect(ports == [PortRail(channel: 1, watts: 2.5)])

        // Existing out-of-range PDBR must hide display branch rather than falling back to PBLR.
        let badPrimary = mockExchange([
            SystemPowerReader.Sensor.display.rawValue: (fltType, 4, floatBytes(500.0)),
            SystemPowerReader.Sensor.displayBacklight.rawValue: (fltType, 4, floatBytes(2.0))
        ])
        #expect(SystemPowerReader.readDisplay(exchange: badPrimary) == nil)
    }

    // MARK: - SystemChargeLimit

    @Test func systemChargeLimitParsesValidPolicyAndRejectsInvalidArchives() throws {
        func makePolicyPlist(className: String = "ChargeCtrlPolicy", limits: [Int]) throws -> Data {
            var objects: [Any] = ["$null", ["$classname": className]]
            for limit in limits { objects.append(["soclimit": limit]) }
            let archive: [String: Any] = ["$archiver": "NSKeyedArchiver", "$objects": objects]
            let archiveData = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
            return try PropertyListSerialization.data(fromPropertyList: ["policies": archiveData], format: .binary, options: 0)
        }

        #expect(SystemChargeLimit.parse(try makePolicyPlist(limits: [80])) == 80)
        #expect(SystemChargeLimit.parse(try makePolicyPlist(limits: [100])) == 100)
        #expect(SystemChargeLimit.parse(try makePolicyPlist(limits: [75])) == nil)
        #expect(SystemChargeLimit.parse(try makePolicyPlist(limits: [80, 90])) == nil)
        #expect(SystemChargeLimit.parse(try makePolicyPlist(className: "OtherPolicy", limits: [80])) == nil)
        #expect(SystemChargeLimit.parse(Data("not a plist".utf8)) == nil)
    }

    // MARK: - SystemProxy

    @Test func systemProxyParsesManualIPv6AutomaticAndDisabledStates() {
        #expect(SystemProxy.parse([:]) == nil)
        #expect(SystemProxy.parse(["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890]) == .manual("127.0.0.1:7890"))
        #expect(SystemProxy.parse(["SOCKSEnable": 1, "SOCKSProxy": "::1", "SOCKSPort": 1080]) == .manual("[::1]:1080"))
        #expect(SystemProxy.parse(["ProxyAutoConfigEnable": 1]) == .automatic)
        #expect(SystemProxy.parse(["ProxyAutoDiscoveryEnable": 1]) == .automatic)
        #expect(SystemProxy.parse(["HTTPEnable": 1, "HTTPProxy": " ", "HTTPPort": 8080]) == nil)
        #expect(SystemProxy.parse(["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 0]) == nil)
    }

    // MARK: - PowerModeState & WiFiSignalStrength

    @Test func powerModeParserHandlesUnifiedAndLegacyPmsetOutput() {
        let unified = PowerModeState.parse(
            live: " powermode 2\n lowpowermode 0\n",
            cap: "Capabilities for AC Power:\n powermode\n highpowermode\n"
        )
        #expect(unified == PowerModeState(current: .high, supportsLow: true, supportsHigh: true))

        let legacyLow = PowerModeState.parse(
            live: " lowpowermode 1\n",
            cap: "Capabilities for Battery Power:\n lowpowermode\n"
        )
        #expect(legacyLow == PowerModeState(current: .low, supportsLow: true, supportsHigh: false))

        let legacyAuto = PowerModeState.parse(
            live: " lowpowermode 0\n",
            cap: "Capabilities for AC Power:\n lowpowermode\n"
        )
        #expect(legacyAuto == PowerModeState(current: .automatic, supportsLow: true, supportsHigh: false))
    }

    @Test func wifiSignalStrengthMapsThresholdsConsistently() {
        #expect(WiFiSignalStrength.bars(for: nil) == 0)
        #expect(WiFiSignalStrength.bars(for: 0) == 0)
        #expect(WiFiSignalStrength.bars(for: 10) == 0)
        #expect(WiFiSignalStrength.bars(for: -95) == 0)
        #expect(WiFiSignalStrength.bars(for: -88) == 1)
        #expect(WiFiSignalStrength.bars(for: -78) == 2)
        #expect(WiFiSignalStrength.bars(for: -70) == 3)
        #expect(WiFiSignalStrength.variableValue(for: -60) == 1.0)
        #expect(WiFiSignalStrength.variableValue(for: -80) == 0.33)
        #expect(WiFiSignalStrength.variableValue(for: nil) == 0.0)
    }
}
