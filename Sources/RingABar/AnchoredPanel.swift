import AppKit
import QuartzCore

/// Keeps the top edge fixed as SwiftUI changes the height of the current page.
@MainActor
final class AnchoredPanel: NSPanel {
    static let width: CGFloat = 330
    static let initialSummaryHeight: CGFloat = 360
    private(set) var heightLimit: CGFloat = 580
    private var top: CGFloat = 0
    private var left: CGFloat = 0
    private var targetFrame: NSRect?
    private var resizeRevision: UInt64 = 0
    static let contentResizeStateDidChange = Notification.Name("TrioRing.panelContentResizeStateDidChange")
    private(set) var isResizingContent = false {
        didSet {
            guard oldValue != isResizingContent else { return }
            NotificationCenter.default.post(name: Self.contentResizeStateDidChange, object: self)
        }
    }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // The WindowServer show transition can briefly reuse the frame from
        // the last time the panel was visible, even after a hidden resize.
        animationBehavior = .none
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        autorecalculatesKeyViewLoop = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        setAccessibilityIdentifier("RingABar.panel")
        title = "TrioRing"
    }

    override var canBecomeKey: Bool { true }

    func host(_ view: NSView) {
        let frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.initialSummaryHeight)
        let cornerRadius: CGFloat = 22
        let container = NSView(frame: frame)
        // Keep the borderless window's composited corners round.
        container.wantsLayer = true
        container.layer?.cornerRadius = cornerRadius
        container.layer?.masksToBounds = true
        let glass = NSGlassEffectView(frame: frame)
        glass.style = .regular
        glass.cornerRadius = cornerRadius
        glass.autoresizingMask = [.width, .height]
        view.frame = glass.bounds
        view.autoresizingMask = [.width, .height]
        glass.contentView = view
        container.addSubview(glass)
        contentView = container
        initialFirstResponder = view
    }

    func anchor(under button: NSStatusBarButton, click: NSPoint?) {
        guard let window = button.window else { return }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = click.flatMap { point in NSScreen.screens.first { $0.frame.contains(point) } }
            ?? window.screen ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        let center = screen.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) ? rect.midX : click?.x ?? visible.midX
        anchor(in: visible, center: center)
    }

    func anchor(in visible: NSRect, center: CGFloat) {
        top = visible.maxY - 3
        left = min(max(center - Self.width / 2, visible.minX + 4), visible.maxX - Self.width - 4)
        heightLimit = max(120, top - visible.minY - 6)
    }

    func fit(height: CGFloat, animated: Bool = false) {
        guard height.isFinite, height > 0 else { return }
        let fitted = min(heightLimit, max(1, ceil(height)))
        let nextFrame = NSRect(x: left.rounded(), y: top - fitted, width: Self.width, height: fitted)
        let shouldAnimate = animated && isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // A readiness change can report the same target again. Do not restart
        // an in-flight resize, or continuous readings would keep it trailing.
        if shouldAnimate, targetFrame == nextFrame { return }
        targetFrame = nextFrame
        let hasFrameChange = abs(frame.height - nextFrame.height) >= 0.5
            || abs(frame.minY - nextFrame.minY) >= 0.5
            || abs(frame.minX - nextFrame.minX) >= 0.5
        if shouldAnimate && !hasFrameChange {
            isResizingContent = false
            return
        }
        resizeRevision &+= 1
        let revision = resizeRevision
        isResizingContent = shouldAnimate && hasFrameChange
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = shouldAnimate ? PanelMotion.duration : 0
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: Float(PanelMotion.controlPoint1.x), Float(PanelMotion.controlPoint1.y),
                Float(PanelMotion.controlPoint2.x), Float(PanelMotion.controlPoint2.y))
            // AppKit interpolates origin and height together, keeping the top
            // edge anchored. Autoresizing updates the hosted viewport per frame.
            animator().setFrame(nextFrame, display: true)
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.resizeRevision == revision else { return }
                self.isResizingContent = false
            }
        })
    }

    func presentFromStatusItem() {
        let animate = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate {
            alphaValue = 0
        } else {
            alphaValue = 1
        }
        makeKeyAndOrderFront(nil)
        guard animate else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelMotion.appearDuration
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: Float(PanelMotion.controlPoint1.x), Float(PanelMotion.controlPoint1.y),
                Float(PanelMotion.controlPoint2.x), Float(PanelMotion.controlPoint2.y))
            animator().alphaValue = 1
        }
    }

    override func orderOut(_ sender: Any?) {
        // Cancel a resize before hiding; it must not resize a later presentation.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().setFrame(frame, display: false)
            animator().alphaValue = 1
        }
        alphaValue = 1
        targetFrame = nil
        resizeRevision &+= 1
        isResizingContent = false
        super.orderOut(sender)
    }
}
