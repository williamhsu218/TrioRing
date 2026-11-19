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
    private var chargingSnapshot: NativeChargingSnapshot?
    private var charge: TRChargeState? { chargingSnapshot?.charge }
    private(set) var modes: PowerModeState?
    private(set) var chargeBusy = false
    private(set) var modeBusy = false
    private(set) var chargeError: LocalizedStringKey?
    private(set) var modeError: LocalizedStringKey?
    private var optimizedChargeRequestedAt: Date?
    private var chargeWriteRevision = 0
    private var chargeReadRevision = 0
    private var appliedChargeReadRevision = 0
    @ObservationIgnored private var calibrationObservationToken: Int32 = -1
    private let defaults: UserDefaults
    private static let pauseKey = "battery.nativeChargePause"
    private static let calibrationKey = "battery.systemCalibration"
    private static let manualFullChargeKey = "battery.manualFullCharge"

    private(set) var calibration: BatteryCalibration {
        didSet {
            guard calibration.session != oldValue.session else { return }
            defaults.set(calibration.session.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.calibrationKey)
        }
    }

    private var manualFullCharge: ManualFullCharge? {
        didSet {
            guard manualFullCharge != oldValue else { return }
            defaults.set(manualFullCharge.flatMap { try? JSONEncoder().encode($0) }, forKey: Self.manualFullChargeKey)
        }
    }

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
        let session = defaults.data(forKey: Self.calibrationKey)
            .flatMap { try? JSONDecoder().decode(BatteryCalibration.Session.self, from: $0) }
        calibration = BatteryCalibration(session: session)
        manualFullCharge = defaults.data(forKey: Self.manualFullChargeKey)
            .flatMap { try? JSONDecoder().decode(ManualFullCharge.self, from: $0) }
            .flatMap { (80..<100).contains($0.limit) ? $0 : nil }
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
        guard let snapshot = chargingSnapshot, snapshot.charge.valid.boolValue, snapshot.charge.mode != 3 else { return nil }
        return snapshot.configuredLimit
    }

    var showsCalibrationStatus: Bool {
        charge?.valid.boolValue == true || calibration.session != nil ||
            (calibration.status != .inactive && calibration.status != .unavailable)
    }

    var chargingControlsDisabled: Bool {
        chargeBusy || externalChargeManagerRunning || calibration.blocksChargingChanges
    }

    func limitForPause(_ reading: BatteryReading) -> Int? {
        guard !calibration.blocksChargingChanges, reading.pluggedIn, reading.charging, let currentChargeLimit,
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
            var snapshot = await Task.detached(priority: .utility) { NativeChargingSnapshot.read() }.value
            var latest = snapshot.charge
            var verified = latest.valid.boolValue && latest.mode != 3 && latest.limit == limit
            if accepted && !verified {
                for _ in 0..<6 {
                    try? await Task.sleep(for: .milliseconds(450))
                    snapshot = await Task.detached(priority: .utility) { NativeChargingSnapshot.read() }.value
                    latest = snapshot.charge
                    verified = latest.valid.boolValue && latest.mode != 3 && latest.limit == limit
                    if verified { break }
                }
            }
            if verified { chargePause = pause }
            else if !accepted || (latest.valid.boolValue && latest.mode != 3 && latest.limit == current) {
                chargePause = previousPause
            }
            chargeBusy = false
            apply(snapshot)
            if !verified {
                chargeError = accepted
                    ? "macOS did not confirm the new charge limit."
                    : "The charge limit could not be changed. Check the current limit and try again."
            }
        }
    }

    private func canWriteChargingSettings() -> Bool {
        guard !calibration.blocksChargingChanges else {
            chargeError = "Charging controls are paused during macOS battery calibration."
            return false
        }
        externalChargeManagerRunning = Self.isExternalChargeManagerRunning
        if externalChargeManagerRunning {
            chargeError = "Quit AlDente before changing charging settings in TrioRing."
        }
        return !externalChargeManagerRunning
    }
    private let log = Logger(subsystem: "com.willhsu.ring-a-bar", category: "BatteryActions")

    var temporarilyOverriddenLimit: Int? {
        guard let request = manualFullCharge, request.confirmed,
              chargingSnapshot?.hasManualOverride(for: request.limit) == true else { return nil }
        return request.limit
    }

    enum Offer: Equatable { case unavailable, none, charge(Int?), waiting, cancel(Int), systemOverride }

    func offer(for reading: BatteryReading?) -> Offer {
        guard !calibration.blocksChargingChanges, chargePause == nil, let charge else { return .none }
        if let limit = temporarilyOverriddenLimit { return .cancel(limit) }
        guard let reading, reading.pluggedIn, reading.percent < 100 else { return .none }
        guard charge.valid.boolValue else { return .unavailable }
        if charge.mode == 3 { return .systemOverride }
        if manualFullCharge?.isWaiting(at: .now) == true ||
            (optimizedChargeRequestedAt.map { Date.now.timeIntervalSince($0) < 25 } == true && !reading.charging) {
            return .waiting
        }
        if charge.mode == 1, (80..<100).contains(charge.limit) { return .charge(charge.limit) }
        if charge.canResume.boolValue && !reading.charging { return .charge(nil) }
        return .none
    }

    func startCalibrationObservation() {
        guard calibrationObservationToken < 0 else { return }
        calibrationObservationToken = TRObserveSystemCalibration { [weak self] in
            MainActor.assumeIsolated { self?.refreshChargingInBackground(force: true) }
        }
        refreshChargingInBackground(force: true)
    }

    func stopCalibrationObservation() {
        TRStopObservingSystemCalibration(calibrationObservationToken)
        calibrationObservationToken = -1
    }

    func refreshChargingInBackground(force: Bool = false) {
        guard force || calibration.session != nil || manualFullCharge != nil ||
                TRReadSystemCalibration() == .active else { return }
        Task { await refreshCharging() }
    }

    private func refreshCharging() async {
        guard !chargeBusy else { return }
        let revision = chargeWriteRevision
        chargeReadRevision += 1
        let readRevision = chargeReadRevision
        let snapshot = await Task.detached(priority: .utility) { NativeChargingSnapshot.read() }.value
        guard !Task.isCancelled, revision == chargeWriteRevision, readRevision > appliedChargeReadRevision else { return }
        appliedChargeReadRevision = readRevision
        apply(snapshot)
    }

    func refresh() async {
        async let charging: Void = refreshCharging()
        let modes = await Task.detached(priority: .utility) { PowerModeState.read() }.value
        await charging
        guard !Task.isCancelled else { return }
        externalChargeManagerRunning = Self.isExternalChargeManagerRunning
        if !modeBusy { self.modes = modes }
        if modes?.supportsLow == true || modes?.supportsHigh == true {
            await powerAuthorization.refresh()
        }
    }

    func apply(_ snapshot: NativeChargingSnapshot) {
        guard !chargeBusy else { return }
        chargingSnapshot = snapshot
        calibration.update(with: snapshot)
        guard !calibration.blocksChargingChanges else { return }
        manualFullCharge = manualFullCharge?.reconciled(with: snapshot, at: .now)
        let state = snapshot.charge
        if let chargePause, state.valid.boolValue, state.mode != 3, (80...100).contains(state.limit),
           state.limit != chargePause.pausedLimit {
            self.chargePause = nil
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
        // Save ownership before sending the native request so a relaunch can
        // reconcile it with the live override, even if the callback was lost.
        if !restore && limit > 0 { manualFullCharge = ManualFullCharge(limit: limit, requestedAt: .now) }
        log.notice("Charging action selected: restore=\(restore)")
        Task {
            let accepted = await Task.detached(priority: .userInitiated) {
                if restore {
                    guard NativeChargingSnapshot.read().hasManualOverride(for: limit) else { return false }
                    return TRRestoreChargeLimit(limit)
                }
                guard let live = BatteryMonitor.read().reading, live.pluggedIn, live.percent < 100 else { return false }
                return TRRequestFullCharge(limit, !live.charging)
            }.value
            log.notice("Charging request accepted: \(accepted)")
            if !restore {
                if !accepted && limit > 0 { manualFullCharge = nil }
                if accepted && limit == 0 { optimizedChargeRequestedAt = .now }
            }
            var snapshot: NativeChargingSnapshot?
            var verified = false
            for attempt in 0..<(accepted ? 20 : 1) {
                if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
                let (latest, live) = await Task.detached(priority: .utility) {
                    (NativeChargingSnapshot.read(), limit == 0 ? BatteryMonitor.read().reading : nil)
                }.value
                snapshot = latest
                if accepted {
                    if restore { verified = latest.confirmsRestoredLimit(limit) }
                    else if limit > 0 { verified = latest.systemCalibration != .active && latest.hasManualOverride(for: limit) }
                    else { verified = live?.charging == true }
                    if verified { break }
                }
            }
            chargeBusy = false
            log.notice("Charging state confirmed: \(verified)")
            if restore && verified { manualFullCharge = nil }
            if let snapshot { apply(snapshot) }
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
