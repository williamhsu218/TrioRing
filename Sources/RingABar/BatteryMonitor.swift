import Foundation
import IOKit.ps

@MainActor
final class BatteryMonitor {
    private var source: CFRunLoopSource?
    private let onChange: (BatteryStatus) -> Void

    init(onChange: @escaping (BatteryStatus) -> Void) {
        self.onChange = onChange
    }

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            // This source is scheduled exclusively on the main run loop.
            MainActor.assumeIsolated {
                Unmanaged<BatteryMonitor>.fromOpaque(context).takeUnretainedValue().refresh()
            }
        }, context)?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        refresh()
    }

    func stop() {
        if let source {
            CFRunLoopSourceInvalidate(source)
        }
        source = nil
    }

    func refresh() {
        onChange(Self.read())
    }

    nonisolated static func read() -> BatteryStatus {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return .unavailable
        }

        for source in sources {
            guard let values = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                return .unavailable
            }
            guard values[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  values[kIOPSIsPresentKey] as? Bool != false else { continue }
            guard let current = values[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = values[kIOPSMaxCapacityKey] as? Int, maximum > 0 else {
                return .unavailable
            }
            let percent = Int((100 * Double(min(max(current, 0), maximum)) / Double(maximum)).rounded())
            let pluggedIn = values[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = values[kIOPSIsChargingKey] as? Bool == true
            let minutesKey = charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            let minutes = (values[minutesKey] as? Int).flatMap { (1...4320).contains($0) ? $0 : nil }
            return .battery(BatteryReading(
                percent: percent,
                pluggedIn: pluggedIn,
                charging: charging,
                lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                chargeLimit: SystemChargeLimit.read(),
                minutesRemaining: !pluggedIn || charging ? minutes : nil
            ))
        }
        return .noBattery
    }
}
