import Foundation
import Sparkle
import Testing
@testable import RingABar

@MainActor
struct SharedRefreshTests {
    @Test func batteryReadSurvivesNavigationToAnotherPage() async throws {
        let picker = AudioDevicePicker()
        let uid = "test-airpods"
        let expected = AirPodsBattery(main: nil, left: 73, right: 81, chargingCase: nil)
        let (reads, requests) = AsyncStream<CheckedContinuation<AirPodsBattery?, Never>>.makeStream()
        defer { requests.finish() }

        let summary = Task {
            await picker.refreshAirPodsBattery(for: uid) { _ in
                await withCheckedContinuation { requests.yield($0) }
            }
        }
        var waitingReads = reads.makeAsyncIterator()
        let pending = try #require(await waitingReads.next())
        summary.cancel()
        await picker.refreshAirPodsBattery(for: uid) { _ in
            Issue.record("The detail page started a second read for the same device.")
            return nil
        }
        pending.resume(returning: expected)
        await summary.value
        #expect(picker.cachedAirPodsBattery(for: uid).battery == expected)
    }

    @Test func pendingUpdateNotificationsPreserveTheLatestChoice() async throws {
        let domain = "org.example.TrioRingTests.\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(domain).bundle")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: url)
        }
        let info: [String: Any] = ["CFBundleIdentifier": domain, "CFBundleVersion": "1",
                                   "CFBundlePackageType": "BNDL", "SUEnableAutomaticChecks": false]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: url))
        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: nil)
        let state = UpdaterState(updater: updater)

        updater.automaticallyChecksForUpdates = true
        state.setAutomaticallyChecksForUpdates(false)
        // Flush the pending observation callbacks before checking both sources.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(!state.automaticallyChecksForUpdates)
        #expect(!updater.automaticallyChecksForUpdates)

        updater.automaticallyChecksForUpdates = true
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(state.automaticallyChecksForUpdates)
    }
}
