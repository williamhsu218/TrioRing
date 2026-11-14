import AppKit
import SwiftUI

/// Attach to a vertical ScrollView's viewport. Native overlay scrollers
/// never take width from the content, so disclosures cannot reflow icons/text.
/// During a panel's content resize, omit the transient scroller altogether;
/// wheel/trackpad scrolling still works, and native controls return at rest.
struct StableScrollViewport: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollViewportConfigurationView {
        ScrollViewportConfigurationView()
    }

    func updateNSView(_ view: ScrollViewportConfigurationView, context: Context) {
        view.configureAfterAttachment()
    }
}

final class ScrollViewportConfigurationView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        configureAfterAttachment()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(
                self, selector: #selector(configure),
                name: AnchoredPanel.contentResizeStateDidChange, object: window)
            NotificationCenter.default.addObserver(
                self, selector: #selector(configure),
                name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        }
        configureAfterAttachment()
    }

    override func layout() {
        super.layout()
        configure()
    }

    func configureAfterAttachment() {
        configure()
        // SwiftUI mounts the background and its native scroll view in the
        // same update. Retry after that mounting pass, before the next draw.
        DispatchQueue.main.async { [weak self] in self?.configure() }
    }

    @objc func configure() {
        guard let root = window?.contentView else { return }
        // SwiftUI may flatten backgrounds outside NSClipView, so do not rely
        // on a private hosting hierarchy or enclosingScrollView. All vertical
        // scroll surfaces in this app window share the same local policy.
        configureScrollers(in: root)
    }

    private func configureScrollers(in view: NSView) {
        if let scroll = view as? NSScrollView {
            // Never change AppleShowScrollBars or any other user preference.
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
            let showsScroller = (window as? AnchoredPanel)?.isResizingContent != true
            if scroll.hasVerticalScroller != showsScroller {
                scroll.hasVerticalScroller = showsScroller
            }
        }
        for child in view.subviews { configureScrollers(in: child) }
    }
}
