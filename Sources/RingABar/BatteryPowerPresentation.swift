import Foundation

extension BatteryPowerSnapshot {
    var flow: BatteryPowerFlowState? {
        var input: BatteryPowerFlowState.Metric?
        var branches: [BatteryPowerFlowState.Metric] = []
        if let split = breakdown {
            input = split.source == .battery
                ? metric(String(localized: "Battery discharge"), split.sourceWatts, .batterySource)
                : metric(String(localized: "Charger input"), split.sourceWatts, .input, detail: split.inputPortType)
            if split.chargingWatts > 0.05 {
                branches.append(metric(String(localized: "Battery charging"), split.chargingWatts, .charging))
            }
            if let display = split.display, display.watts > 0.05 {
                branches.append(metric(String(localized: "Display"), display.watts, .display,
                                       help: String(localized: "Built-in display backlight")))
            }
            for port in split.usbPorts {
                // A stable port label distinguishes otherwise identical USB nodes;
                // the complete device list remains available in help/VoiceOver.
                branches.append(metric(port.channelLabel, port.watts, .usb, help: port.measurementLabel))
            }
            if split.system.watts > 0.05 {
                branches.append(metric(String(localized: "System power (est.)"), split.system.watts, .system,
                                       help: String(localized: "Estimated system power (SoC, DRAM, Display Controller, and residual load)")))
            }
        } else {
            if let inputWatts, inputWatts > 0.05 {
                input = metric(String(localized: "Charger input"), inputWatts, .input, detail: inputPortType)
            } else if let watts = battery?.watts, watts < -0.05 {
                input = metric(String(localized: "Battery discharge"), -watts, .batterySource)
            }
            if let watts = battery?.watts, watts > 0.05 {
                branches.append(metric(String(localized: "Battery charging"), watts, .charging))
            }
            if let systemWatts {
                branches.append(metric(String(localized: "System total"), systemWatts, .system))
            }
        }
        guard input != nil || !branches.isEmpty else { return nil }
        return BatteryPowerFlowState(input: input, destinations: branches)
    }

    private func metric(_ label: String, _ watts: Double, _ kind: BatteryPowerFlowState.Kind,
                        detail: String? = nil, help: String? = nil) -> BatteryPowerFlowState.Metric {
        .init(label: label, value: Self.formatWatts(watts), watts: watts, kind: kind, help: help, detail: detail)
    }

    static func formatWatts(_ value: Double) -> String {
        let digits = (abs(value) * 100).rounded() / 100 >= 100 ? 0 : 2
        let number = value.formatted(.number.precision(.fractionLength(digits)))
        return String(localized: "\(number) W")
    }
}

extension USBPortOutput {
    var channelLabel: String { String(localized: "USB-C \(channel)") }

    var measurementLabel: String {
        guard !deviceNames.isEmpty else { return channelLabel }
        return channelLabel + " · " + deviceNames.joined(separator: ", ")
    }
}
