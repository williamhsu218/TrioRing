import Foundation

enum AirPodsListeningMode: UInt32, CaseIterable, Identifiable, Sendable {
    case off = 1
    case noiseCancellation = 2
    case transparency = 3
    case adaptive = 4

    var id: UInt32 { rawValue }

    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .noiseCancellation: String(localized: "Noise Cancellation")
        case .transparency: String(localized: "Transparency")
        case .adaptive: String(localized: "Adaptive")
        }
    }

    var supportBit: UInt32 {
        switch self {
        case .off: 0
        case .noiseCancellation: 1 << 0
        case .transparency: 1 << 1
        case .adaptive: 1 << 2
        }
    }
}

struct AirPodsOutput: Equatable, Sendable {
    let deviceID: UInt32
    let uid: String
    let currentMode: AirPodsListeningMode?
    let supportedModes: [AirPodsListeningMode]

    static func symbol(forModelUID uid: String?) -> String? {
        // Bluetooth CoreAudio model UIDs contain the product and vendor IDs in hex.
        guard let parts = uid?.split(whereSeparator: \.isWhitespace), parts.count == 2,
              UInt16(parts[1], radix: 16) == 0x004c,
              let product = UInt16(parts[0], radix: 16) else { return nil }

        switch product {
        case 0x2002, 0x200f: return "airpods"
        case 0x2013: return "airpods.gen3"
        case 0x2019, 0x201b, 0x2030, 0x2032, 0x2036, 0x2037: return "airpods.gen4"
        case 0x200e, 0x2014, 0x2024, 0x2027: return "airpodspro"
        case 0x200a, 0x201f, 0x202d: return "airpodsmax"
        default: return nil
        }
    }
}

struct AirPodsBattery: Equatable, Sendable {
    let main: Int?
    let left: Int?
    let right: Int?
    let chargingCase: Int?

    enum Component: String, Sendable {
        case left, right, chargingCase, main

        var title: String {
            switch self {
            case .left: String(localized: "Left")
            case .right: String(localized: "Right")
            case .chargingCase: String(localized: "Case")
            case .main: String(localized: "Battery")
            }
        }

        func symbol(deviceSymbol: String) -> String {
            let pro = deviceSymbol == "airpodspro"
            let newer = deviceSymbol == "airpods.gen3" || deviceSymbol == "airpods.gen4"
            switch self {
            case .left: return pro ? "airpodpro.left" : newer ? "airpod.gen3.left" : "airpod.left"
            case .right: return pro ? "airpodpro.right" : newer ? "airpod.gen3.right" : "airpod.right"
            case .chargingCase:
                switch deviceSymbol {
                case "airpodspro": return "airpodspro.chargingcase.wireless"
                case "airpods.gen3": return "airpods.gen3.chargingcase.wireless"
                case "airpods.gen4": return "airpods.gen4.chargingcase.wireless"
                default: return "airpods.chargingcase"
                }
            case .main: return deviceSymbol
            }
        }
    }

    struct Reading: Identifiable, Equatable, Sendable {
        let component: Component
        let percent: Int
        var id: Component { component }
    }

    /// Never invent a missing ear or duplicate the combined reading beside it.
    var readings: [Reading] {
        var result: [Reading] = []
        if let left { result.append(.init(component: .left, percent: left)) }
        if let right { result.append(.init(component: .right, percent: right)) }
        if left == nil && right == nil, let main {
            result.append(.init(component: .main, percent: main))
        }
        if let chargingCase { result.append(.init(component: .chargingCase, percent: chargingCase)) }
        return result
    }

    static func read(outputUID: String) -> Self? {
        let suffix = ":output"
        guard outputUID.hasSuffix(suffix),
              let expectedAddress = address(String(outputUID.dropLast(suffix.count))),
              let data = profilerReport() else { return nil }
        return parse(data, address: expectedAddress)
    }

    static func parse(_ data: Data, address expected: String) -> Self? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        let devices = controllers.flatMap { $0["device_connected"] as? [[String: [String: Any]]] ?? [] }
            .flatMap { $0.values }
        let matches = devices.filter {
            ($0["device_address"] as? String).flatMap(address) == expected
                && ($0["device_vendorID"] as? String)?.lowercased() == "0x004c"
        }
        guard matches.count == 1, let device = matches.first else { return nil }
        func level(_ key: String) -> Int? {
            let raw = (device[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = raw.flatMap { Int($0.hasSuffix("%") ? String($0.dropLast()) : $0) } ?? device[key] as? Int
            return value.flatMap { (0...100).contains($0) ? $0 : nil }
        }
        let battery = Self(main: level("device_batteryLevelMain"), left: level("device_batteryLevelLeft"),
                           right: level("device_batteryLevelRight"), chargingCase: level("device_batteryLevelCase"))
        return [battery.main, battery.left, battery.right, battery.chargingCase].contains { $0 != nil } ? battery : nil
    }

    private static func address(_ value: String) -> String? {
        let canonical = value.uppercased().filter { $0 != ":" && $0 != "-" }
        guard canonical.utf8.count == 12, canonical.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0)
        }) else { return nil }
        return canonical
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
        process.arguments = ["-timeout", "3", "-json", "SPBluetoothDataType"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return nil }
        if finished.wait(timeout: .now() + 4) == .timedOut {
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
