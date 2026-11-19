import Foundation
import PowerUIBridge

struct NativeChargingSnapshot: Sendable {
    let charge: TRChargeState
    let systemCalibration: TRSystemCalibration
    let storedLimit: Int?

    static func read() -> Self {
        let charge = TRReadChargeState()
        let calibration = TRReadSystemCalibration()
        let needsStoredLimit = !charge.valid.boolValue || charge.mode == 3 || calibration == .active
        return Self(charge: charge, systemCalibration: calibration,
                    storedLimit: needsStoredLimit ? SystemChargeLimit.read() : nil)
    }

    var configuredLimit: Int? {
        guard charge.valid.boolValue, (80...100).contains(charge.limit) else { return storedLimit }
        if charge.limit == 100 && (charge.mode == 3 || systemCalibration == .active) {
            return storedLimit.flatMap { (80..<100).contains($0) ? $0 : nil }
        }
        return charge.limit
    }

    func hasManualOverride(for limit: Int) -> Bool {
        guard charge.valid.boolValue, charge.mode == 3 else { return false }
        if let configuredLimit { return configuredLimit == limit }
        return charge.limit == 100
    }

    func confirmsRestoredLimit(_ limit: Int) -> Bool {
        systemCalibration == .inactive && charge.valid.boolValue && charge.mode == 1 && charge.limit == limit
    }
}

struct BatteryCalibration {
    struct Session: Codable, Equatable {
        let originalLimit: Int?
    }

    enum Status: Equatable {
        case unavailable
        case inactive
        case active(Int?)
        case checking(Int)
        case restored(Int)
        case changed(original: Int, current: Int)
        case finished
    }

    private(set) var session: Session?
    private var signal: TRSystemCalibration = .unknown
    private var completion: Status?

    init(session: Session? = nil) {
        self.session = session
    }

    var blocksChargingChanges: Bool {
        signal == .active || (signal == .unknown && session != nil)
    }

    var status: Status {
        switch signal {
        case .active: return .active(session?.originalLimit)
        case .inactive:
            if let limit = session?.originalLimit { return .checking(limit) }
            return completion ?? .inactive
        default: return .unavailable
        }
    }

    mutating func update(with snapshot: NativeChargingSnapshot) {
        signal = snapshot.systemCalibration
        if signal == .active {
            if session?.originalLimit == nil {
                let original = snapshot.configuredLimit.flatMap { (80..<100).contains($0) ? $0 : nil }
                session = Session(originalLimit: original)
            }
            completion = nil
        } else if signal == .inactive {
            if let session {
                guard let limit = session.originalLimit else {
                    completion = .finished
                    self.session = nil
                    return
                }
                if snapshot.confirmsRestoredLimit(limit) {
                    completion = .restored(limit)
                } else if snapshot.charge.valid.boolValue, let current = snapshot.configuredLimit, current != limit {
                    completion = .changed(original: limit, current: current)
                } else {
                    return
                }
                self.session = nil
            } else if case let .restored(limit) = completion, let current = snapshot.configuredLimit, current != limit {
                completion = nil
            } else if case let .changed(_, limit) = completion, let current = snapshot.configuredLimit, current != limit {
                completion = nil
            }
        }
    }
}

struct ManualFullCharge: Codable, Equatable {
    let limit: Int
    let requestedAt: Date
    var confirmed = false

    func isWaiting(at date: Date) -> Bool {
        !confirmed && (0..<25).contains(date.timeIntervalSince(requestedAt))
    }

    func reconciled(with snapshot: NativeChargingSnapshot, at date: Date) -> Self? {
        // Calibration may temporarily take precedence over a manual request.
        guard snapshot.systemCalibration != .active, snapshot.charge.valid.boolValue else { return self }
        if let configuredLimit = snapshot.configuredLimit, configuredLimit != limit { return nil }
        if snapshot.hasManualOverride(for: limit), confirmed || isWaiting(at: date) {
            var verified = self
            verified.confirmed = true
            return verified
        }
        if snapshot.charge.mode == 3 && snapshot.configuredLimit == nil { return self }
        return isWaiting(at: date) ? self : nil
    }
}
