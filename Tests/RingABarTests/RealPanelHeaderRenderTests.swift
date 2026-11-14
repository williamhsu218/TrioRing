import AppKit
import SwiftUI
import Testing
@testable import RingABar

@MainActor @Suite(.serialized)
struct RealPanelHeaderRenderTests {
    /// Uses production DetailPanel/PageHeader and tracks body icons too.
    /// Native indicators must never reserve width or flash during a resize,
    /// including animated content expansion inside an already visible page.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRIORING_RENDER_UI"] == "1"),
          arguments: ["Battery · 80%", "Wi-Fi", "Audio"])
    func realHeaderStaysAnchoredWhileScrollerAppearsAndDisappears(title: String) async throws {
        _ = NSApplication.shared
        let state = DetailHeaderSamples()
        let hosting = NSHostingView(rootView: DetailHeaderFixture(title: title, samples: state))
        let panel = AnchoredPanel()
        panel.anchor(in: NSRect(x: -20000, y: -20000, width: 1200, height: 900), center: -19400)
        panel.host(hosting)
        panel.fit(height: 140)
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.contentView = nil }
        try await Task.sleep(for: .milliseconds(100))
        for height: CGFloat in [140, 540, 160, 540] {
            state.contentHeight = height == 160 ? 680 : 420
            panel.fit(height: height, animated: true)
            for _ in 0..<24 {
                try await Task.sleep(for: .milliseconds(12))
                for scroll in scrollViews(in: hosting) {
                    #expect(scroll.frame.width <= AnchoredPanel.width + 0.5)
                    #expect(scroll.scrollerStyle == .overlay)
                    #expect(scroll.hasVerticalScroller == !panel.isResizingContent,
                            "Native indicators must stay suppressed until the final viewport settles")
                    if let document = scroll.documentView {
                        #expect(document.frame.width <= scroll.contentSize.width + 0.5,
                                "Vertical scrolling must not clip fixed-width content horizontally")
                    }
                }
            }
        }
        #expect(!state.headerXs.isEmpty)
        #expect(state.headerXs.allSatisfy { abs($0 - 14) <= 0.5 },
                "Actual header moved: \(state.headerXs)")
        #expect(state.widths.allSatisfy { abs($0 - AnchoredPanel.width) <= 0.5 },
                "Detail stack expanded: \(state.widths)")
        #expect(!state.documentWidths.isEmpty)
        #expect(state.documentWidths.allSatisfy { abs($0 - 302) <= 0.5 },
                "Body width changed as scrollbar toggled: \(state.documentWidths)")
        #expect(state.trailingXs.allSatisfy { abs($0 - 292) <= 0.5 },
                "Trailing body icon moved: \(state.trailingXs)")
        print("Real \(title) header x=\(state.headerXs), detail widths=\(state.widths), body widths=\(state.documentWidths), trailing icon x=\(state.trailingXs)")
    }

    /// A capped panel must remain genuinely scrollable. Suppression is scoped
    /// to the latest animation and must end even after interruption/closing.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRIORING_RENDER_UI"] == "1"))
    func overflowRemainsScrollableAndInterruptedResizeRestoresNativeControls() async throws {
        _ = NSApplication.shared
        let state = DetailHeaderSamples()
        state.contentHeight = 1000
        let hosting = NSHostingView(rootView: DetailHeaderFixture(title: "Audio", samples: state))
        let panel = AnchoredPanel()
        panel.anchor(in: NSRect(x: -20000, y: -20000, width: 1200, height: 320), center: -19400)
        panel.host(hosting)
        panel.fit(height: 140)
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.contentView = nil }
        try await Task.sleep(for: .milliseconds(100))
        let scroll = try #require(scrollViews(in: hosting).first)
        let systemPreference = UserDefaults.standard.string(forKey: "AppleShowScrollBars")
        // Simulate a width-consuming native style locally, not via defaults.
        scroll.scrollerStyle = .legacy
        for view in configurationViews(in: hosting) { view.configure() }
        #expect(scroll.scrollerStyle == .overlay)
        #expect(UserDefaults.standard.string(forKey: "AppleShowScrollBars") == systemPreference)
        panel.fit(height: 1000, animated: true)
        try await Task.sleep(for: .milliseconds(350))
        #expect(!panel.isResizingContent)
        #expect(scroll.hasVerticalScroller)
        #expect(scroll.contentSize.width == AnchoredPanel.width)
        #expect(try #require(scroll.documentView).frame.height > scroll.contentSize.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.minY >= 99)
        panel.fit(height: 140, animated: true)
        try await Task.sleep(for: .milliseconds(55))
        panel.fit(height: 250, animated: true)
        try await Task.sleep(for: .milliseconds(55))
        panel.fit(height: 1000, animated: true)
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(12))
            #expect(scroll.hasVerticalScroller == !panel.isResizingContent)
            #expect(scroll.contentSize.width == AnchoredPanel.width)
        }
        #expect(!panel.isResizingContent)
        panel.fit(height: 140, animated: true)
        panel.orderOut(nil)
        panel.fit(height: 180)
        try await Task.sleep(for: .milliseconds(350))
        #expect(!panel.isResizingContent)
        #expect(scroll.hasVerticalScroller)
        #expect(panel.frame.height == 180)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRIORING_RENDER_UI"] == "1"))
    func nestedAudioDeviceListPreservesBothViewportsAndScrolling() async throws {
        _ = NSApplication.shared
        let routes = (1...9).map {
            AudioRoute(id: UInt32($0), uid: "fixture.\($0)", name: "Microphone \($0)", symbol: "mic.fill")
        }
        let root = ScrollView {
            VStack(spacing: 0) {
                ScrollView {
                    AudioDeviceRows(devices: routes, direction: .input,
                                    picker: AudioDevicePicker(), monitor: AudioMonitor(onChange: { _ in }))
                        .frame(width: 302)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 5 * AudioDeviceRows.rowHeight)
                .background(StableScrollViewport())
                Color.clear.frame(height: 600)
            }
            .padding(.horizontal, 14)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .background(StableScrollViewport())
        .frame(width: AnchoredPanel.width)
        let hosting = NSHostingView(rootView: root)
        let panel = AnchoredPanel()
        panel.anchor(in: NSRect(x: -20000, y: -20000, width: 1200, height: 900), center: -19400)
        panel.host(hosting)
        panel.fit(height: 220)
        panel.orderFront(nil)
        defer { panel.orderOut(nil); panel.contentView = nil }
        try await Task.sleep(for: .milliseconds(100))
        panel.fit(height: 540, animated: true)
        for _ in 0..<28 {
            try await Task.sleep(for: .milliseconds(12))
            let scrolls = scrollViews(in: hosting)
            #expect(scrolls.count == 2)
            for scroll in scrolls {
                #expect(scroll.scrollerStyle == .overlay)
                #expect(scroll.hasVerticalScroller == !panel.isResizingContent)
                #expect(try #require(scroll.documentView).frame.width <= scroll.contentSize.width + 0.5)
            }
        }
        for scroll in scrollViews(in: hosting) {
            #expect(scroll.hasVerticalScroller)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 80))
            scroll.reflectScrolledClipView(scroll.contentView)
            #expect(scroll.contentView.bounds.minY >= 79)
        }
    }

    /// Optional read-only integration fixture mounts the whole StatusPanel in
    /// its real glass container and lets battery diagnostics finish loading.
    /// It never starts monitors, scans Wi-Fi, or calls device-setting writes.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRIORING_READ_UI"] == "1"))
    func actualBatteryAndNetworkHeaderDuringNavigationAndLoading() async throws {
        _ = NSApplication.shared
        let suite = "TrioRingHeaderTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.showsVPN = false
        preferences.showsLocalIP = false
        preferences.setVisible(false, section: .audio)
        let store = StatusStore()
        store.battery = .battery(.init(percent: 80, pluggedIn: true, chargeLimit: 80))
        // Powered off means the detail task cannot initiate a Wi-Fi scan.
        store.network = .init(path: .wifi, signalDBm: -50, wifiPowered: false, wifiName: "Fixture Wi-Fi")
        let panel = AnchoredPanel()
        panel.anchor(in: NSRect(x: -20000, y: -20000, width: 1200, height: 900), center: -19400)
        let root = StatusPanel(store: store, preferences: preferences,
            network: NetworkMonitor(onChange: { _ in }), audio: AudioMonitor(onChange: { _ in }),
            batteryActions: BatteryActions(defaults: defaults), wifiAccess: WiFiLocationAccess(),
            onVolume: { _, _ in }, onMute: { _, _ in }, onClose: {}, onSettings: {},
            onBatterySettings: {}, onNetworkSettings: {}, onAudioSettings: {}, onAbout: {},
            onHeight: { layout, _, height, _ in
                if layout == store.panelLayout { panel.fit(height: height, animated: true) }
            }, onQuit: {}, onSystemSettings: { _ in })
            .environment(\.colorScheme, .light)
            .environment(\.locale, Locale(identifier: "en_US"))
            .background(.white)
        let hosting = NSHostingView(rootView: root)
        panel.host(hosting)
        panel.fit(height: 320)
        panel.orderFront(nil)
        store.panelVisible = true
        defer { store.panelVisible = false; panel.orderOut(nil); panel.contentView = nil }
        try await Task.sleep(for: .milliseconds(400))
        let output = ProcessInfo.processInfo.environment["TRIORING_HEADER_SNAPSHOTS"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        for section in [PanelSection.battery, .network, .audio] {
            store.navigate(to: .details(section))
            var widths: [CGFloat] = []
            for index in 0..<45 {
                try await Task.sleep(for: .milliseconds(16))
                for scroll in scrollViews(in: hosting) {
                    widths.append(scroll.frame.width)
                    #expect(scroll.scrollerStyle == .overlay)
                    #expect(scroll.hasVerticalScroller == !panel.isResizingContent)
                    #expect(try #require(scroll.documentView).frame.width <= scroll.contentSize.width + 0.5)
                }
                if let output, [0, 3, 8, 15, 30, 44].contains(index) {
                    let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: output.appendingPathComponent("\(section.rawValue)-\(index).png"))
                }
            }
            #expect(!widths.isEmpty)
            #expect(widths.allSatisfy { $0 <= AnchoredPanel.width + 0.5 },
                    "Whole-panel \(section) scroll widths: \(widths)")
            store.navigate(to: .summary)
            try await Task.sleep(for: .milliseconds(300))
        }
    }

    private func configurationViews(in view: NSView) -> [ScrollViewportConfigurationView] {
        (view as? ScrollViewportConfigurationView).map { [$0] }
            ?? view.subviews.flatMap { configurationViews(in: $0) }
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }
}

