import AppKit
import Foundation
import Testing
@testable import RingABar

struct AirPodsBatteryTests {
    @Test func readsOnlyTheMatchingConnectedDevice() throws {
        let data = try report(connected: [
            ["device_address": "01-02-03-04-05-06", "device_vendorID": "0x004C",
             "device_batteryLevelLeft": "27%", "device_batteryLevelRight": "105%",
             "device_batteryLevelCase": "91%"],
            ["device_address": "11:12:13:14:15:16", "device_vendorID": "0x004C",
             "device_batteryLevelMain": "99%"],
        ], disconnected: [
            ["device_address": "21:22:23:24:25:26", "device_vendorID": "0x004C",
             "device_batteryLevelMain": "85%"],
        ])
        #expect(AirPodsBattery.parse(data, address: "010203040506")
                == AirPodsBattery(main: nil, left: 27, right: nil, chargingCase: 91))
        #expect(AirPodsBattery.parse(data, address: "212223242526") == nil)
    }

    @Test func rejectsAmbiguousAddress() throws {
        let device = ["device_address": "01:02:03:04:05:06", "device_vendorID": "0x004C",
                      "device_batteryLevelCase": "91%"]
        let data = try report(connected: [device, device])
        #expect(AirPodsBattery.parse(data, address: "010203040506") == nil)
    }

    @Test func iconReadingsKeepLeftRightCaseOrderWithoutDuplicatingMain() {
        let battery = AirPodsBattery(main: 41, left: 39, right: 45, chargingCase: 100)
        #expect(battery.readings == [
            .init(component: .left, percent: 39),
            .init(component: .right, percent: 45),
            .init(component: .chargingCase, percent: 100)
        ])
    }

    @Test func missingEarAndCaseReadingsAreNotInvented() {
        let partial = AirPodsBattery(main: 80, left: nil, right: 0, chargingCase: nil)
        #expect(partial.readings == [.init(component: .right, percent: 0)])
        let combined = AirPodsBattery(main: 63, left: nil, right: nil, chargingCase: 100)
        #expect(combined.readings == [.init(component: .main, percent: 63),
                                     .init(component: .chargingCase, percent: 100)])
        #expect(AirPodsBattery(main: nil, left: nil, right: nil, chargingCase: nil).readings.isEmpty)
    }

    @Test @MainActor func batterySymbolsExistForSupportedAirPodsFamilies() {
        for deviceSymbol in ["airpods", "airpods.gen3", "airpods.gen4", "airpodspro", "airpodsmax"] {
            for component in [AirPodsBattery.Component.left, .right, .chargingCase, .main] {
                let symbol = component.symbol(deviceSymbol: deviceSymbol)
                #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                        "Missing battery symbol: \(symbol)")
            }
        }
    }

    private func report(connected: [[String: String]], disconnected: [[String: String]] = []) throws -> Data {
        let controller = [
            "device_connected": connected.map { ["Headphones": $0] },
            "device_not_connected": disconnected.map { ["Headphones": $0] }
        ]
        return try JSONSerialization.data(withJSONObject: ["SPBluetoothDataType": [controller]])
    }
}
