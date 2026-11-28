import AppKit
import SwiftUI

enum SystemSettingsPane {
    case battery, network, wifi, vpn, sound, sharing, location, menuBar

    var url: URL {
        let pane = switch self {
        case .battery: "com.apple.Battery-Settings.extension"
        case .network: "com.apple.Network-Settings.extension"
        case .wifi: "com.apple.wifi-settings-extension"
        case .vpn: "com.apple.NetworkExtensionSettingsUI.NESettingsUIExtension"
        case .sound: "com.apple.Sound-Settings.extension"
        case .sharing: "com.apple.Sharing-Settings.extension"
        case .location: "com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices"
        case .menuBar: "com.apple.ControlCenter-Settings.extension"
        }
        return URL(string: "x-apple.systempreferences:" + pane)
            ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")
    }
}

struct PageHeader<Trailing: View>: View {
    static var height: CGFloat { 32 }

    let title: LocalizedStringKey
    let navigationFocus: FocusState<PanelNavigationFocus?>.Binding
    let onBack: () -> Void
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            backButton
            trailing()
        }
        .frame(height: Self.height)
    }

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.backward")
                    .font(.caption.weight(.semibold))
                    .frame(width: Self.height, height: Self.height)
                    .background {
                        Circle().fill(Color.primary.opacity(hovered ? 0.07 : 0))
                    }
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .opacity(hovered ? 0.72 : 1.0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .focused(navigationFocus, equals: .back)
        .accessibilityLabel("Back")
        .accessibilityValue(Text(title))
        .help("Back (⌘[)")
        .accessibilityIdentifier("RingABar.management.back")
    }
}

struct DetailHeaderAction: View {
    let symbol: String
    var isBusy = false

    var body: some View {
        ZStack {
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: StatusPanel.summaryActionWidth, height: StatusPanel.summaryActionWidth)
        .accessibilityHidden(true)
    }
}

struct DetailPanel<Header: View, Content: View>: View {
    let height: PanelHeightReporter
    let headerHeight: CGFloat
    let spacing: CGFloat
    let scrollContentID: String?
    let header: Header
    let content: Content
    @State private var contentScrolled = false
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(height: PanelHeightReporter, headerHeight: CGFloat = PageHeader<EmptyView>.height, spacing: CGFloat = 12,
         scrollContentID: String? = nil, @ViewBuilder header: () -> Header,
         @ViewBuilder content: () -> Content) {
        self.height = height
        self.headerHeight = headerHeight
        self.spacing = spacing
        self.scrollContentID = scrollContentID
        self.header = header()
        self.content = content()
    }

    var body: some View {
        let topInset: CGFloat = 14
        let chromeHeight = topInset + headerHeight + spacing
        let contentWidth = AnchoredPanel.width - 28
        VStack(alignment: .leading, spacing: 0) {
            header.frame(width: contentWidth, height: headerHeight, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, topInset)
                .padding(.bottom, spacing)
                .overlay(alignment: .bottom) {
                    if contentScrolled {
                        Divider().padding(.horizontal, 14)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            .transition(.opacity)
                    }
                }
                .animation(PanelMotion.animation(reduceMotion: reduceMotion), value: contentScrolled)
            ScrollView {
                height.measuring(
                    content.frame(width: contentWidth, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading),
                    adding: chromeHeight
                )
            }
            // Constrain the viewport independently of the document. Overlay
            // scrollers preserve its full width even during a native resize.
            .frame(width: AnchoredPanel.width, alignment: .leading)
            .background(StableScrollViewport())
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 1
            } action: { _, scrolled in
                contentScrolled = scrolled
            }
            .scrollPosition($scrollPosition)
        }
        .frame(width: AnchoredPanel.width, alignment: .leading)
        .onChange(of: scrollContentID) { _, _ in
            contentScrolled = false
            scrollPosition.scrollTo(edge: .top)
        }
    }
}

struct DetailGroup<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DetailValue: View {
    let label: LocalizedStringKey
    let value: String
    var copyID: String?
    @State private var copySucceeded: Bool?
    @State private var copyRevision = 0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).panelSecondaryText()
            Spacer(minLength: 0)
            if let copyID {
                Button {
                    NSPasteboard.general.clearContents()
                    copySucceeded = NSPasteboard.general.setString(value, forType: .string)
                    copyRevision += 1
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(value).multilineTextAlignment(.trailing)
                            .monospacedDigit()
                        Image(systemName: copySucceeded == true ? "checkmark" : copySucceeded == false ? "exclamationmark.circle" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                            .font(.caption2)
                            .foregroundStyle(copySucceeded == true ? Color.green : copySucceeded == false ? Color.red : .secondary)
                            .frame(width: 12)
                            .accessibilityHidden(true)
                    }
                    .help(copySucceeded == true ? Text("Copied") : copySucceeded == false ? Text("Copy failed") : Text("Copy"))
                }
                .buttonStyle(PanelActionStyle())
                .accessibilityLabel(Text("\(Text(label)): \(value)"))
                .accessibilityHint("Copy")
                .accessibilityValue(copySucceeded == true ? Text("Copied") : copySucceeded == false ? Text("Copy failed") : Text(""))
                .accessibilityIdentifier(copyID)
                .task(id: copyRevision) {
                    guard copySucceeded != nil else { return }
                    do { try await Task.sleep(for: .seconds(1.5)) }
                    catch { return }
                    copySucceeded = nil
                }
                .onChange(of: value) { _, _ in copySucceeded = nil }
            } else {
                Text(value)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
        }
        .font(.caption)
    }
}

struct DetailSettingsLink: View {
    let title: LocalizedStringKey
    let accessibilityID: String
    let action: () -> Void

    init(_ title: LocalizedStringKey, id: String, action: @escaping () -> Void) {
        self.title = title
        self.accessibilityID = id
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
        }
        .buttonStyle(PanelActionStyle())
        .accessibilityIdentifier(accessibilityID)
    }
}
