import AppKit
import Foundation
import Observation
import OSLog
import PowerUIBridge
import SwiftUI

enum PowerMode: Int, CaseIterable {
    case automatic, low, high

    var symbol: String {
        switch self {
        case .automatic: "gauge"
        case .low: "leaf.fill"
        case .high: "bolt.batteryblock.fill"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .automatic: "Automatic"
        case .low: "Low Power"
        case .high: "High Power"
        }
    }
}

struct PowerModeState: Equatable, Sendable {
    var current: PowerMode?
    var supportsLow: Bool
    var supportsHigh: Bool

    static func read() -> Self? {
        guard let live = run("/usr/bin/pmset", ["-g", "live"]),
              let cap = run("/usr/bin/pmset", ["-g", "cap"]) else { return nil }
        let keys = Set(cap.split(whereSeparator: \.isWhitespace))
        var values: [Substring: Int] = [:]
        for line in live.split(whereSeparator: \.isNewline) {
            let columns = line.split(whereSeparator: \.isWhitespace)
            if columns.count == 2, let value = Int(columns[1]) { values[columns[0]] = value }
        }
        let mode: PowerMode?
        if let unified = values["powermode"] { mode = PowerMode(rawValue: unified) }
        else if values["highpowermode"] == 1 { mode = .high }
        else if let low = values["lowpowermode"], (0...1).contains(low) { mode = low == 1 ? .low : .automatic }
        else { mode = nil }
        return Self(current: mode, supportsLow: keys.contains("lowpowermode") || keys.contains("powermode"),
                    supportsHigh: keys.contains("highpowermode"))
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

@MainActor @Observable
final class BatteryActions {
    let powerAuthorization = PowerModeAuthorization()
    private(set) var charge: TRChargeState?
    private(set) var modes: PowerModeState?
    private(set) var chargeBusy = false
    private(set) var modeBusy = false
    private(set) var chargeError: LocalizedStringKey?
    private(set) var modeError: LocalizedStringKey?
    private var requestedAt: Date?
    private var restoreLimit: Int?
    private var observedOverride = false
    private var chargeWriteRevision = 0
    private let defaults: UserDefaults
    private static let pauseKey = "battery.nativeChargePause"

    struct ChargePause: Codable, Equatable {
        let originalLimit: Int
        let pausedLimit: Int
    }

    private(set) var chargePause: ChargePause? {
        didSet { defaults.set(chargePause.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.pauseKey) }
    }

    private(set) var externalChargeManagerRunning = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        chargePause = defaults.data(forKey: Self.pauseKey)
            .flatMap { try? JSONDecoder().decode(ChargePause.self, from: $0) }
        externalChargeManagerRunning = Self.isExternalChargeManagerRunning
    }

    private static var isExternalChargeManagerRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apphousekitchen.aldente-pro").isEmpty
    }

    var availableChargeLimits: [Int] {
        guard let charge, charge.valid.boolValue else { return [] }
        return (80...100).filter { charge.allowedLimits & (1 << ($0 - 80)) != 0 }
    }

    var currentChargeLimit: Int? {
        guard let charge, charge.valid.boolValue, charge.mode != 3, (80...100).contains(charge.limit) else { return nil }
        return charge.limit
    }

    func limitForPause(_ reading: BatteryReading) -> Int? {
        guard reading.pluggedIn, reading.charging, let currentChargeLimit,
              availableChargeLimits.contains(currentChargeLimit) else { return nil }
        return availableChargeLimits.last { $0 <= reading.percent && $0 < currentChargeLimit }
    }

    func updateChargeLimit(_ limit: Int) {
        changeChargeLimit(limit, pause: nil)
    }

    func pauseCharging(_ reading: BatteryReading) {
        guard let target = limitForPause(reading), let original = currentChargeLimit else { return }
        changeChargeLimit(target, pause: ChargePause(originalLimit: original, pausedLimit: target))
    }

    func restorePausedChargeLimit() {
        guard let pause = chargePause, currentChargeLimit == pause.pausedLimit else { return }
        changeChargeLimit(pause.originalLimit, pause: nil)
    }

    private func changeChargeLimit(_ limit: Int, pause: ChargePause?) {
        guard !chargeBusy, let current = currentChargeLimit, limit != current,
              availableChargeLimits.contains(limit), canWriteChargingSettings() else { return }
        chargeError = nil
        chargeBusy = true
        chargeWriteRevision += 1
        let previousPause = chargePause
        if let pause { chargePause = pause }
        log.notice("Charge limit change: \(current) to \(limit), temporary pause=\(pause != nil)")

        Task {
            let accepted = await Task.detached(priority: .userInitiated) {
                if pause != nil {
                    guard let reading = BatteryMonitor.read().reading, reading.pluggedIn,
                          reading.charging, reading.percent >= limit else { return false }
                }
                return TRSetChargeLimit(limit, current)
            }.value
            var latest = await Task.detached(priority: .utility) { TRReadChargeState() }.value
            var verified = latest.valid.boolValue && latest.mode != 3 && latest.limit == limit
            if accepted && !verified {
                for _ in 0..<6 {
                    try? await Task.sleep(for: .milliseconds(450))
                    latest = await Task.detached(priority: .utility) { TRReadChargeState() }.value
                    verified = latest.valid.boolValue && latest.mode != 3 && latest.limit == limit
                    if verified { break }
                }
            }
            if verified { chargePause = pause }
            else if !accepted || (latest.valid.boolValue && latest.mode != 3 && latest.limit == current) {
                chargePause = previousPause
            }
            chargeBusy = false
            apply(latest)
            if !verified {
                chargeError = accepted
                    ? "macOS did not confirm the new charge limit."
                    : "The charge limit could not be changed. Check the current limit and try again."
            }
        }
    }

