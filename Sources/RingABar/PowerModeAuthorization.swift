import Foundation
import Observation
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
    private let connection: NSXPCConnection
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    private init(requirement: String, continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
        connection = NSXPCConnection(machServiceName: PowerModeServiceIdentity.helper, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: PowerModeServiceProtocol.self)
    }

    private func finish(_ result: Bool) {
        let callback = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
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
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(3)) { call.finish(false) }
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
