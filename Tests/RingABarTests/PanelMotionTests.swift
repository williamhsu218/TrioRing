import AppKit
import SwiftUI
import Testing
@testable import RingABar

@MainActor
struct PanelMotionTests {
    @Test func provisionalFitsAreValidButStaleOrInvalidSamplesAreNot() {
        let layout = PanelLayout.battery(readingsExpanded: true)
        let loading = PanelFitRequest(layout: layout, presentation: 4, height: 420, ready: false)
        #expect(loading.matches(layout: layout, presentation: 4))
        #expect(!loading.matches(layout: .summary(audioExpanded: false), presentation: 4))
        #expect(!loading.matches(layout: layout, presentation: 5))
        for height in [CGFloat.nan, .infinity, -.infinity, 0, -1] {
            #expect(!PanelFitRequest(layout: layout, presentation: 4, height: height, ready: true)
                .matches(layout: layout, presentation: 4))
        }
    }

    @Test func reduceMotionDisablesContentAnimation() {
        #expect(PanelMotion.animation(reduceMotion: true) == nil)
        #expect(PanelMotion.animation(reduceMotion: false) != nil)
        #expect(PanelMotion.duration <= 0.25)
    }

    @Test func wifiLoadingCannotShrinkTheViewportBeforeTheListArrives() {
        let layout = PanelLayout.network(wifi: true, expanded: false, more: false)
        let placeholder = PanelFitRequest(layout: layout, presentation: 4, height: 234, ready: false)
        #expect(placeholder.targetHeight(currentHeight: 346, wifiFeedbackVisible: false) == nil)
        #expect(placeholder.targetHeight(currentHeight: 200, wifiFeedbackVisible: false) == 234)
        #expect(placeholder.targetHeight(currentHeight: 346, wifiFeedbackVisible: true) == 234)
        let loadedList = PanelFitRequest(layout: layout, presentation: 4, height: 501, ready: true)
        #expect(loadedList.targetHeight(currentHeight: 346, wifiFeedbackVisible: false) == 501)
        let finishedEmpty = PanelFitRequest(layout: layout, presentation: 4, height: 234, ready: true)
        #expect(finishedEmpty.targetHeight(currentHeight: 346, wifiFeedbackVisible: false) == 234)
    }

    @Test func keyboardNavigationRestoresTheActualEntryPoint() {
        let store = StatusStore()
        store.audioExpanded = true
        store.navigate(to: .details(.audio), fromKeyboard: true)
        #expect(store.navigationFocus == .back)
        store.navigate(to: .summary, fromKeyboard: true)
        #expect(store.navigationFocus == .summary(.audio))
        #expect(store.audioExpanded)
        store.navigate(to: .details(.network))
        #expect(store.navigationFocus == nil)
        store.navigate(to: .summary)
        #expect(store.navigationFocus == nil)
    }

    @Test func batteryCacheSurvivesNavigationButNotSourceChanges() {
        let cache = BatteryPageCache()
        cache.prepare(pluggedIn: true)
        cache.details = BatteryDetails(maximumCapacity: 95, cycleCount: 100)
        cache.prepare(pluggedIn: true)
        #expect(cache.details?.maximumCapacity == 95)
        cache.prepare(pluggedIn: false)
        #expect(cache.details == nil)
        #expect(cache.power == nil)
    }

    @Test func scanReuseIsBoundedAndInvalidatedByNetworkOrPermissionChanges() {
        let cache = NetworkPageCache()
        let status = NetworkStatus(path: .wifi, wifiPowered: true, wifiName: "Fixture")
        let identity = NetworkPageIdentity(status: status, locationAllowed: true)
        let now = Date()
        cache.prepare(identity: identity)
        cache.nearby = NearbyWiFi(current: nil, known: [], other: [])
        cache.scannedAt = now
        #expect(cache.canReuseScan(for: identity, now: now.addingTimeInterval(29)))
        #expect(!cache.canReuseScan(for: identity, now: now.addingTimeInterval(30)))
        #expect(!cache.canReuseScan(for: identity, now: now.addingTimeInterval(-1)))
        var changed = status
        changed.wifiName = "Other network"
        #expect(!cache.canReuseScan(for: .init(status: changed, locationAllowed: true), now: now))
        let revoked = NetworkPageIdentity(status: status, locationAllowed: false)
        #expect(!cache.canReuseScan(for: revoked, now: now))
        cache.prepare(identity: revoked)
        #expect(cache.nearby == nil)
        #expect(cache.details == nil)
        #expect(cache.scannedAt == nil)
    }
}

