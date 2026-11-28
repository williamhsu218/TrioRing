import Darwin
import Foundation
import IOKit
import IOKit.ps
import os

// Adapted from the power sample in Status Trio v1.9.5 (Apache-2.0).
struct BatteryPowerSample: Equatable, Sendable {
    let volts: Double
    let amps: Double
    let updatedAt: Date
    var watts: Double { volts * amps }
}

struct BatteryPowerSnapshot: Sendable {
    let inputWatts: Double?
    let battery: BatteryPowerSample?
    let systemWatts: Double?
    let temperatureCelsius: Double?
    let displayWatts: Double?
    let usbPorts: [USBPortOutput]
    let inputPortType: String?
    let breakdown: BatteryPowerBreakdown?

    var volts: Double? { battery?.volts }
    var amps: Double? { battery?.amps }

    static func read(pluggedIn: Bool, previous: BatteryPowerBreakdown?) -> Self {
        let started = Date()
        let sensors = SystemPowerReader().readSensors(system: true, input: pluggedIn, battery: true,
                                                       breakdown: true, temperature: true)
        let registry = batteryProperties()
        let registryInput = (registry["PowerTelemetryData"] as? [String: Any])?["SystemPowerIn"] as? NSNumber
        let fallbackInput = registryInput.flatMap {
            (0...500_000).contains($0.doubleValue) ? $0.doubleValue / 1000 : nil
        }
        let input = pluggedIn ? sensors.input?.watts ?? fallbackInput : nil
        let battery = sensors.battery ?? registryBattery(registry, started: started)
        let topology = USBPortTopologyReader.read()
        let now = Date()
        let usb = USBOutputReader.resolve(portRails: sensors.portRails, registry: registry,
                                          topology: topology, now: started)
        let resolved = BatteryPowerBreakdown.resolve(
            adapterInput: input.map { SystemPowerSample(watts: $0, readAt: started) },
            charging: battery.map { max(0, $0.watts) }, discharge: battery.map { max(0, -$0.watts) },
            display: sensors.display, usb: usb, inputPortType: pluggedIn ? topology.inputPortType : nil, now: now)
        // The rails update on separate clocks. Keep the last coherent graph for
        // one refresh only, and only while its USB topology has not changed.
        let previousStillMatches = previous.map { snapshot in
            now.timeIntervalSince(snapshot.readAt) <= 15
                && snapshot.usbPorts.map(\.channel) == (usb?.ports.map(\.channel) ?? [])
                && snapshot.usbPorts.map(\.deviceNames) == (usb?.ports.map(\.deviceNames) ?? [])
                && snapshot.inputPortType == (pluggedIn ? topology.inputPortType : nil)
        } ?? false
        let breakdown = resolved ?? (previousStillMatches ? previous : nil)
        return Self(inputWatts: input, battery: battery, systemWatts: sensors.system?.watts,
                    temperatureCelsius: sensors.batteryTemperatureCelsius,
                    displayWatts: breakdown?.display?.watts ?? sensors.display?.watts,
                    usbPorts: breakdown?.usbPorts ?? usb?.ports ?? [],
                    inputPortType: pluggedIn ? topology.inputPortType : nil, breakdown: breakdown)
    }

    private static func batteryProperties() -> [String: Any] {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard entry != IO_OBJECT_NULL else { return [:] }
        defer { IOObjectRelease(entry) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return [:] }
        return properties?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    private static func registryBattery(_ registry: [String: Any], started: Date) -> BatteryPowerSample? {
        guard let voltage = (registry["Voltage"] as? NSNumber)?.doubleValue, (1_000...50_000).contains(voltage),
              let current = (registry["InstantAmperage"] as? NSNumber)?.int64Value,
              (-50_000...50_000).contains(current) else { return nil }
        return BatteryPowerSample(volts: voltage / 1000, amps: Double(current) / 1000, updatedAt: started)
    }
}

enum SystemChargeLimit {
    private struct FileFingerprint: Equatable {
        let mtimeSec: Int
        let mtimeNsec: Int
        let size: off_t
    }

    private struct CachedLimit {
        let fingerprint: FileFingerprint
        let limit: Int?
    }

    private static let path = "/Library/Preferences/com.apple.powerd.charging.plist"
    private static let cache = OSAllocatedUnfairLock<CachedLimit?>(initialState: nil)

