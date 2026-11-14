import SwiftUI

/// One short, non-bouncing curve for SwiftUI content and its AppKit viewport.
/// Keep ordinary telemetry/slider updates outside value-scoped animations.
enum PanelMotion {
    static let duration: TimeInterval = 0.22
    static let appearDuration: TimeInterval = 0.14
    static let controlPoint1 = CGPoint(x: 0.16, y: 1)
    static let controlPoint2 = CGPoint(x: 0.30, y: 1)

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .timingCurve(
            controlPoint1.x, controlPoint1.y, controlPoint2.x, controlPoint2.y,
            duration: duration)
    }

    static func pageTransition(reduceMotion: Bool) -> AnyTransition {
        // Headers belong to the page too: even a small entrance offset makes
        // the back button/title visibly drift after navigation. Fade in place.
        reduceMotion ? .identity : .opacity
    }

    static func disclosureTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .identity : .opacity.combined(with: .offset(y: -4))
    }
}

/// Only complete layouts are saved for the next presentation.
struct PanelFitRequest: Equatable {
    let layout: PanelLayout
    let presentation: UInt64
    let height: CGFloat
    let ready: Bool

    func matches(layout: PanelLayout, presentation: UInt64) -> Bool {
        self.layout == layout && self.presentation == presentation
            && height.isFinite && height > 0
    }

    func targetHeight(currentHeight: CGFloat, wifiFeedbackVisible: Bool) -> CGFloat? {
        // Keep the loading page visible at the current size while the nearby
        // list arrives. A password, progress or error card can size the panel.
        if case .network(wifi: true, expanded: _, more: _) = layout,
           !ready, !wifiFeedbackVisible, height < currentHeight {
            return nil
        }
        return height
    }
}