/// These windows remain far outside every physical display. No monitors are
/// started and no volume, listening mode, Wi-Fi or charging actions are called.
@MainActor @Suite(.serialized)
struct PanelMotionRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRIORING_RENDER_UI"] == "1"))
    func panelResizeInterpolatesKeepsTopAnchoredAndCanBeInterrupted() async throws {
        _ = NSApplication.shared
        let panel = AnchoredPanel()
        panel.anchor(in: NSRect(x: -20000, y: -20000, width: 1200, height: 900), center: -19400)
        let content = NSView()
        panel.host(content)
        panel.fit(height: 220)
        #expect(abs(content.frame.height - 220) <= 1)
        let top = panel.frame.maxY
        let left = panel.frame.minX
        panel.orderFront(nil)
        defer { panel.orderOut(nil) }
        // Let synchronous screenshot fixtures and the initial window layout
        // finish before sampling a real-time animation on the shared main actor.
        try await Task.sleep(for: .milliseconds(80))
        panel.fit(height: 500, animated: true)
        var heights: [CGFloat] = []
        for _ in 0..<35 {
            try await Task.sleep(for: .milliseconds(10))
            heights.append(panel.frame.height)
            #expect(abs(panel.frame.maxY - top) <= 1)
            #expect(abs(panel.frame.minX - left) <= 0.5)
            #expect(abs(content.frame.height - panel.frame.height) <= 1)
        }
        #expect(abs(panel.frame.height - 500) <= 1)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            #expect(heights.contains { $0 > 221 && $0 < 499 })
        }
        panel.fit(height: 260, animated: true)
        try await Task.sleep(for: .milliseconds(55))
        panel.fit(height: 410, animated: true)
        try await Task.sleep(for: .milliseconds(320))
        #expect(abs(panel.frame.height - 410) <= 1)
        #expect(abs(panel.frame.maxY - top) <= 1)
        panel.fit(height: 700, animated: true)
        panel.orderOut(nil)
        panel.fit(height: 230)
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(panel.frame.height - 230) <= 1)
        panel.fit(height: .nan)
        #expect(abs(panel.frame.height - 230) <= 1)
        panel.fit(height: 5000)
        #expect(panel.frame.height == panel.heightLimit)
        print("Panel resize samples: \(heights.map { Int($0.rounded()) })")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRIORING_RENDER_UI"] == "1"))
    func animatedContentReportsItsTargetWithoutAResizeFeedbackLoop() async throws {
        _ = NSApplication.shared
        let state = DisclosureFixtureState()
        let hosting = NSHostingView(rootView: DisclosureFixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 330, height: 580),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(80))
        state.expanded = true
        try await Task.sleep(for: .milliseconds(350))
        #expect(state.heights.last == 320)
        state.expanded = false
        try await Task.sleep(for: .milliseconds(350))
        #expect(state.heights.last == 80)
        // Intrinsic geometry should publish layout targets, not one sample for
        // every animation frame that would restart the native viewport animator.
        #expect(state.heights.count < 12)
        print("Disclosure intrinsic samples: \(state.heights)")
    }
}

@MainActor @Observable private final class DisclosureFixtureState {
    var expanded = false
    var heights: [CGFloat] = []
}

private struct DisclosureFixture: View {
    let state: DisclosureFixtureState
    var body: some View {
        let reporter = PanelHeightReporter(layout: .battery(readingsExpanded: state.expanded),
            presentation: 1, ready: true, onHeight: { _, _, height, _ in state.heights.append(height) })
        VStack {
            reporter.measuring(
                VStack(spacing: 0) {
                    Color.clear.frame(height: 80)
                    if state.expanded { Color.blue.frame(height: 240).transition(.opacity) }
                }
                .animation(PanelMotion.animation(reduceMotion: false), value: state.expanded),
                adding: 0)
            Spacer(minLength: 0)
        }
        .frame(width: 330)
    }
}
