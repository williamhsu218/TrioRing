import Foundation
import PowerUIBridge
import Testing
@testable import RingABar

@MainActor
struct BatteryChargingStateTests {
    private func snapshot(
        _ signal: TRSystemCalibration = .inactive, mode: UInt = 1, limit: Int = 85, valid: Bool = true,
        storedLimit: Int? = nil
    ) -> NativeChargingSnapshot {
        .init(charge: TRChargeState(valid: ObjCBool(valid), mode: mode, limit: limit, canResume: false, allowedLimits: 0),
              systemCalibration: signal, storedLimit: storedLimit)
    }

    private func isolatedDefaults(_ run: (UserDefaults) throws -> Void) throws {
        let suite = "TrioRingTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try run(defaults)
    }

    @Test func confirmsLimitOnlyAfterCalibrationEndsAndNativeLimitIsEnabled() throws {
        try isolatedDefaults { defaults in
            let reading = BatteryReading(percent: 100, pluggedIn: true, chargeLimit: 85)
            let running = BatteryActions(defaults: defaults)
            running.apply(snapshot(.active, limit: 100, storedLimit: 85))
            #expect(running.calibration.status == .active(85))
            #expect(running.currentChargeLimit == 85)
            #expect(running.chargingControlsDisabled)
            #expect(running.offer(for: reading) == .none)

            let reopened = BatteryActions(defaults: defaults)
            reopened.apply(snapshot(.unknown))
            #expect(reopened.calibration.status == .unavailable)
            #expect(reopened.chargingControlsDisabled)
            reopened.apply(snapshot(mode: 3))
            #expect(reopened.calibration.status == .checking(85))
            reopened.apply(snapshot(valid: false, storedLimit: 85))
            #expect(reopened.calibration.status == .checking(85))
            reopened.apply(snapshot())
            #expect(reopened.calibration.status == .restored(85))
            #expect(reopened.calibration.session == nil)
        }
    }

    @Test func changedLimitIsReportedFromReadback() {
        var calibration = BatteryCalibration()
        calibration.update(with: snapshot(.active))
        calibration.update(with: snapshot(.active, limit: 90))
        #expect(calibration.status == .active(85))
        calibration.update(with: snapshot(limit: 90))
        #expect(calibration.status == .changed(original: 85, current: 90))
        calibration.update(with: snapshot(limit: 95))
        #expect(calibration.status == .inactive)
    }

    @Test func missingOriginalLimitCannotBeInferredFromTheEndingState() {
        var calibration = BatteryCalibration()
        calibration.update(with: snapshot(.active, valid: false))
        calibration.update(with: snapshot())
        #expect(calibration.status == .finished)
    }

    @Test func savedManualOverrideCanBeCancelledAtFullChargeAfterRelaunch() throws {
        try isolatedDefaults { defaults in
            let record = ManualFullCharge(limit: 85, requestedAt: .now.addingTimeInterval(-3600), confirmed: true)
            defaults.set(try JSONEncoder().encode(record), forKey: "battery.manualFullCharge")
            let reopened = BatteryActions(defaults: defaults)
            let full = BatteryReading(percent: 100, pluggedIn: true, chargeLimit: 85)

            reopened.apply(snapshot(mode: 3))
            #expect(reopened.offer(for: full) == .cancel(85))
            reopened.apply(snapshot(.active, mode: 3))
            #expect(reopened.offer(for: full) == .none)
            reopened.apply(snapshot(mode: 3, limit: 100, storedLimit: 100))
            #expect(reopened.offer(for: full) == .cancel(85))
            reopened.apply(snapshot())
            #expect(reopened.offer(for: full) == .none)
            #expect(defaults.data(forKey: "battery.manualFullCharge") == nil)
        }
    }

    @Test func anUnownedOrMismatchedOverrideOffersNoCancellation() throws {
        try isolatedDefaults { defaults in
            let reading = BatteryReading(percent: 90, pluggedIn: true, chargeLimit: 85)
            let running = BatteryActions(defaults: defaults)
            running.apply(snapshot(mode: 3))
            #expect(running.offer(for: reading) == .systemOverride)

            let record = ManualFullCharge(limit: 85, requestedAt: .now, confirmed: true)
            defaults.set(try JSONEncoder().encode(record), forKey: "battery.manualFullCharge")
            let reopened = BatteryActions(defaults: defaults)
            reopened.apply(snapshot(mode: 3, limit: 90))
            #expect(reopened.offer(for: reading) == .systemOverride)
            #expect(defaults.data(forKey: "battery.manualFullCharge") == nil)
        }
    }

    @Test func pendingManualRequestIsConfirmedOnlyByAMatchingLiveOverride() {
        let now = Date.now
        let record = ManualFullCharge(limit: 85, requestedAt: now)
        #expect(record.reconciled(with: snapshot(), at: now) == record)
        #expect(record.reconciled(with: snapshot(mode: 3), at: now)?.confirmed == true)
        #expect(record.reconciled(with: snapshot(mode: 3, limit: 100), at: now)?.confirmed == true)
        #expect(record.reconciled(with: snapshot(mode: 3), at: now.addingTimeInterval(60)) == nil)
    }
}
