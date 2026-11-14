import CoreWLAN
import Foundation
import Testing
@testable import RingABar

@MainActor
struct WiFiConnectionTests {
    private let secured = NearbyWiFi.Row(name: "Fixture Wi-Fi", signal: -50, security: .wpa2Personal)
    private let open = NearbyWiFi.Row(name: "Fixture Guest", signal: -65, security: .open)

    @Test func networkIdentityIncludesRawSSIDAndExactSecurityButNotSignal() {
        let a = NearbyWiFi.Row(name: "Same name", signal: -40, security: .wpa2Personal)
        let b = NearbyWiFi.Row(name: "Same name", signal: -80, security: .wpa2Personal)
        let unsecured = NearbyWiFi.Row(name: "Same name", signal: -30, security: .open)
        let changedSecurity = NearbyWiFi.Row(name: "Same name", signal: -30, security: .wpaPersonal)
        let differentBytes = NearbyWiFi.Row(name: "Same name", signal: -40, security: .wpa2Personal, ssidData: Data([0xFF, 0xFE]))
        #expect(a.id == b.id)
        #expect(a.id != unsecured.id)
        #expect(a.id != changedSecurity.id)
        #expect(a.id != differentBytes.id)
    }

    @Test func securityPolicyDoesNotTreatEnterpriseOrUnknownAsOpen() {
        #expect(WiFiSecurity.open.supportsDirectJoin)
        #expect(!WiFiSecurity.open.requiresPassword)
        #expect(WiFiSecurity.owe.supportsDirectJoin)
        #expect(!WiFiSecurity.owe.requiresPassword)
        #expect(WiFiSecurity.wpa3Personal.requiresPassword)
        #expect(WiFiSecurity.wpa3Transition.requiresPassword)
        #expect(WiFiSecurity.wep.requiresPassword)
        for security: WiFiSecurity in [.enterprise, .wpaEnterprise, .wpa2Enterprise, .wpa3Enterprise, .dynamicWEP, .unknown] {
            #expect(!security.supportsDirectJoin)
        }
        #expect(WiFiSecurity.wpa3Transition.native == .wpa3Transition)
        #expect(WiFiSecurity.wpa2Personal.native == .wpa2Personal)
        #expect(WiFiSecurity.oweTransition.native == .oweTransition)
    }

    @Test func constructingControllerIsInertAndCurrentNetworkIsANoOp() async {
        let joiner = RecordingWiFiJoiner()
        let controller = WiFiConnectionController(joiner: joiner)
        #expect(controller.phase == .idle)
        await controller.join(secured, currentSSID: secured.ssidData)
        #expect(await joiner.calls.isEmpty)
        #expect(controller.phase == .idle)
    }

    @Test func openAndSavedNetworksJoinWithoutAnUnnecessaryPasswordPrompt() async {
        for network in [open, secured] {
            let joiner = RecordingWiFiJoiner()
            let controller = WiFiConnectionController(joiner: joiner)
            await controller.join(network)
            #expect(controller.phase == .connected(network))
            let calls = await joiner.calls
            #expect(calls.count == 1)
            #expect(calls.first?.network == network)
            #expect(calls.first?.password == nil, "Nil asks the driver to use Keychain for a secured network")
        }
    }

    @Test func missingAndIncorrectPasswordsCanRetryWithoutTrimmingOrPersistingDrafts() async {
        let joiner = RecordingWiFiJoiner(outcomes: [.failure(.passwordRequired), .failure(.authentication), .success])
        let controller = WiFiConnectionController(joiner: joiner)
        await controller.join(secured)
        #expect(controller.phase == .passwordRequired(secured, nil))
        await controller.submit(password: "")
        #expect(await joiner.calls.count == 1)
        await controller.submit(password: "incorrect fixture")
        #expect(controller.phase == .passwordRequired(secured, .authentication))
        let fixture = "  fixture with spaces 密码  "
        await controller.submit(password: fixture)
        #expect(controller.phase == .connected(secured))
        #expect(await joiner.calls.last?.password == fixture)
        #expect(!String(describing: controller.phase).contains(fixture))
    }

    @Test func dismissingPasswordRequestDoesNotAssociateAndNextSelectionIsIndependent() async {
        let joiner = RecordingWiFiJoiner(outcomes: [.failure(.passwordRequired), .success])
        let controller = WiFiConnectionController(joiner: joiner)
        await controller.join(secured)
        controller.dismissPrompt()
        #expect(controller.phase == .idle)
        await controller.submit(password: "stale fixture")
        #expect(await joiner.calls.count == 1)
        await controller.join(open)
        #expect(controller.phase == .connected(open))
    }

