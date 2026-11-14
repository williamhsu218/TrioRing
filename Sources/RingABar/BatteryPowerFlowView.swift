// Adapted from Status Trio v1.9.5, Copyright 2026 lingyired (Apache-2.0).
import SwiftUI

/// A static flow diagram: sampling changes the numbers and ribbon widths, with
/// no animation clock, Canvas loop, or work while the panel is closed.
struct BatteryPowerFlowView: View {
    @Environment(\.colorScheme) private var colorScheme
    let state: BatteryPowerFlowState

    private var destinations: [BatteryPowerFlowState.Metric] { state.destinations }
    /// Extra breathing room above and below the branch column.
    private let topPadding: CGFloat = 2

    /// Power share belongs to the ribbons, not the text layout. Keeping every
    /// node readable also prevents live samples from moving the controls below.
    static let branchRowHeight: CGFloat = 54
    private static let inputCardWidth: CGFloat = 84
    private static let branchCardWidth: CGFloat = 118
    private static let rowGap: CGFloat = 6
    /// The input card holds one number and its label, so it stays a small node;
    /// the branch column is allowed to grow taller than it.
    private static let inputCardHeight: CGFloat = 84
    /// The ribbon bundle is centred in the input card with a 5% margin above
    /// and below, so it reads as one stream leaving the middle of the card.
    private static let bundleInset: CGFloat = 0.05
    /// The panel chrome is transparent Liquid Glass, so the previous very light
    /// fills (0.045–0.08) vanished over a bright or colourful desktop. These
    /// fills and rims keep each node and ribbon legible without hiding the glass.
    /// The input chip shares the outer power bar's styling through
    /// `PowerCardSurface` (silver fill and rim, radius 12), so the two "charger
    /// input" cards read the same in both appearances.
    private static let cardFill: Double = 0.18
    private static let cardStroke: Double = 0.32
    private static let ribbonFillStart: Double = 0.22
    private static let ribbonFillEnd: Double = 0.62

    /// Height is a function of branch count only, never of fluctuating watts.
    private var columnHeight: CGFloat {
        guard !destinations.isEmpty else { return 0 }
        return Self.branchRowHeight * CGFloat(destinations.count)
            + Self.rowGap * CGFloat(destinations.count - 1)
    }

    var diagramHeight: CGFloat {
        switch destinations.count {
        case 0, 1: return Self.inputCardHeight
        default: return topPadding * 2 + max(Self.inputCardHeight, columnHeight)
        }
    }

    private func centerY(_ index: Int) -> CGFloat {
        let top = (diagramHeight - columnHeight) / 2
        return top + CGFloat(index) * (Self.branchRowHeight + Self.rowGap) + Self.branchRowHeight / 2
    }

    private struct Ribbon: Identifiable {
        let id: Int
        let startY: CGFloat
        let endY: CGFloat
        let thickness: CGFloat
        let endThickness: CGFloat
        let color: Color
    }

