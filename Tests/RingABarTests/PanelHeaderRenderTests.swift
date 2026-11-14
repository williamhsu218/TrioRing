import AppKit
import SwiftUI
import Testing
@testable import RingABar

/// Samples rendered pixels, not GeometryReader's final layout target: the
/// latter cannot catch a transition's presentation-only horizontal offset.
@MainActor
struct PanelHeaderRenderTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRIORING_RENDER_UI"] == "1"))
    func headerAppearsAtItsFinalPositionOnEntryAndReturn() async throws {
        _ = NSApplication.shared
        let state = HeaderTransitionState()
        let hosting = NSHostingView(rootView: HeaderTransitionFixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 330, height: 580),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        // Let initial layout and other synchronous screenshot fixtures finish.
        try await Task.sleep(for: .milliseconds(100))
        for page in [PanelPage.details(.battery), .summary, .details(.network), .summary, .details(.audio), .summary] {
            state.page = page
            var positions: [ClosedRange<CGFloat>] = []
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(12))
                if let range = try markerRange(in: hosting, blue: page == .summary) { positions.append(range) }
            }
            #expect(positions.count >= 3)
            let left = positions.map(\.lowerBound)
            let right = positions.map(\.upperBound)
            let leftTravel = (left.max() ?? 0) - (left.min() ?? 0)
            let rightTravel = (right.max() ?? 0) - (right.min() ?? 0)
            #expect(leftTravel <= 0.5, "Header left edge moved \(leftTravel)pt on \(page)")
            #expect(rightTravel <= 0.5, "Header right edge moved \(rightTravel)pt on \(page)")
            #expect(abs((left.last ?? 0) - 14) <= 0.5)
            print("Header \(page): left \(left.min() ?? 0)...\(left.max() ?? 0), right \(right.min() ?? 0)...\(right.max() ?? 0)")
        }
    }

    private func markerRange(in view: NSView, blue: Bool) throws -> ClosedRange<CGFloat>? {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        var minimum: Int?
        var maximum: Int?
        // The six-point marker occupies the header near x=14, y=20. Search
        // a slightly larger area to include any in-flight transition offset.
        for x in 0..<min(bitmap.pixelsWide, Int(60 * scale)) {
            for y in stride(from: 0, to: min(bitmap.pixelsHigh, Int(64 * scale)), by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let dominant = blue ? color.blueComponent : color.redComponent
                let other = blue ? color.redComponent : color.blueComponent
                if dominant > 0.6, dominant - color.greenComponent > 0.2, dominant - other > 0.2 {
                    minimum = min(minimum ?? x, x)
                    maximum = max(maximum ?? x, x)
                    break
                }
            }
        }
        guard let minimum, let maximum else { return nil }
        return CGFloat(minimum) / scale ... CGFloat(maximum + 1) / scale
    }
}

@MainActor @Observable private final class HeaderTransitionState {
    var page: PanelPage = .summary
}

private struct HeaderTransitionFixture: View {
    let state: HeaderTransitionState
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        (state.page == .summary ? Color.blue : Color.red).frame(width: 6, height: 20)
                        Text("Header").font(.headline)
                        Spacer(minLength: 0)
                    }
                    .frame(width: 302, height: 32, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 12)
                    Color.clear
                }
                .frame(height: geometry.size.height, alignment: .top)
                .id(state.page)
                .transition(PanelMotion.pageTransition(reduceMotion: false))
            }
            .animation(PanelMotion.animation(reduceMotion: false), value: state.page)
        }
        .frame(width: 330)
        .background(.white)
    }
}