    @Test func enterpriseAndUnknownRequireExplicitSystemSetupWithoutCallingDriver() async {
        for security: WiFiSecurity in [.wpa2Enterprise, .wpa3Enterprise, .dynamicWEP, .unknown] {
            let network = NearbyWiFi.Row(name: "Managed Fixture", signal: -50, security: security)
            let joiner = RecordingWiFiJoiner()
            let controller = WiFiConnectionController(joiner: joiner)
            await controller.join(network)
            #expect(controller.phase == .failed(network, .unsupported))
            #expect(await joiner.calls.isEmpty)
        }
    }

    @Test(arguments: [WiFiJoinError.poweredOff, .unavailable, .permission, .timedOut, .unconfirmed, .notFound, .system(-3911)])
    func failuresNeverClaimConnectedOrPromptForUnrelatedPasswords(failure: WiFiJoinError) async {
        let joiner = RecordingWiFiJoiner(outcomes: [.failure(failure)])
        let controller = WiFiConnectionController(joiner: joiner)
        await controller.join(secured)
        #expect(controller.phase == .failed(secured, failure))
        #expect(controller.connectedNetwork == nil)
        #expect(!controller.busy)
    }

    @Test func duplicateClicksAndDismissalCannotStartOverlappingOrPretendToCancelNativeWork() async {
        let joiner = GatedWiFiJoiner()
        let controller = WiFiConnectionController(joiner: joiner)
        let first = Task { await controller.join(secured) }
        await joiner.waitUntilStarted()
        #expect(controller.busy)
        #expect(controller.phase == .connecting(secured))
        controller.dismissPrompt()
        controller.clearResult()
        await controller.join(open)
        await controller.submit(password: "ignored fixture")
        #expect(await joiner.count == 1)
        #expect(controller.phase == .connecting(secured))
        controller.requestPassword(for: secured)
        #expect(controller.phase == .connecting(secured))
        await joiner.finish()
        await first.value
        #expect(controller.phase == .connected(secured))
        controller.clearResult()
        #expect(controller.phase == .idle)
    }

    @Test func genericNativeFailureStillAllowsReplacingStaleSavedPassword() async {
        let joiner = RecordingWiFiJoiner(outcomes: [.failure(.system(-3906)), .success])
        let controller = WiFiConnectionController(joiner: joiner)
        await controller.join(secured)
        #expect(controller.phase == .failed(secured, .system(-3906)))
        controller.requestPassword(for: secured)
        #expect(controller.phase == .passwordRequired(secured, nil))
        #expect(await joiner.calls.count == 1)
        await controller.submit(password: "replacement fixture")
        #expect(controller.phase == .connected(secured))
        #expect(await joiner.calls.last?.password == "replacement fixture")
    }

    @Test func selectedSecurityVariantIsTheOnlyOptimisticCurrentRow() async {
        let controller = WiFiConnectionController(joiner: RecordingWiFiJoiner())
        let selected = NearbyWiFi.Row(name: "Transition Fixture", signal: -40, security: .wpa3Transition)
        let sameNameOpen = NearbyWiFi.Row(name: selected.name, signal: -30, security: .open)
        let negotiated = NearbyWiFi.Row(name: selected.name, signal: -40, security: .wpa3Personal)
        #expect(controller.isCurrent(secured, scannedCurrentID: secured.id))
        await controller.join(selected)
        #expect(controller.isCurrent(selected, scannedCurrentID: secured.id))
        #expect(!controller.isCurrent(sameNameOpen, scannedCurrentID: secured.id))
        #expect(!controller.isCurrent(secured, scannedCurrentID: secured.id))
        #expect(controller.isCurrent(negotiated, scannedCurrentID: negotiated.id))
        #expect(!controller.isCurrent(sameNameOpen, scannedCurrentID: negotiated.id))
    }

    @Test func nativeErrorsMapToActionableSanitizedMessages() {
        #expect(WiFiJoinError.association(NSError(domain: CWErrorDomain, code: CWErr.cwTimeoutErr.rawValue)) == .timedOut)
        #expect(WiFiJoinError.association(NSError(domain: CWErrorDomain, code: CWErr.cwInvalidPMKErr.rawValue)) == .authentication)
        #expect(WiFiJoinError.association(NSError(domain: CWErrorDomain, code: CWErr.cwOperationNotPermittedErr.rawValue)) == .permission)
        #expect(WiFiJoinError.association(NSError(domain: CWErrorDomain, code: CWErr.cwNotSupportedErr.rawValue)) == .unsupported)
        let error = NSError(domain: "Fixture", code: 123, userInfo: [NSLocalizedDescriptionKey: "sensitive fixture"])
        #expect(WiFiJoinError.association(error) == .system(123))
        #expect(!WiFiJoinError.association(error).message.contains("sensitive fixture"))
    }