    /// Ribbons leave the input card as one bundle that fills it, so the left
    /// edge reads as a single stream. Every branch that carries power gets a
    /// minimum width and the rest of the bundle is shared by the branches'
    /// percentages; a band that would cross into a neighbour is trimmed and the
    /// trimmed height goes to the bands that still have room.
    private func ribbons() -> [Ribbon] {
        let count = destinations.count
        guard count > 0 else { return [] }
        let fractions = destinations.map {
            max(0, state.flowFraction(for: $0).map { CGFloat($0) } ?? 0)
        }
        let total = fractions.reduce(0, +)
        let bundleHeight = Self.inputCardHeight * (1 - 2 * Self.bundleInset)
        let top = diagramHeight / 2 - bundleHeight / 2
        let live = destinations.indices.filter { fractions[$0] > 0 }
        guard total > 0 else { return [] }
        let minimum = min(CGFloat(6), bundleHeight / CGFloat(live.count))
        var thicknesses = Array(repeating: CGFloat.zero, count: count)
        var remaining = bundleHeight
        var pending = live
        // Apply the lower bound only to small shares; preserve proportional
        // allocation among all branches that remain above it.
        while !pending.isEmpty {
            let weight = pending.reduce(CGFloat.zero) { $0 + fractions[$1] }
            let small = pending.filter { remaining * fractions[$0] / weight < minimum }
            if small.isEmpty {
                for index in pending { thicknesses[index] = remaining * fractions[index] / weight }
                break
            }
            for index in small { thicknesses[index] = minimum; remaining -= minimum }
            pending.removeAll { small.contains($0) }
        }
        var offset = top
        return live.map { index in
            let thickness = thicknesses[index]
            let startY = offset + thickness / 2
            offset += thickness
            // The source keeps the branch's full share; only the end is tapered
            // to fit its card, so a dominant branch does not shrink the others.
            let endThickness = min(thickness, max(0, Self.branchRowHeight - 8))
            return Ribbon(id: index, startY: startY, endY: centerY(index),
                          thickness: thickness, endThickness: endThickness,
                          color: Self.color(for: destinations[index].kind))
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            // Nodes reserve space for permanent labels. Ribbons continue underneath their
            // original rounded outlines; the mask below cuts out card interiors
            // so the overlap cannot show through their translucent fills.
            let left: CGFloat = state.input == nil
                ? 0
                : PowerFlowCardGeometry.ribbonStartX(inputCardRight: Self.inputCardWidth)
            let right = PowerFlowCardGeometry.ribbonEndX(branchCardLeft: width - Self.branchCardWidth)
            let center = diagramHeight / 2
            // A ribbon at or below the drawing floor is not drawn.
            let liveRibbons = (state.input != nil && !destinations.isEmpty)
                ? ribbons().filter { $0.thickness > PowerFlowCardGeometry.liveThreshold }
                : []
            // Mask the ribbon layer with the exact card silhouettes. Drawing
            // the translucent cards above it is not enough to hide the overlap.
            let inputFrame = CGRect(x: 0, y: center - Self.inputCardHeight / 2,
                                    width: Self.inputCardWidth, height: Self.inputCardHeight)
            let branchFrames = destinations.indices.map { index in
                CGRect(x: width - Self.branchCardWidth, y: centerY(index) - Self.branchRowHeight / 2,
                       width: Self.branchCardWidth, height: Self.branchRowHeight)
            }
            ZStack {
                ForEach(liveRibbons) { item in
                    ribbon(from: left, to: right, startY: item.startY, endY: item.endY,
                           thickness: item.thickness, endThickness: item.endThickness, color: item.color)
                }
            }
            .frame(width: width, height: diagramHeight)
            .mask {
                PowerFlowRibbonMask(cardFrames: [inputFrame] + branchFrames)
                    .fill(style: FillStyle(eoFill: true))
            }
            if let input = state.input {
                // The source node is the adapter (plug, primary) unless the pack
                // is discharging, in which case it takes the outer bar's
                // discharging card style (plain battery, orange).
                let inputColor = Self.color(for: input.kind)
                let inputSurface = Self.surface(for: input.kind)
                metric(input, symbol: Self.symbol(for: input.kind), color: inputColor,
                       height: Self.inputCardHeight,
                       iconSize: Self.iconSize(for: input.kind),
                       iconLeading: false)
                    .frame(width: destinations.isEmpty ? width : Self.inputCardWidth)
                    // `Self.color(for:)` returns the explicit `.primary` colour,
                    // not a bare `.primary` shape style: the leading-dot form
                    // resolves to the hierarchical foreground, follows the vibrant
                    // detail-page text and nearly vanishes over the glass.
                    .powerFlowCardSurface(
                        fill: inputSurface.fill(tint: inputColor, scheme: colorScheme),
                        stroke: inputSurface.stroke(tint: inputColor, scheme: colorScheme)
                    )
                    .position(x: destinations.isEmpty ? width / 2 : Self.inputCardWidth / 2, y: center)
            }
            ForEach(Array(destinations.enumerated()), id: \.offset) { index, item in
                metric(item, symbol: Self.symbol(for: item.kind),
                       color: Self.color(for: item.kind), height: Self.branchRowHeight,
                       iconSize: Self.iconSize(for: item.kind))
                    .frame(width: state.input == nil ? width : Self.branchCardWidth)
                    .powerFlowCardSurface(
                        fill: Self.color(for: item.kind).opacity(Self.cardFill),
                        stroke: Self.color(for: item.kind).opacity(Self.cardStroke)
                    )
                    .position(x: state.input == nil ? width / 2 : width - Self.branchCardWidth / 2, y: centerY(index))
            }
        }
        .frame(height: diagramHeight)
    }

