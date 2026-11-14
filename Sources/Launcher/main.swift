import AppKit
import Foundation

let launcherURL = Bundle.main.bundleURL
let appURL = launcherURL
    .deletingLastPathComponent() // MacOS
    .deletingLastPathComponent() // Contents
    .deletingLastPathComponent() // TrioRingLauncher.app
    .deletingLastPathComponent() // LoginItems
    .deletingLastPathComponent() // Library
    .deletingLastPathComponent() // Contents
    .appendingPathComponent("MacOS")
    .appendingPathComponent("TrioRing")

let semaphore = DispatchSemaphore(value: 0)
let configuration = NSWorkspace.OpenConfiguration()
NSWorkspace.shared.open(appURL, configuration: configuration) { _, error in
    if let error {
        fputs("Failed to launch TrioRing: \(error)\n", stderr)
    }
    semaphore.signal()
}
_ = semaphore.wait(timeout: .now() + 5)
