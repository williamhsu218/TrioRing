import SwiftUI

/// Battery belongs to the device heading, not to its listening-mode controls.
struct AirPodsBatteryStatus: View {
    let output: AirPodsOutput
    let deviceSymbol: String
    let isVisible: Bool
    @State private var battery: AirPodsBattery?
    @State private var didReadBattery = false

    var body: some View {
        Group {
            if let battery, !battery.readings.isEmpty {
                AirPodsBatteryIndicators(battery: battery, deviceSymbol: deviceSymbol)
            } else if didReadBattery {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .help("Battery unavailable")
                    .accessibilityLabel("Battery unavailable")
            } else {
                ProgressView()
                    .controlSize(.mini)
                    .help("Reading battery…")
                    .accessibilityLabel("Reading battery…")
            }
        }
        .accessibilityIdentifier("RingABar.audio.airpods.battery")
        .task(id: isVisible ? output.uid : nil) {
            guard isVisible else { return }
            let uid = output.uid
            while !Task.isCancelled {
                let result = await Task.detached(priority: .utility) { AirPodsBattery.read(outputUID: uid) }.value
                guard !Task.isCancelled else { return }
                battery = result
                didReadBattery = true
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }
}

/// Compact columns keep all three readings alongside an ordinary device name
/// at the 330pt panel width. Text labels remain available to help and VoiceOver.
struct AirPodsBatteryIndicators: View {
    let battery: AirPodsBattery
    let deviceSymbol: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(battery.readings) { reading in
                let percent = (Double(reading.percent) / 100).formatted(.percent.precision(.fractionLength(0)))
                VStack(spacing: 0) {
                    Image(systemName: reading.component.symbol(deviceSymbol: deviceSymbol))
                        .font(.system(size: 12))
                        .frame(height: 13)
                    Text(percent)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                }
                .frame(minWidth: 25)
                .foregroundStyle(.secondary)
                .help(Text(verbatim: reading.component.title + ": " + percent))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: reading.component.title))
                .accessibilityValue(Text(verbatim: percent))
                .accessibilityIdentifier("RingABar.audio.airpods.battery.\(reading.component.rawValue)")
            }
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
    }
}
