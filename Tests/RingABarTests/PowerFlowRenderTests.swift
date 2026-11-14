import AppKit
import SwiftUI
import Testing
@testable import RingABar

/// Opt-in, off-screen regression for the production flow view. Uses only fixed
/// model data: no monitors, preferences, device actions or permission requests.
@Suite(.serialized)
@MainActor
struct PowerFlowRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRIORING_RENDER_UI"] == "1"),
          arguments: [ColorScheme.light, .dark])
    func identicalPowerReadingsKeepRibbonPixelsAcrossPresentations(scheme: ColorScheme) async throws {
        _ = NSApplication.shared
        let state = flow(charging: 10, system: 20)
        let size = CGSize(width: 330, height: BatteryPowerFlowView(state: state).diagramHeight + 28)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        // Never order the window on screen, or cover any physical display.
        let rightEdge = NSScreen.screens.map(\.frame.maxX).max() ?? 0
        window.setFrameOrigin(CGPoint(x: rightEdge + 500, y: 0))
        defer {
            window.contentView = nil
            window.close()
        }

        func mount(_ state: BatteryPowerFlowState) async throws -> NSHostingView<AnyView> {
            let content = BatteryPowerFlowView(state: state)
                .padding(14)
                .environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color(white: 0.14) : Color(white: 0.96))
            let hosting = NSHostingView(rootView: AnyView(content))
            window.contentView = hosting
            hosting.frame = CGRect(origin: .zero, size: size)
            hosting.layoutSubtreeIfNeeded()
            // Initial SwiftUI mounting may schedule one more layout pass. Do not
            // mistake that transient for a time-dependent change after settling.
            try await Task.sleep(for: .milliseconds(150))
            hosting.layoutSubtreeIfNeeded()
            return hosting
        }

        let initial = try await mount(state)
        let reference = try ribbonPixels(initial)
        try await Task.sleep(for: .milliseconds(350))
        let remainsStatic = try ribbonPixels(initial) == reference
        #expect(remainsStatic, "A settled diagram must stay static")

        // Multiple separated presentations catch a wall-clock sine even if the
        // first two samples happen to land at the same brightness. Compare the
        // ribbons only, not labels, fonts, window chrome or PNG metadata.
        for presentation in 1...3 {
            try await Task.sleep(for: .milliseconds(250))
            let hosting = try await mount(state)
            let repeated = try ribbonPixels(hosting)
            let changed = zip(reference, repeated).filter { $0 != $1 }.count
            print("Power flow \(scheme), presentation \(presentation): \(changed) changed ribbon bytes")
            #expect(repeated.count == reference.count)
            #expect(changed == 0, "Identical power readings must not change ribbon brightness")
        }

        // Negative control: the crop must really contain live ribbons, and a
        // changed power split must still alter their geometry.
        let changedHosting = try await mount(flow(charging: 20, system: 10))
        let changedSplit = try ribbonPixels(changedHosting)
        let updatesGeometry = changedSplit != reference
        #expect(updatesGeometry, "Changed watts must still update ribbon geometry")
    }

    private func flow(charging: Double, system: Double) -> BatteryPowerFlowState {
        .init(input: .init(label: "Charger input", value: "30 W", watts: 30, kind: .input),
              destinations: [
                .init(label: "Battery charging", value: "\(charging) W", watts: charging, kind: .charging),
                .init(label: "System power", value: "\(system) W", watts: system, kind: .system)
              ])
    }

    private func ribbonPixels(_ hosting: NSHostingView<AnyView>) throws -> [UInt8] {
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let bytes = try #require(bitmap.bitmapData)
        let bytesPerPixel = bitmap.bitsPerPixel / 8
        try #require(bitmap.bitsPerPixel > 0 && bitmap.bitsPerPixel % 8 == 0)
        let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
        // Diagram coordinates 100..<180 lie between the source card (0...84)
        // and branch cards (184...302); include the fixture's 14pt padding.
        let columns = Int(114 * scale)..<Int(194 * scale)
        var pixels: [UInt8] = []
        pixels.reserveCapacity(columns.count * bitmap.pixelsHigh * bytesPerPixel)
        for y in 0..<bitmap.pixelsHigh {
            for x in columns {
                let offset = y * bitmap.bytesPerRow + x * bytesPerPixel
                pixels.append(contentsOf: UnsafeBufferPointer(start: bytes + offset, count: bytesPerPixel))
            }
        }
        return pixels
    }
}