    private static func symbol(for kind: BatteryPowerFlowState.Kind) -> String {
        switch kind {
        case .input: return "powerplug.fill"
        // The pack as the source: plain battery, matching the outer bar's
        // discharging card (only charging carries the bolt).
        case .batterySource: return "battery.100"
        case .charging: return "battery.100.bolt"
        case .display: return "display"
        case .usb: return "cable.connector"
        case .system: return "cpu"
        }
    }

    private static func color(for kind: BatteryPowerFlowState.Kind) -> Color {
        switch kind {
        case .input: return .primary
        // Same orange as the outer power bar's discharging battery card.
        case .batterySource: return .orange
        case .charging: return .green
        case .display: return .indigo
        case .usb: return .orange
        case .system: return .blue
        }
    }

    /// The input card's surface: the shared silver while the adapter supplies
    /// power, and the input-card tint wash (not the branch cards' slightly
    /// heavier rim) when the pack is the source instead.
    static func surface(for kind: BatteryPowerFlowState.Kind) -> PowerCardSurface {
        switch kind {
        case .input: return .silver(.connected)
        case .batterySource, .charging, .display, .usb, .system:
            return .tint(fillOpacity: 0.18, strokeOpacity: 0.3)
        }
    }

    /// SF Symbols do not share one optical weight: the battery glyph reads
    /// larger than the display and connector glyphs at the same point size.
    private static func iconSize(for kind: BatteryPowerFlowState.Kind) -> CGFloat {
        switch kind {
        case .input: return 15
        case .batterySource: return 13
        case .charging: return 12
        case .display, .usb, .system: return 13
        }
    }

    private func metric(_ value: BatteryPowerFlowState.Metric, symbol: String,
                        color: Color, height: CGFloat, iconSize: CGFloat = 14,
                        iconLeading: Bool = true) -> some View {
        VStack(spacing: iconLeading ? 2 : 3) {
            if iconLeading {
                HStack(spacing: 6) {
                    Image(systemName: symbol)
                        .foregroundStyle(color)
                        .font(.system(size: iconSize, weight: .medium))
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    metricValue(value.value)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .font(.system(size: 16, weight: .medium))
                    .accessibilityHidden(true)
                metricValue(value.value)
            }
            Text(value.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            if let detail = value.detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(value) + ": " + value.value)
        .help(accessibilityText(value))
    }

    private func metricValue(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.9)
    }

    private func accessibilityText(_ value: BatteryPowerFlowState.Metric) -> String {
        let base = value.help ?? value.label
        return value.detail.map { "\(base) · \($0)" } ?? base
    }

    private func ribbon(from start: CGFloat, to end: CGFloat, startY: CGFloat,
                        endY: CGFloat, thickness: CGFloat?, endThickness: CGFloat, color: Color) -> some View {
        let thickness = max(0, thickness ?? 0)
        return Path { path in
            let control = (end - start) * 0.5
            path.move(to: CGPoint(x: start, y: startY - thickness / 2))
            path.addCurve(to: CGPoint(x: end, y: endY - endThickness / 2),
                control1: CGPoint(x: start + control, y: startY - thickness / 2),
                control2: CGPoint(x: end - control, y: endY - endThickness / 2))
            path.addLine(to: CGPoint(x: end, y: endY + endThickness / 2))
            path.addCurve(to: CGPoint(x: start, y: startY + thickness / 2),
                control1: CGPoint(x: end - control, y: endY + endThickness / 2),
                control2: CGPoint(x: start + control, y: startY + thickness / 2))
            path.closeSubpath()
        }
        .fill(LinearGradient(colors: [color.opacity(Self.ribbonFillStart), color.opacity(Self.ribbonFillEnd)],
            startPoint: .leading, endPoint: .trailing))
        .accessibilityHidden(true)
    }
}