    @Test func connectedBannerAutoDismissesAfterConfiguredDuration() async throws {
        let sleeper = GatedSleep()
        let controller = WiFiConnectionController(
            joiner: RecordingWiFiJoiner(),
            connectedBannerDuration: .seconds(4),
            bannerSleep: { try await sleeper.sleep(for: $0) }
        )
        await controller.join(open)
        #expect(controller.phase == .connected(open))
        let dismissTask = try #require(controller.autoDismissTask)
        await sleeper.waitUntilSleeping()
        #expect(await sleeper.durations == [.seconds(4)])
        #expect(controller.phase == .connected(open))
        #expect(await sleeper.releaseNext())
        await dismissTask.value
        #expect(controller.phase == .idle)
    }

    @Test func manualClearOrSubsequentJoinCancelsPendingConnectedAutoDismiss() async throws {
        let sleeper = GatedSleep()
        let controller = WiFiConnectionController(
            joiner: RecordingWiFiJoiner(outcomes: [.success, .failure(.timedOut)]),
            connectedBannerDuration: .seconds(4),
            bannerSleep: { try await sleeper.sleep(for: $0) }
        )
        await controller.join(open)
        #expect(controller.phase == .connected(open))
        let dismissTask = try #require(controller.autoDismissTask)
        await sleeper.waitUntilSleeping()

        controller.clearResult()
        #expect(controller.phase == .idle)
        await sleeper.waitUntilCancelled()
        await dismissTask.value
        #expect(await sleeper.cancelledCount == 1)

        await controller.join(secured)
        #expect(controller.phase == .failed(secured, .timedOut))
        #expect(await sleeper.durations.count == 1)
    }

    @Test func staleConnectedSleepResolvingAfterClearOrFailedJoinNeverClearsPhase() async throws {
        let sleeper = GatedSleep(ignoreCancellation: true)
        let controller = WiFiConnectionController(
            joiner: RecordingWiFiJoiner(outcomes: [.success, .failure(.timedOut)]),
            connectedBannerDuration: .seconds(4),
            bannerSleep: { try await sleeper.sleep(for: $0) }
        )
        await controller.join(open)
        #expect(controller.phase == .connected(open))
        let staleTask = try #require(controller.autoDismissTask)
        await sleeper.waitUntilSleeping()

        controller.clearResult()
        #expect(controller.phase == .idle)
        await sleeper.waitUntilCancelled()

        await controller.join(secured)
        #expect(controller.phase == .failed(secured, .timedOut))

        // Even if a stale sleep resolves without throwing, failed state must never be cleared
        #expect(await sleeper.releaseNext())
        await staleTask.value
        #expect(controller.phase == .failed(secured, .timedOut))
    }

    @Test func inFlightJoinIsNotClearedByEarlierConnectedTimer() async throws {
        let joiner = GatedWiFiJoiner()
        let sleeper = GatedSleep(ignoreCancellation: true)
        let controller = WiFiConnectionController(
            joiner: joiner,
            connectedBannerDuration: .seconds(4),
            bannerSleep: { try await sleeper.sleep(for: $0) }
        )
        let first = Task { await controller.join(open) }
        await joiner.waitUntilStarted()
        await joiner.finish()
        await first.value
        #expect(controller.phase == .connected(open))
        let firstTimer = try #require(controller.autoDismissTask)
        await sleeper.waitUntilSleeping()

        let second = Task { await controller.join(secured) }
        await joiner.waitUntilStarted()
        #expect(controller.phase == .connecting(secured))
        await sleeper.waitUntilCancelled()

        // Even if the earlier connected sleep finishes while the new join is in flight,
        // the generation guard keeps .connecting intact.
        #expect(await sleeper.releaseNext())
        await firstTimer.value
        #expect(controller.phase == .connecting(secured))

        await joiner.finish(error: .timedOut)
        await second.value
        #expect(controller.phase == .failed(secured, .timedOut))
    }

    @Test func dismissPromptOnlyClearsPasswordPromptAndPreservesConnectedAutoDismiss() async throws {
        let sleeper = GatedSleep()
        let controller = WiFiConnectionController(
            joiner: RecordingWiFiJoiner(),
            connectedBannerDuration: .seconds(4),
            bannerSleep: { try await sleeper.sleep(for: $0) }
        )
        await controller.join(open)
        #expect(controller.phase == .connected(open))
        let dismissTask = try #require(controller.autoDismissTask)
        await sleeper.waitUntilSleeping()

        controller.dismissPrompt()
        #expect(controller.phase == .connected(open))
        #expect(await sleeper.cancelledCount == 0)

        #expect(await sleeper.releaseNext())
        await dismissTask.value
        #expect(controller.phase == .idle)
    }

