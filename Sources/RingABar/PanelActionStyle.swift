import SwiftUI

struct PanelActionStyle: ButtonStyle {
    var cornerRadius: CGFloat = 9
    var highlightBleed = EdgeInsets()

    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration, cornerRadius: cornerRadius, highlightBleed: highlightBleed)
    }

    private struct HoverLabel: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        let highlightBleed: EdgeInsets
        @Environment(\.isEnabled) private var enabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorScheme) private var colorScheme
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background {
                    let active = enabled && (hovered || configuration.isPressed)
                    let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    shape
                        .fill(fillColor)
                        .overlay {
                            shape.strokeBorder(borderColor, lineWidth: 0.5)
                        }
                        .padding(EdgeInsets(
                            top: -highlightBleed.top,
                            leading: -highlightBleed.leading,
                            bottom: -highlightBleed.bottom,
                            trailing: -highlightBleed.trailing
                        ))
                        .opacity(active ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .shadow(color: Color.black.opacity(configuration.isPressed ? 0.2 : 0), radius: 2, x: 0, y: 1)
                .scaleEffect(configuration.isPressed && enabled && !reduceMotion ? 0.985 : 1.0)
                .animation(reduceMotion ? nil : .easeOut(duration: hovered ? 0.12 : 0.18), value: hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: configuration.isPressed ? 0.06 : 0.14), value: configuration.isPressed)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .onChange(of: configuration.isPressed) { _, pressed in
                    if pressed && enabled && !reduceMotion {
                        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                    }
                }
        }

        private var fillColor: Color {
            guard enabled else { return .clear }
            if colorScheme == .dark {
                if configuration.isPressed { return Color.white.opacity(0.18) }
                return hovered ? Color.white.opacity(0.12) : .clear
            } else {
                if configuration.isPressed { return Color.black.opacity(0.10) }
                return hovered ? Color.black.opacity(0.06) : .clear
            }
        }

        private var borderColor: Color {
            guard enabled else { return .clear }
            if colorScheme == .dark {
                if configuration.isPressed { return Color.white.opacity(0.15) }
                return hovered ? Color.white.opacity(0.12) : .clear
            } else {
                if configuration.isPressed { return Color.white.opacity(0.35) }
                return hovered ? Color.white.opacity(0.60) : .clear
            }
        }
    }
}

private struct PanelGlassControl<Outline: Shape>: ViewModifier {
    let outline: Outline
    let tint: Color?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled

    func body(content: Content) -> some View {
        content.glassEffect(.regular.tint(tint).interactive(enabled && !reduceMotion), in: outline)
    }
}

private struct PanelSecondaryText: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.foregroundStyle(Color.primary.opacity(reduceTransparency || contrast == .increased ? 1 : 0.80))
    }
}

extension View {
    func panelGlassControl<Outline: Shape>(in outline: Outline, tint: Color? = nil) -> some View {
        modifier(PanelGlassControl(outline: outline, tint: tint))
    }

    func panelSecondaryText() -> some View {
        modifier(PanelSecondaryText())
    }
}
