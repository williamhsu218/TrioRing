import Foundation
import Observation
import os
import PowerModeServiceProtocol
import ServiceManagement

@MainActor @Observable
final class PowerModeAuthorization {
    enum State: Equatable {
        case unavailable, notSetUp, needsApproval, checking, ready, failed
    }

    private(set) var state: State
    private let requirement: String?
    private let service = SMAppService.daemon(plistName: PowerModeServiceIdentity.plist)
    private var lastStatus: SMAppService.Status?
    private var lastProbe: ContinuousClock.Instant?
    private var probeInProgress = false
    private var registrationInProgress = false

    init() {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/TrioRingPowerHelper")
        let requirement = PowerModeServiceIdentity.requirement(for: PowerModeServiceIdentity.helper,
                                                               requiringSelf: PowerModeServiceIdentity.app)
        self.requirement = FileManager.default.isExecutableFile(atPath: helper.path) ? requirement : nil
        state = self.requirement == nil ? .unavailable : .notSetUp
    }

    func setUp() {
        guard requirement != nil, !registrationInProgress, !probeInProgress else { return }
        registrationInProgress = true
        Task {
            defer { registrationInProgress = false }
            let status = service.status
            if status == .notRegistered || status == .notFound {
                do {
                    try service.register()
                } catch {
                    if service.status != .requiresApproval {
                        state = .failed
                        return
                    }
                }
            }
            await refresh(force: true)
            if state == .needsApproval { openSystemSettings() }
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    func refresh(force: Bool = false) async {
        guard let requirement, !probeInProgress else { return }
        let status = service.status
        let changed = lastStatus != status
        lastStatus = status
        guard status == .enabled || status == .requiresApproval else {
            if state != .failed { state = .notSetUp }
            lastProbe = nil
            return
        }
        let now = ContinuousClock.now
        let interval: Duration = state == .ready ? .seconds(60) : .seconds(8)
        if !force && !changed, let lastProbe, lastProbe.duration(to: now) < interval { return }
        probeInProgress = true
        lastProbe = now
        if state != .ready { state = .checking }
        let reachable = await PowerModeHelperCall.run(.ping, requirement: requirement)
        probeInProgress = false
        state = reachable ? .ready : (status == .requiresApproval ? .needsApproval : .failed)
    }

    func changeMode(_ mode: Int, onAC: Bool) async -> Bool {
        guard state == .ready, let requirement else { return false }
        let changed = await PowerModeHelperCall.run(.setMode(mode, onAC: onAC), requirement: requirement)
        if !changed { await refresh(force: true) }
        return changed
    }
}

/// One connection per request. Every failure path shares a single completion.
private final class PowerModeHelperCall: @unchecked Sendable {
    private struct Pending: Sendable {
        var continuation: CheckedContinuation<Bool, Never>?
        var timeout: Task<Void, Never>?
    }

    private let connection: NSXPCConnection
    private let state: OSAllocatedUnfairLock<Pending>

    private init(requirement: String, continuation: CheckedContinuation<Bool, Never>) {
        state = OSAllocatedUnfairLock(initialState: Pending(continuation: continuation, timeout: nil))
        connection = NSXPCConnection(machServiceName: PowerModeServiceIdentity.helper, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: PowerModeServiceProtocol.self)
    }

    private func setTimeout(_ task: Task<Void, Never>) {
        let shouldCancel = state.withLock { pending -> Bool in
            if pending.continuation == nil { return true }
            pending.timeout = task
            return false
        }
        if shouldCancel { task.cancel() }
    }

    private func finish(_ result: Bool) {
        let (callback, timeout) = state.withLock { pending -> (CheckedContinuation<Bool, Never>?, Task<Void, Never>?) in
            let current = pending.continuation
            let timer = pending.timeout
            pending.continuation = nil
            pending.timeout = nil
            return (current, timer)
        }
        timeout?.cancel()
        guard let callback else { return }
        connection.invalidate()
        callback.resume(returning: result)
    }

    enum Request: Sendable {
        case ping
        case setMode(Int, onAC: Bool)
    }

    static func run(_ request: Request, requirement: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let call = PowerModeHelperCall(requirement: requirement, continuation: continuation)
            call.connection.invalidationHandler = { [weak call] in call?.finish(false) }
            call.connection.interruptionHandler = { [weak call] in call?.finish(false) }
            call.connection.resume()
            let deadline: Duration = switch request {
            case .ping: .seconds(3)
            case .setMode: .seconds(8)
            }
            // Own the request until a reply, connection failure, or timeout finishes it.
            let timeout = Task {
                do { try await Task.sleep(for: deadline) }
                catch { return }
                call.finish(false)
            }
            call.setTimeout(timeout)
            guard let proxy = call.connection.remoteObjectProxyWithErrorHandler({ [weak call] _ in
                call?.finish(false)
            }) as? PowerModeServiceProtocol else {
                call.finish(false)
                return
            }
            let reply: (Bool) -> Void = { [weak call] result in call?.finish(result) }
            switch request {
            case .ping: proxy.ping(reply: reply)
            case let .setMode(mode, onAC): proxy.setPowerMode(mode, onAC: onAC, reply: reply)
            }
        }
    }
}
