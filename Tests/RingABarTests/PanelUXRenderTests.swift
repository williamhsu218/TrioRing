import AppKit
import ScreenCaptureKit
import SwiftUI
import Testing
@testable import RingABar

/// Opt-in render fixtures. No monitors are started, no action callbacks write to
/// devices, settings windows stay ordered behind other windows (falling back
/// off-screen when Screen Recording permission is unavailable), and preferences
/// use an ephemeral suite.
/// Run: TRIORING_RENDER_UI=1 swift test --filter PanelUXRenderTests
@MainActor
struct PanelUXRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRIORING_RENDER_UI"] == "1"))
    func renderChangedLayoutsWithoutDeviceActions() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "TrioRingTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.showsVPN = false
        preferences.showsPowerMode = false
        let store = StatusStore()
        store.battery = .battery(.init(percent: 80, pluggedIn: true, chargeLimit: 80))
        store.network = .init(path: .wifi, signalDBm: -50, wifiPowered: true, wifiName: "Studio Wi-Fi")
        store.audio = .init(deviceID: 1, deviceName: "Studio Headphones with a Very Long Device Name",
                            volume: 0.63, muted: true, canSetVolume: true, canMute: true,
                            deviceSymbol: "headphones")
        let audio = AudioMonitor(onChange: { _ in })
        let network = NetworkMonitor(onChange: { _ in })
        let actions = BatteryActions(defaults: defaults)
        let access = WiFiLocationAccess()
        let shortcut = GlobalShortcutController(preferences: preferences, backend: CarbonShortcutBackend(), action: {})
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("dist/verification-ui-ux")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let airPodsBattery = AirPodsBattery(main: nil, left: 39, right: 45, chargingCase: 100)
        let airPodsRoute = AudioRoute(id: 2, uid: "fixture:output", name: "Studio AirPods Pro", symbol: "airpodspro")
        let picker = AudioDevicePicker()
        let airPods = AirPodsOutput(deviceID: 2, uid: airPodsRoute.uid, currentMode: .noiseCancellation,
                                    supportedModes: [.noiseCancellation, .transparency, .adaptive])
        assertAirPodsControlsGeometry(output: airPods, picker: picker, monitor: audio)
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            let summary = StatusPanel(store: store, preferences: preferences, network: network, audio: audio,
                batteryActions: actions, wifiAccess: access, onVolume: { _, _ in }, onMute: { _, _ in },
                onClose: {}, onSettings: {}, onBatterySettings: {}, onNetworkSettings: {}, onAudioSettings: {},
                onAbout: {}, onHeight: { _, _, _, _ in }, onQuit: {}, onSystemSettings: { _ in })
            try snapshot(summary.frame(width: 330, height: 350), size: .init(width: 330, height: 350),
                         scheme: scheme, to: root.appendingPathComponent("summary-muted-\(suffix).png"))
            let flow = BatteryPowerFlowView(state: .init(
                input: .init(label: "Charger input", value: "30.00 W", watts: 30, kind: .input, detail: "MagSafe 3"),
                destinations: [
                    .init(label: "Battery charging", value: "10.00 W", watts: 10, kind: .charging),
                    .init(label: "Display", value: "0.20 W", watts: 0.2, kind: .display),
                    .init(label: "USB-C 1", value: "2.00 W", watts: 2, kind: .usb),
                    .init(label: "USB-C 2", value: "0.30 W", watts: 0.3, kind: .usb),
                    .init(label: "System power (est.)", value: "17.50 W", watts: 17.5, kind: .system)
                ]))
            try snapshot(flow.padding(14), size: .init(width: 330, height: flow.diagramHeight + 28),
                         scheme: scheme, to: root.appendingPathComponent("power-flow-\(suffix).png"))
            let airPodsFixture = VStack(spacing: 2) {
                AudioDeviceRowLabel(route: .init(id: 1, uid: "dock", name: "DL-Dock", symbol: "speaker.wave.2.fill"),
                                    selected: false, showsSummaryChips: true) { EmptyView() }
                AudioDeviceRowLabel(route: airPodsRoute, selected: true, showsSummaryChips: true) {
                    AirPodsBatteryIndicators(battery: airPodsBattery, deviceSymbol: airPodsRoute.symbol)
                }
                AirPodsControls(output: airPods, picker: picker, monitor: audio)
            }
            .padding(14)
            let airPodsURL = root.appendingPathComponent("airpods-battery-\(suffix).png")
            try snapshot(airPodsFixture, size: .init(width: 330, height: 122), scheme: scheme,
                         to: airPodsURL)
            try assertNoCornerBleedInSnapshot(at: airPodsURL, scheme: scheme)
            let longName = AudioDeviceRowLabel(
                route: .init(id: 2, uid: "long", name: "Studio AirPods Pro with an Extremely Long Device Name", symbol: "airpodspro"),
                selected: true, showsSummaryChips: true
            ) {
                AirPodsBatteryIndicators(battery: airPodsBattery, deviceSymbol: "airpodspro")
            }
            try snapshot(longName.padding(14), size: .init(width: 330, height: 56), scheme: scheme,
                         to: root.appendingPathComponent("airpods-battery-long-name-\(suffix).png"))
            for category in [SettingsCategory.audio, .panel] {
                store.settingsCategory = category
                let settings = SettingsView(preferences: preferences, store: store, audio: audio,
                    batteryActions: actions, wifiAccess: access, globalShortcut: shortcut,
                    onRecordShortcut: {}, onCancelShortcut: {})
                try await snapshotTitled(settings, size: .init(width: 720, height: 530), scheme: scheme,
                             to: root.appendingPathComponent("settings-\(category.rawValue)-\(suffix).png")) { hosting in
                    if category == .panel {
                        assertConsistentSmallSwitches(in: hosting)
                    }
                }
            }
        }
    }

    private func switches(in root: NSView) -> [NSSwitch] {
        root.subviews.flatMap { subview -> [NSSwitch] in
            let current = (subview as? NSSwitch).map { [$0] } ?? []
            return current + switches(in: subview)
        }
    }

    private func assertConsistentSmallSwitches(in view: NSView) {
        let panelSwitches = switches(in: view)
        #expect(!panelSwitches.isEmpty, "Expected to find NSSwitch controls in panel settings")
        #expect(panelSwitches.allSatisfy { $0.controlSize == .small })
    }

    private func findViews(in root: NSView, matching: (NSView) -> Bool) -> [NSView] {
        var matches: [NSView] = []
        if matching(root) { matches.append(root) }
        for sub in root.subviews {
            matches.append(contentsOf: findViews(in: sub, matching: matching))
        }
        return matches
    }

    private func assertConsistentDetailFooters(in hosting: NSView) {
        let nsButtons = findViews(in: hosting) { $0 is NSButton }.compactMap { $0 as? NSButton }
        for button in nsButtons {
            #expect(!button.isBordered, "Footer NSButton \(button.title) should be borderless (!isBordered)")
            #expect(button.bounds.width >= 280, "Footer NSButton \(button.title) width must be >= 280 pt (was \(button.bounds.width))")
        }

        let docViews = findViews(in: hosting) { NSStringFromClass(type(of: $0)).contains("DocumentView") }
        #expect(docViews.count == 3, "Expected 3 detail page document views (found \(docViews.count))")
        guard docViews.count == 3 else { return }

        // BatteryPage: footer links are the last 2 focus rings in its document view
        let batteryRings = findViews(in: docViews[0]) { NSStringFromClass(type(of: $0)).contains("FocusRingView") }
        #expect(batteryRings.count >= 2, "Expected at least 2 footer links in BatteryPage")
        for ring in batteryRings.suffix(2) {
            #expect(ring.bounds.width >= 280, "BatteryPage footer button width must be >= 280 pt (was \(ring.bounds.width))")
            #expect(abs(ring.bounds.height - 20) <= 2, "BatteryPage footer button height must be ~20 pt (was \(ring.bounds.height))")
        }

        // NetworkPage: footer links are the last 2 focus rings in its document view
        let networkRings = findViews(in: docViews[1]) { NSStringFromClass(type(of: $0)).contains("FocusRingView") }
        #expect(networkRings.count >= 2, "Expected at least 2 footer links in NetworkPage")
        for ring in networkRings.suffix(2) {
            #expect(ring.bounds.width >= 280, "NetworkPage footer button width must be >= 280 pt (was \(ring.bounds.width))")
            #expect(abs(ring.bounds.height - 20) <= 2, "NetworkPage footer button height must be ~20 pt (was \(ring.bounds.height))")
        }

        // AudioPage: footer link is the last focus ring in its document view
        let audioRings = findViews(in: docViews[2]) { NSStringFromClass(type(of: $0)).contains("FocusRingView") }
        #expect(!audioRings.isEmpty, "Expected footer settings link in AudioPage")
        if let audioFooter = audioRings.last {
            #expect(audioFooter.bounds.width >= 280, "AudioPage footer button width must be >= 280 pt (was \(audioFooter.bounds.width))")
            #expect(abs(audioFooter.bounds.height - 20) <= 2, "AudioPage footer button height must be ~20 pt (was \(audioFooter.bounds.height))")
        }
    }

    private struct DetailFootersFixture: View {
        let store: StatusStore
        let preferences: Preferences
        let actions: BatteryActions
        let network: NetworkMonitor
        let access: WiFiLocationAccess
        let audio: AudioMonitor
        let picker: AudioDevicePicker
        let batteryCache: BatteryPageCache
        let networkCache: NetworkPageCache
        @FocusState private var focus: PanelNavigationFocus?

        var body: some View {
            VStack(spacing: 20) {
                BatteryPage(store: store, preferences: preferences, actions: actions,
                            height: PanelHeightReporter(layout: .battery(readingsExpanded: false), presentation: 0, ready: true, onHeight: { _, _, _, _ in }),
                            navigationFocus: $focus, onBack: {}, onOpenSettings: {}, onOpenAppSettings: {}, cache: batteryCache)
                    .frame(width: 330, height: 360)
                NetworkPage(store: store, preferences: preferences, monitor: network, access: access,
                            height: PanelHeightReporter(layout: .network(wifi: true, expanded: false, more: false), presentation: 0, ready: true, onHeight: { _, _, _, _ in }),
                            navigationFocus: $focus, onBack: {}, onOpenSettings: { _ in }, onOpenAppSettings: {}, onTogglePower: {}, cache: networkCache)
                    .frame(width: 330, height: 230)
                AudioPage(store: store, preferences: preferences, monitor: audio, picker: picker, outputControls: EmptyView(),
                          height: PanelHeightReporter(layout: .audio(direction: .output, inputExpanded: false), presentation: 0, ready: true, onHeight: { _, _, _, _ in }),
                          navigationFocus: $focus, onBack: {}, onOpenSettings: {}, onOpenAppSettings: {})
                    .frame(width: 330, height: 180)
            }
            .frame(width: 330)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRIORING_RENDER_UI"] == "1"))
    func detailPageFootersConsistency() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let suite = "TrioRingTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let store = StatusStore()
        store.battery = .battery(.init(percent: 80, pluggedIn: true, chargeLimit: 80))
        store.network = .init(path: .wifi, signalDBm: -50, wifiPowered: true, wifiName: "Studio Wi-Fi")
        store.audio = .init(deviceID: 1, deviceName: "Studio Headphones", volume: 0.63, muted: false, canSetVolume: true, canMute: true, deviceSymbol: "headphones")
        let actions = BatteryActions(defaults: defaults)
        let network = NetworkMonitor(onChange: { _ in })
        let access = WiFiLocationAccess()
        let audio = AudioMonitor(onChange: { _ in })
        let picker = AudioDevicePicker()
        let batteryCache = BatteryPageCache()
        let networkCache = NetworkPageCache()

        let content = DetailFootersFixture(store: store, preferences: preferences, actions: actions,
                                           network: network, access: access, audio: audio, picker: picker,
                                           batteryCache: batteryCache, networkCache: networkCache)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("dist/verification-ui-ux")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            let url = root.appendingPathComponent("detail-footers-\(suffix).png")
            try snapshot(content, size: CGSize(width: 330, height: 810), scheme: scheme, to: url) { hosting in
                assertConsistentDetailFooters(in: hosting)
            }
        }
    }

    private func snapshotTitled<V: View>(
        _ view: V,
        size: CGSize,
        scheme: ColorScheme,
        to url: URL,
        inspect: ((NSView) -> Void)? = nil
    ) async throws {
        let content = view
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(scheme)
        guard CGPreflightScreenCaptureAccess() else {
            try snapshot(content, size: size, scheme: scheme, to: url, inspect: inspect)
            return
        }
        let appearance = try #require(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 100, y: 100), size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.appearance = appearance
        window.titleVisibility = .hidden
        let hosting = NSHostingController(rootView: content)
        window.contentViewController = hosting
        window.setContentSize(size)
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
        }
        appearance.performAsCurrentDrawingAppearance {
            window.layoutIfNeeded()
            hosting.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        inspect?(hosting.view)
        try await Task.sleep(for: .milliseconds(250))
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let scWindow = try #require(shareable.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        let scale = max(1, window.backingScaleFactor)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.scalesToFit = true
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.captureResolution = .best
        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: cgImage)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        try png.write(to: url)
        #expect(rep.pixelsWide > 0 && rep.pixelsHigh > 0)
    }

    private func snapshot<V: View>(
        _ view: V,
        size: CGSize,
        scheme: ColorScheme,
        to url: URL,
        inspect: ((NSView) -> Void)? = nil
    ) throws {
        let appearance = try #require(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
        let content = view
            .environment(\.colorScheme, scheme)
            .preferredColorScheme(scheme)
            .background(scheme == .dark ? Color(white: 0.14) : Color(white: 0.96))
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        appearance.performAsCurrentDrawingAppearance {
            hosting.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        inspect?(hosting)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        appearance.performAsCurrentDrawingAppearance {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        window.contentView = nil
    }

    private func assertAirPodsControlsGeometry(output: AirPodsOutput, picker: AudioDevicePicker, monitor: AudioMonitor) {
        let controls = AirPodsControls(output: output, picker: picker, monitor: monitor).frame(width: 286)
        let hosting = NSHostingView(rootView: controls)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: CGSize(width: 286, height: 32)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = CGRect(x: 0, y: 0, width: 286, height: 32)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let fitting = hosting.fittingSize
        #expect(fitting.width <= 286, "Rendered width must not overflow 286 pt (was \(fitting.width))")
        #expect(fitting.height >= 31 && fitting.height <= 33,
                "Rendered single-row height should stay ~32 pt (was \(fitting.height))")

        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            assertCleanSegmentThumb(in: rep, bounds: hosting.bounds)
        }

        window.contentView = nil
    }

    private func assertCleanSegmentThumb(in rep: NSBitmapImageRep, bounds: CGRect) {
        let scale = Double(rep.pixelsWide) / bounds.width
        var bluePixels: [(x: Int, y: Int)] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y),
                   c.blueComponent > 0.4 && c.blueComponent > c.redComponent * 1.4 {
                    bluePixels.append((x, y))
                }
            }
        }
        #expect(!bluePixels.isEmpty, "Expected active thumb pixels to be rendered")
        guard let minX = bluePixels.map(\.x).min(),
              let maxX = bluePixels.map(\.x).max(),
              let minY = bluePixels.map(\.y).min(),
              let maxY = bluePixels.map(\.y).max() else { return }

        let thumbWidth = (Double(maxX - minX) + 1.0) / scale
        let thumbHeight = (Double(maxY - minY) + 1.0) / scale
        let thumbLeading = Double(minX) / scale

        // Inside 286 pt with 7 pt horizontal padding and 2 pt track padding:
        // Interactive width = 286 - 14 - 4 = 268 pt -> ~89.3 pt per segment.
        #expect(abs(thumbWidth - (268.0 / 3.0)) <= 1.5, "Segment thumb width should be ~89.3 pt (was \(thumbWidth))")
        #expect(abs(thumbHeight - 28.0) <= 1.5, "Segment thumb height should be 28 pt (was \(thumbHeight))")
        #expect(abs(thumbLeading - 9.0) <= 1.5, "Segment thumb leading inset should be ~9 pt (was \(thumbLeading))")

        // Concentric circular capsule geometry: verify zero stroke bleed pixels in corner zones
        let r = Double(maxY - minY + 1) / 2.0
        let cy = Double(minY) + r
        let cxLeft = Double(minX) + r
        let cxRight = Double(maxX) - r

        var cornerBleedCount = 0
        for p in bluePixels {
            let x = Double(p.x)
            let y = Double(p.y)
            if x < cxLeft {
                let d = hypot(x - cxLeft, y - cy)
                if d > r + 1.5 * scale { cornerBleedCount += 1 }
            } else if x > cxRight {
                let d = hypot(x - cxRight, y - cy)
                if d > r + 1.5 * scale { cornerBleedCount += 1 }
            }
        }
        #expect(cornerBleedCount == 0, "Expected zero corner stroke bleed pixels (found \(cornerBleedCount))")
    }

    private func assertNoCornerBleedInSnapshot(at url: URL, scheme: ColorScheme) throws {
        guard let image = NSImage(contentsOf: url),
              let rep = image.representations.first as? NSBitmapImageRep else {
            Issue.record("Failed to read image at \(url.path)")
            return
        }

        var bluePixels: [(x: Int, y: Int)] = []
        for y in 150..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let isBlue: Bool
                if scheme == .dark {
                    isBlue = c.blueComponent > 0.4 && c.blueComponent > c.redComponent * 1.5
                } else {
                    isBlue = c.blueComponent > 0.6 && c.blueComponent > c.redComponent * 1.3
                }
                if isBlue { bluePixels.append((x, y)) }
            }
        }

        #expect(!bluePixels.isEmpty, "Expected active thumb pixels in snapshot at \(url.lastPathComponent)")
        guard let minX = bluePixels.map(\.x).min(),
              let maxX = bluePixels.map(\.x).max(),
              let minY = bluePixels.map(\.y).min(),
              let maxY = bluePixels.map(\.y).max() else { return }

        let r = Double(maxY - minY + 1) / 2.0
        let cy = Double(minY) + r
        let cxLeft = Double(minX) + r
        let cxRight = Double(maxX) - r

        var bleedCount = 0
        for p in bluePixels {
            let x = Double(p.x)
            let y = Double(p.y)
            if x < cxLeft {
                let d = hypot(x - cxLeft, y - cy)
                if d > r + 1.5 { bleedCount += 1 }
            } else if x > cxRight {
                let d = hypot(x - cxRight, y - cy)
                if d > r + 1.5 { bleedCount += 1 }
            }
        }
        #expect(bleedCount == 0, "Found \(bleedCount) corner stroke bleed pixels in snapshot \(url.lastPathComponent)")
    }
}
