import AppKit
import SwiftUI
import Testing
@testable import RingABar

@MainActor @Suite(.serialized)
struct WiFiConnectionRenderTests {
    /// Production password/status view, offscreen and fully injected: no scan,
    /// Keychain read, network association, synthetic input or permission prompts.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRIORING_RENDER_UI"] == "1"),
          arguments: [false, true])
    func passwordAndFailureStatesFitNativePanel(dark: Bool) async throws {
        _ = NSApplication.shared
        let network = NearbyWiFi.Row(name: "Fixture Wi-Fi · Long network name for narrow panel", signal: -50, security: .wpa2Personal)
        let joiner = RecordingWiFiJoiner(outcomes: [.failure(.passwordRequired), .failure(.authentication), .failure(.timedOut), .success])
        let controller = WiFiConnectionController(joiner: joiner)
        let root = WiFiConnectionView(controller: controller, onOpenSettings: {})
            .padding(14)
            .frame(width: AnchoredPanel.width, alignment: .topLeading)
            .environment(\.locale, Locale(identifier: "en"))
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(dark ? Color(white: 0.12) : Color(white: 0.96))
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 330, height: 280),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        #expect(controller.phase == .idle)
        #expect(hosting.fittingSize.width == AnchoredPanel.width)
        #expect(hosting.fittingSize.height <= 30, "Idle phase must render EmptyView with zero card chrome")
        await controller.join(network)
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.width == AnchoredPanel.width)
        #expect(hosting.fittingSize.height > 30)
        let fields = descendants(hosting).compactMap { $0 as? NSSecureTextField }
        #expect(fields.count == 1, "Password must use a native secure text field")
        for field in fields {
            #expect(field.stringValue.isEmpty)
            #expect(field.bounds.width > 200)
            let rect = field.convert(field.bounds, to: hosting)
            #expect(rect.minX >= 13 && rect.maxX <= 317, "Password input clipped outside 302 pt body")
        }
        try capture(hosting, name: "password-\(dark ? "dark" : "light")")
        await controller.submit(password: "incorrect fixture")
        #expect(controller.phase == .passwordRequired(network, .authentication))
        try await Task.sleep(for: .milliseconds(100))
        #expect(descendants(hosting).compactMap { $0 as? NSSecureTextField }.allSatisfy { $0.stringValue.isEmpty })
        try capture(hosting, name: "password-retry-\(dark ? "dark" : "light")")
        controller.dismissPrompt()
        try await Task.sleep(for: .milliseconds(50))
        #expect(descendants(hosting).compactMap { $0 as? NSSecureTextField }.isEmpty)
        let managed = NearbyWiFi.Row(name: "Managed Enterprise", signal: -40, security: .wpa2Enterprise)
        await controller.join(managed)
        try await Task.sleep(for: .milliseconds(100))
        #expect(descendants(hosting).compactMap { $0 as? NSSecureTextField }.isEmpty)
        #expect(hosting.fittingSize.width == 330)
        try capture(hosting, name: "enterprise-fallback-\(dark ? "dark" : "light")")
        #expect(await joiner.calls.count == 2, "Rendering and enterprise setup must not perform a native join")
        await controller.join(network)
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        #expect(controller.phase == .failed(network, .timedOut))
        #expect(hosting.fittingSize.width == AnchoredPanel.width)
        #expect(hosting.fittingSize.height > 30)
        try capture(hosting, name: "connection-error-\(dark ? "dark" : "light")")
        controller.requestPassword(for: network)
        try await Task.sleep(for: .milliseconds(50))
        #expect(descendants(hosting).compactMap { $0 as? NSSecureTextField }.count == 1)
        await controller.submit(password: "replacement fixture")
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        #expect(descendants(hosting).compactMap { $0 as? NSSecureTextField }.isEmpty)
        #expect(controller.phase == .connected(network))
        #expect(hosting.fittingSize.width == AnchoredPanel.width)
        #expect(hosting.fittingSize.height > 30)
        try capture(hosting, name: "connected-\(dark ? "dark" : "light")")
        controller.clearResult()
        try await Task.sleep(for: .milliseconds(50))
        hosting.layoutSubtreeIfNeeded()
        #expect(controller.phase == .idle)
        #expect(hosting.fittingSize.width == AnchoredPanel.width)
        #expect(hosting.fittingSize.height <= 30, "Clearing result must return to zero-height EmptyView")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRIORING_RENDER_UI"] == "1"))
    func passwordRequestResetsLongListViewportToRevealFeedback() async throws {
        _ = NSApplication.shared
        let joiner = GatedWiFiJoiner()
        let controller = WiFiConnectionController(joiner: joiner)
        let root = WiFiConnectionScrollFixture(controller: controller).frame(width: 330, height: 260)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 330, height: 260),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(for: .milliseconds(150))
        let scroll = try #require(descendants(hosting).compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 450))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(100))
        #expect(scroll.contentView.bounds.minY > 300)
        let row = NearbyWiFi.Row(name: "Fixture", signal: -50, security: .wpa2Personal)
        let operation = Task { await controller.join(row) }
        await joiner.waitUntilStarted()
        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.phase == .connecting(row))
        try capture(hosting, name: "connecting-long-list")
        await joiner.finish(error: .passwordRequired)
        await operation.value
        try await Task.sleep(for: .milliseconds(200))
        #expect(controller.phase == .passwordRequired(row, nil), "Removing the spinner must not dismiss the password request")
        #expect(scroll.contentView.bounds.minY <= 1, "Password prompt must not remain above a scrolled network list")
        let field = try #require(descendants(hosting).compactMap { $0 as? NSSecureTextField }.first)
        let fieldRect = field.convert(field.bounds, to: scroll.contentView)
        #expect(scroll.contentView.bounds.intersects(fieldRect))
    }

    private func descendants(_ root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants($0) }
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["TRIORING_WIFI_CAPTURE_DIR"] else { return }
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let target = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
        try data.write(to: target)
        print("Wi-Fi production UI capture: \(target.path), fitting size \(view.fittingSize)")
    }
}

private struct WiFiConnectionScrollFixture: View {
    let controller: WiFiConnectionController
    var body: some View {
        DetailPanel(height: PanelHeightReporter(layout: .network(wifi: true, expanded: false, more: false),
                                               presentation: 1, ready: true, onHeight: { _, _, _, _ in }),
                    scrollContentID: String(describing: controller.phase)) {
            Text("Wi-Fi")
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                WiFiConnectionView(controller: controller, onOpenSettings: {})
                Color.clear.frame(height: 900)
            }
        }
    }
}