@MainActor @Observable private final class DetailHeaderSamples {
    var headerXs: [CGFloat] = []
    var widths: [CGFloat] = []
    var contentHeight: CGFloat = 420
    var documentWidths: [CGFloat] = []
    var trailingXs: [CGFloat] = []
}

private struct DetailHeaderFixture: View {
    let title: String
    let samples: DetailHeaderSamples
    @FocusState private var navigationFocus: PanelNavigationFocus?

    var body: some View {
        GeometryReader { geometry in
            DetailPanel(height: .init(layout: .battery(readingsExpanded: false), presentation: 0,
                                      ready: true, onHeight: { _, _, _, _ in })) {
                PageHeader(title: LocalizedStringKey(title), navigationFocus: $navigationFocus, onBack: {}) {
                    if title != "Audio" {
                        Button {} label: {
                            DetailHeaderAction(symbol: "slider.horizontal.3")
                        }.buttonStyle(PanelActionStyle())
                    }
                    Button {} label: {
                        DetailHeaderAction(symbol: "info.circle")
                    }.buttonStyle(PanelActionStyle())
                }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: {
                    samples.headerXs.append($0)
                }
            } content: {
                // Track real body content too: pinning only the header must
                // not allow trailing icons to jump when a scrollbar vanishes.
                HStack {
                    Image(systemName: "speaker.wave.2.fill").frame(width: 24)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").frame(width: 24)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: {
                            samples.trailingXs.append($0)
                        }
                }
                .frame(height: samples.contentHeight)
                .animation(PanelMotion.animation(reduceMotion: false), value: samples.contentHeight)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                    samples.documentWidths.append($0)
                }
            }
            .frame(height: geometry.size.height, alignment: .top)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                samples.widths.append($0)
            }
        }
        .frame(width: AnchoredPanel.width)
    }
}