    static func read() -> Int? {
        var info = stat()
        let fingerprint: FileFingerprint? = stat(path, &info) == 0
            ? FileFingerprint(mtimeSec: info.st_mtimespec.tv_sec, mtimeNsec: info.st_mtimespec.tv_nsec, size: info.st_size)
            : nil
        if let fingerprint, let cached = cache.withLock({ $0 }), cached.fingerprint == fingerprint {
            return cached.limit
        }
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            cache.withLock { $0 = nil }
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16_385), data.count <= 16_384 else { return nil }
        let limit = parse(data)
        if let fingerprint {
            cache.withLock { $0 = CachedLimit(fingerprint: fingerprint, limit: limit) }
        }
        return limit
    }

    static func parse(_ data: Data) -> Int? {
        // The powerd archive layout is private. Read its scalar values as a
        // property list without instantiating any of the archived classes.
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let policies = plist["policies"] as? Data,
              let archive = (try? PropertyListSerialization.propertyList(from: policies, format: nil)) as? [String: Any],
              archive["$archiver"] as? String == "NSKeyedArchiver",
              let objects = archive["$objects"] as? [Any] else { return nil }
        let entries = objects.compactMap { $0 as? [String: Any] }
        guard entries.contains(where: { $0["$classname"] as? String == "ChargeCtrlPolicy" }) else { return nil }
        let limits = entries.filter { $0["soclimit"] != nil }
        guard limits.count == 1, let limit = limits.first?["soclimit"] as? Int,
              (80...100).contains(limit) else { return nil }
        return limit
    }
}

struct BatteryDetails: Sendable {
    var maximumCapacity: Int?
    var cycleCount: Int?
    var condition: Condition?
    var adapterWatts: Int?
    var uptime: Double?

    enum Condition: Sendable {
        case normal, serviceRecommended
    }

    private struct CachedHealth: Sendable {
        let maximumCapacity: Int?
        let cycleCount: Int?
        let condition: Condition?
        let readAt: Date
    }

    private static let healthTTL: TimeInterval = 600
    private static let healthCache = OSAllocatedUnfairLock<CachedHealth?>(initialState: nil)

    static func read() -> Self {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        let uptime: Double? = sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 && boot.tv_sec > 0
            ? max(0, Date.now.timeIntervalSince1970 - Double(boot.tv_sec))
            : nil
        let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
        let watts = (adapter?[kIOPSPowerAdapterWattsKey] as? Int).flatMap { $0 > 0 ? $0 : nil }

        let now = Date()
        if let cached = healthCache.withLock({ $0 }),
           (0..<healthTTL).contains(now.timeIntervalSince(cached.readAt)) {
            return Self(maximumCapacity: cached.maximumCapacity, cycleCount: cached.cycleCount,
                        condition: cached.condition, adapterWatts: watts, uptime: uptime)
        }

        guard let data = profilerReport(),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]],
              let item = items.first(where: { $0["_name"] as? String == "spbattery_information" }),
              let health = item["sppower_battery_health_info"] as? [String: Any] else {
            return Self(adapterWatts: watts, uptime: uptime)
        }
        let capacity = (health["sppower_battery_health_maximum_capacity"] as? String)
            .flatMap { Int($0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "%")))) }
            .flatMap { (1...100).contains($0) ? $0 : nil }
        let cycles = (health["sppower_battery_cycle_count"] as? Int).flatMap { $0 >= 0 ? $0 : nil }
        let condition: Condition? = switch health["sppower_battery_health"] as? String {
        case "Good", "Normal": .normal
        case "Service Recommended", "Check Battery", "Replace Soon", "Replace Now": .serviceRecommended
        default: nil
        }
        if capacity != nil || cycles != nil || condition != nil {
            healthCache.withLock {
                $0 = CachedHealth(maximumCapacity: capacity, cycleCount: cycles, condition: condition, readAt: now)
            }
        }
        return Self(maximumCapacity: capacity, cycleCount: cycles, condition: condition,
                    adapterWatts: watts, uptime: uptime)
    }

    private static func profilerReport() -> Data? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let output = try? FileHandle(forUpdating: url) else { return nil }
        defer { try? output.close() }

        let finished = DispatchSemaphore(value: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-timeout", "3", "SPPowerDataType", "-json"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return nil }
        if finished.wait(timeout: .now() + .seconds(4)) == .timedOut {
            if process.isRunning { process.terminate() }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        do {
            try output.seek(toOffset: 0)
            let limit = 256 * 1024
            guard let data = try output.read(upToCount: limit + 1), data.count <= limit else { return nil }
            return data
        } catch {
            return nil
        }
    }
}