    private func canWriteChargingSettings() -> Bool {
        externalChargeManagerRunning = Self.isExternalChargeManagerRunning
        if externalChargeManagerRunning {
            chargeError = "Quit AlDente before changing charging settings in TrioRing."
        }
        return !externalChargeManagerRunning
    }
    private let log = Logger(subsystem: "com.willhsu.ring-a-bar", category: "BatteryActions")

    var temporarilyOverriddenLimit: Int? { charge?.mode == 3 ? restoreLimit : nil }

    enum Offer: Equatable { case unavailable, none, charge(Int?), waiting, cancel(Int), systemOverride }

    func offer(for reading: BatteryReading?) -> Offer {
        guard let reading, reading.pluggedIn, reading.percent < 100 else { return .none }
        guard let charge else { return .none }
        guard charge.valid.boolValue else { return .unavailable }
        if chargePause != nil { return .none }
        if charge.mode == 3 {
            if let restoreLimit { return .cancel(restoreLimit) }
            return .systemOverride
        }
        if let requestedAt, Date().timeIntervalSince(requestedAt) < 25, !reading.charging { return .waiting }
        if charge.mode == 1, (80..<100).contains(charge.limit) { return .charge(charge.limit) }
        if charge.canResume.boolValue && !reading.charging { return .charge(nil) }
        return .none
    }

    func refresh() async {
        let revision = chargeWriteRevision
        let startedWhileWriting = chargeBusy
        let (charge, modes) = await Task.detached(priority: .utility) {
            (TRReadChargeState(), PowerModeState.read())
        }.value
        guard !Task.isCancelled else { return }
        externalChargeManagerRunning = Self.isExternalChargeManagerRunning
        if !startedWhileWriting && revision == chargeWriteRevision { apply(charge) }
        if !modeBusy { self.modes = modes }
        if modes?.supportsLow == true || modes?.supportsHigh == true {
            await powerAuthorization.refresh()
        }
    }

    private func apply(_ state: TRChargeState) {
        guard !chargeBusy else { return }
        charge = state
        if state.valid.boolValue {
            if let chargePause, state.mode != 3, (80...100).contains(state.limit),
               state.limit != chargePause.pausedLimit { self.chargePause = nil }
            if state.mode == 3 { observedOverride = true }
            else if observedOverride || (requestedAt.map { Date().timeIntervalSince($0) > 25 } ?? false) {
                restoreLimit = nil
                observedOverride = false
                requestedAt = nil
            }
        }
    }

    func runCharge(for reading: BatteryReading?) {
        guard !chargeBusy else { return }
        let action = offer(for: reading)
        let limit: Int
        let restore: Bool
        switch action {
        case let .charge(expected): limit = expected ?? 0; restore = false
        case let .cancel(expected): limit = expected; restore = true
        default: return
        }
        guard canWriteChargingSettings() else { return }
        chargeError = nil
        chargeBusy = true
        chargeWriteRevision += 1
        log.notice("Charging action selected: restore=\(restore)")
        Task {
            let accepted = await Task.detached(priority: .userInitiated) {
                guard let live = BatteryMonitor.read().reading, live.pluggedIn, live.percent < 100 else { return false }
                return restore ? TRRestoreChargeLimit(limit) : TRRequestFullCharge(limit, !live.charging)
            }.value
            log.notice("Charging request accepted: \(accepted)")
            if accepted && !restore {
                restoreLimit = limit > 0 ? limit : nil
                requestedAt = Date()
                observedOverride = false
            }
            var verified = false
            for attempt in 0..<(accepted ? 20 : 1) {
                if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
                let (latest, live) = await Task.detached(priority: .utility) {
                    (TRReadChargeState(), BatteryMonitor.read().reading)
                }.value
                charge = latest
                if accepted {
                    if restore { verified = latest.valid.boolValue && latest.mode != 3 && latest.limit == limit }
                    else if limit > 0 { verified = latest.valid.boolValue && latest.mode == 3 }
                    else { verified = live?.charging == true }
                    if verified {
                        if !restore && latest.valid.boolValue && latest.mode == 3 { observedOverride = true }
                        break
                    }
                }
            }
            chargeBusy = false
            log.notice("Charging state confirmed: \(verified)")
            if restore && verified { restoreLimit = nil; requestedAt = nil; observedOverride = false }
            if !accepted { chargeError = "macOS did not accept the charging request." }
            else if !verified { chargeError = "macOS accepted the request; the new charging state is not confirmed yet." }
        }
    }

    func setMode(_ mode: PowerMode, pluggedIn: Bool) {
        guard powerAuthorization.state == .ready, !modeBusy, let modes, modes.current != nil, modes.current != mode,
              mode != .high || modes.supportsHigh, mode != .low || modes.supportsLow else { return }
        modeError = nil
        modeBusy = true
        Task {
            let accepted = await powerAuthorization.changeMode(mode.rawValue, onAC: pluggedIn)
            let latest = await Task.detached(priority: .utility) { PowerModeState.read() }.value
            self.modes = latest
            modeBusy = false
            if !accepted { modeError = "Power mode could not be changed. Check Power Mode Access in Battery settings." }
            else if latest?.current != mode { modeError = "The active power profile has not confirmed this mode." }
        }
    }
}
