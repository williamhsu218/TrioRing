import Darwin
import Foundation
import PowerModeServiceProtocol

final class PowerModeService: NSObject, PowerModeServiceProtocol, NSXPCListenerDelegate, @unchecked Sendable {
    private let work = DispatchQueue(label: "com.willhsu.ring-a-bar.PowerMode.commands")
    private lazy var idle = DispatchSource.makeTimerSource(queue: work)

    func startIdleTimer() {
        idle.setEventHandler { exit(EXIT_SUCCESS) }
        extendLifetime()
        idle.activate()
    }

    private func extendLifetime() {
        idle.schedule(deadline: .now() + .seconds(45))
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: PowerModeServiceProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func ping(reply: @escaping (Bool) -> Void) {
        nonisolated(unsafe) let sendReply = reply
        work.async {
            self.extendLifetime()
            sendReply(true)
        }
    }

    func setPowerMode(_ mode: Int, onAC: Bool, reply: @escaping (Bool) -> Void) {
        guard (0...2).contains(mode) else { reply(false); return }
        nonisolated(unsafe) let sendReply = reply
        work.async {
            self.extendLifetime()
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            command.arguments = [onAC ? "-c" : "-b", "powermode", String(mode)]
            command.environment = ["PATH": "/usr/bin:/bin"]
            command.standardOutput = FileHandle.nullDevice
            command.standardError = FileHandle.nullDevice
            do {
                try command.run()
                command.waitUntilExit()
                self.extendLifetime()
                sendReply(command.terminationReason == .exit && command.terminationStatus == 0)
            } catch {
                sendReply(false)
            }
        }
    }
}

guard geteuid() == 0,
      let requirement = PowerModeServiceIdentity.requirement(for: PowerModeServiceIdentity.app,
                                                             requiringSelf: PowerModeServiceIdentity.helper) else {
    exit(EXIT_FAILURE)
}
let service = PowerModeService()
let listener = NSXPCListener(machServiceName: PowerModeServiceIdentity.helper)
listener.setConnectionCodeSigningRequirement(requirement)
listener.delegate = service
service.startIdleTimer()
listener.resume()
RunLoop.main.run()