    @Test func nilConnectedBannerDurationNeverSchedulesAutoDismiss() async {
        let sleeper = GatedSleep()
        let controller = WiFiConnectionController(
            joiner: RecordingWiFiJoiner(),
            connectedBannerDuration: nil,
            bannerSleep: { try await sleeper.sleep(for: $0) }
        )
        await controller.join(open)
        #expect(controller.phase == .connected(open))
        #expect(controller.autoDismissTask == nil)
        #expect(await sleeper.durations.isEmpty)
    }
}

actor RecordingWiFiJoiner: WiFiJoining {
    enum Outcome { case success, failure(WiFiJoinError) }
    struct Call: Sendable { let network: NearbyWiFi.Row; let password: String? }
    private var outcomes: [Outcome]
    private(set) var calls: [Call] = []
    init(outcomes: [Outcome] = []) { self.outcomes = outcomes }
    func join(_ network: NearbyWiFi.Row, password: String?) async throws {
        calls.append(Call(network: network, password: password))
        if !outcomes.isEmpty, case .failure(let error) = outcomes.removeFirst() { throw error }
    }
}

actor GatedWiFiJoiner: WiFiJoining {
    private(set) var count = 0
    private var pending: CheckedContinuation<Void, Error>?
    private var started: CheckedContinuation<Void, Never>?
    func join(_ network: NearbyWiFi.Row, password: String?) async throws {
        count += 1
        try await withCheckedThrowingContinuation { pending = $0; started?.resume(); started = nil }
    }
    func waitUntilStarted() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(error: WiFiJoinError? = nil) {
        if let error { pending?.resume(throwing: error) }
        else { pending?.resume() }
        pending = nil
    }
}

actor GatedSleep {
    private struct Entry {
        var continuation: CheckedContinuation<Void, Error>?
        var cancelled = false
    }

    private let ignoreCancellation: Bool
    private(set) var durations: [Duration] = []
    private(set) var cancelledCount = 0
    private var nextID: UInt64 = 0
    private var registeredCount = 0
    private var entries: [UInt64: Entry] = [:]
    private var waitOrder: [UInt64] = []
    private var sleepWaiters: [(targetCount: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var cancelWaiters: [(targetCount: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(ignoreCancellation: Bool = false) {
        self.ignoreCancellation = ignoreCancellation
    }

    func sleep(for duration: Duration) async throws {
        let id = allocateID(for: duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerContinuation(continuation, id: id)
            }
        } onCancel: {
            Task { await self.handleCancel(id: id) }
        }
    }

    func waitUntilSleeping(count: Int = 1) async {
        if registeredCount >= count { return }
        await withCheckedContinuation { sleepWaiters.append((count, $0)) }
    }

    func waitUntilCancelled(count: Int = 1) async {
        if cancelledCount >= count { return }
        await withCheckedContinuation { cancelWaiters.append((count, $0)) }
    }

    @discardableResult
    func releaseNext() -> Bool {
        for id in waitOrder {
            guard let continuation = entries[id]?.continuation else { continue }
            entries.removeValue(forKey: id)
            continuation.resume()
            return true
        }
        return false
    }

    private func allocateID(for duration: Duration) -> UInt64 {
        durations.append(duration)
        nextID &+= 1
        let id = nextID
        entries[id] = Entry()
        waitOrder.append(id)
        return id
    }

    private func registerContinuation(_ continuation: CheckedContinuation<Void, Error>, id: UInt64) {
        if entries[id]?.cancelled == true && !ignoreCancellation {
            entries.removeValue(forKey: id)
            continuation.resume(throwing: CancellationError())
        } else {
            entries[id]?.continuation = continuation
        }
        registeredCount += 1
        resumeWaiters(&sleepWaiters, currentCount: registeredCount)
    }

    private func handleCancel(id: UInt64) {
        cancelledCount += 1
        resumeWaiters(&cancelWaiters, currentCount: cancelledCount)
        guard !ignoreCancellation, entries[id] != nil else { return }
        if let continuation = entries[id]?.continuation {
            entries.removeValue(forKey: id)
            continuation.resume(throwing: CancellationError())
        } else {
            entries[id]?.cancelled = true
        }
    }

    private func resumeWaiters(_ waiters: inout [(targetCount: Int, continuation: CheckedContinuation<Void, Never>)],
                               currentCount: Int) {
        var remaining: [(targetCount: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in waiters {
            if currentCount >= waiter.targetCount {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}
