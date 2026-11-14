// Copyright 2026 lingyired
// SPDX-License-Identifier: Apache-2.0
// Adapted from Status Trio v1.9.5, Sources/StatusTrioCore/UI/Icon/StatusIconGeometry.swift.
// TrioRing retains the static artwork and omits geometry used by other presentations.
import CoreGraphics

enum StatusIconGeometry {

    static let canvas = CGRect(x: 0, y: 0, width: 120, height: 120)

    static let artworkCenterX: CGFloat = 59.5

    // Derived from the SVG battery endpoints and radius.
    private static let batteryRadius: CGFloat = 51.5
    /// Vertical centre of the battery ring. The centre slot shares it so the
    /// glyph sits on the circle's centre instead of slightly below it.
    static let batteryCenterY: CGFloat = 61.48715261785473
    private static let batteryCenter = CGPoint(x: artworkCenterX, y: batteryCenterY)
    private static let batteryStart: CGFloat = 148.69008689281117 * .pi / 180
    private static let batterySweep: CGFloat = 242.6198262143777 * .pi / 180
    static let batteryValueTopGapWidth: CGFloat = 64
    static let batteryChargingBoltTopGapWidth: CGFloat = 50

    static let batteryValueBaseFontSize: CGFloat = 20
    static let batteryChargingBoltCalibration: CGFloat = 220.0 / 180.0

    static let batteryPlugHeightScale: CGFloat = 1.2

    /// The top-gap accessory shares the artwork centre axis. Only its vertical
    /// position follows the bolt's scaling; horizontally it is pinned to
    /// `artworkCenterX`, so neither the plug nor a fallback glyph inherits the
    /// bolt's asymmetric bounding box — which sits ~0.05 units left of centre and
    /// would otherwise drift further left as the glyph is scaled up (Issue #30
    /// top accessory: "插头看着偏左").
    static func batteryTopIndicatorCenter(boltScale: CGFloat) -> CGPoint {
        let bolt = batteryChargingBolt().boundingBoxOfPath
        let pivot = batteryChargingBoltPivot
        return CGPoint(
            x: artworkCenterX,
            y: pivot.y + (bolt.midY - pivot.y) * boltScale
        )
    }

    static func batteryValueBaseline(fontSize: CGFloat) -> CGPoint {
        let referenceFontSize: CGFloat = 20
        let referenceBaseline: CGFloat = 17
        let currentFontSize: CGFloat = 32
        let currentBaseline: CGFloat = 24
        let slope = (currentBaseline - referenceBaseline) / (currentFontSize - referenceFontSize)
        return CGPoint(
            x: artworkCenterX,
            y: referenceBaseline + (fontSize - referenceFontSize) * slope
        )
    }

    static func batteryTrack(
        hasTopGap: Bool = false,
        topGapWidth: CGFloat = batteryChargingBoltTopGapWidth
    ) -> CGPath {
        batteryArc(
            from: 0,
            to: 1,
            hasTopGap: hasTopGap,
            topGapWidth: topGapWidth
        )
    }

    static func batteryFill(
        progress: Double,
        hasTopGap: Bool = false,
        topGapWidth: CGFloat = batteryChargingBoltTopGapWidth
    ) -> CGPath {
        batteryArc(
            from: 0,
            to: progress,
            hasTopGap: hasTopGap,
            topGapWidth: topGapWidth
        )
    }


    // The occupied top gap carries no progress in split mode.
    static func splitFillProgress(_ progress: Double, topGapWidth: CGFloat) -> Double {
        let fraction = clampedUnit(progress)
        let gap = batteryGapFraction(topGapWidth: topGapWidth)
        let visible = fraction * (1 - gap)
        return fraction > 0.5 ? visible + gap : visible
    }

    private static func clampedUnit(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private static func batteryGapFraction(topGapWidth: CGFloat) -> Double {
        guard topGapWidth.isFinite, topGapWidth > 0 else { return 0 }
        let arcLength = batteryRadius * batterySweep
        guard arcLength.isFinite, arcLength > 0 else { return 0 }
        return min(1, max(0, Double(topGapWidth / arcLength)))
    }

    static func batteryChargingBolt(scale: CGFloat = 1) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 62.1, y: 2.2))
        path.addQuadCurve(
            to: CGPoint(x: 62.6, y: 3.3),
            control: CGPoint(x: 62.8, y: 2.5)
        )
        path.addLine(to: CGPoint(x: 61.2, y: 7.8))
        path.addLine(to: CGPoint(x: 65.9, y: 7.8))
        path.addQuadCurve(
            to: CGPoint(x: 67.3, y: 8.6),
            control: CGPoint(x: 66.9, y: 7.8)
        )
        path.addQuadCurve(
            to: CGPoint(x: 67, y: 10),
            control: CGPoint(x: 67.6, y: 9.3)
        )
        path.addLine(to: CGPoint(x: 57, y: 21.3))
        path.addQuadCurve(
            to: CGPoint(x: 55.6, y: 21.6),
            control: CGPoint(x: 56.4, y: 22)
        )
        path.addQuadCurve(
            to: CGPoint(x: 55.3, y: 20.5),
            control: CGPoint(x: 55, y: 21.3)
        )
        path.addLine(to: CGPoint(x: 57.4, y: 14.1))
        path.addLine(to: CGPoint(x: 52.9, y: 14.1))
        path.addQuadCurve(
            to: CGPoint(x: 51.6, y: 13.3),
            control: CGPoint(x: 52, y: 14.1)
        )
        path.addQuadCurve(
            to: CGPoint(x: 51.9, y: 12),
            control: CGPoint(x: 51.3, y: 12.6)
        )
        path.addLine(to: CGPoint(x: 61.1, y: 2.7))
        path.addQuadCurve(
            to: CGPoint(x: 62.1, y: 2.2),
            control: CGPoint(x: 61.6, y: 2.1)
        )
        path.closeSubpath()

        guard scale.isFinite, scale > 0, scale != 1 else { return path }
        let pivot = batteryChargingBoltPivot
        var transform = CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: pivot.x * (1 - scale),
            ty: pivot.y * (1 - scale)
        )
        return path.copy(using: &transform) ?? path
    }


    static let batteryChargingBoltPivot = CGPoint(x: artworkCenterX, y: 2.1)

    static let ethernetStrokeWidth: CGFloat = 4.886659979939819
    static let ethernetDotRadius: CGFloat = 2.4433299899699095

    private static let ethernetSourceBounds = CGRect(
        x: 56.132,
        y: 75.812,
        width: 87.736,
        height: 46.376
    )
    private static let ethernetTargetBounds = CGRect(
        x: 31.5,
        y: 51.19959879638917,
        width: 56,
        height: 29.60080240722166
    )

    static func ethernetChevrons() -> [CGPath] {
        let left = ethernetPolyline([
            CGPoint(x: 79.32, y: 79.64),
            CGPoint(x: 59.96, y: 99),
            CGPoint(x: 79.32, y: 118.36)
        ])
        let right = ethernetPolyline([
            CGPoint(x: 120.68, y: 79.64),
            CGPoint(x: 140.04, y: 99),
            CGPoint(x: 120.68, y: 118.36)
        ])
        return [left, right]
    }

    static func ethernetDots() -> [CGPoint] {
        [
            ethernetPoint(x: 84.688, y: 99),
            ethernetPoint(x: 100, y: 99),
            ethernetPoint(x: 115.312, y: 99)
        ]
    }

    private static func ethernetPolyline(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: ethernetPoint(x: first.x, y: first.y))
        for point in points.dropFirst() {
            path.addLine(to: ethernetPoint(x: point.x, y: point.y))
        }
        return path
    }

    private static func ethernetPoint(x: CGFloat, y: CGFloat) -> CGPoint {
        let scaleX = ethernetTargetBounds.width / ethernetSourceBounds.width
        let scaleY = ethernetTargetBounds.height / ethernetSourceBounds.height
        return CGPoint(
            x: ethernetTargetBounds.minX + (x - ethernetSourceBounds.minX) * scaleX,
            y: ethernetTargetBounds.minY + (y - ethernetSourceBounds.minY) * scaleY
        )
    }


    static func volumeDots() -> [CGPoint] {
        [
            CGPoint(x: 33, y: 104.2),
            CGPoint(x: 50.5, y: 111.2),
            CGPoint(x: 68.5, y: 111.7),
            CGPoint(x: 86, y: 105.8)
        ]
    }

    static let volumeDotRadius: CGFloat = 5.5

    static let volumeArcStartAngle: CGFloat = 121.82 * .pi / 180
    static let volumeArcEndAngle: CGFloat = 59.12 * .pi / 180

    static func volumeArcTrack() -> CGPath {
        let path = CGMutablePath()
        path.addArc(
            center: batteryCenter,
            radius: batteryRadius,
            startAngle: volumeArcStartAngle,
            endAngle: volumeArcEndAngle,
            clockwise: true
        )
        return path
    }

    static func volumeArcFill(progress: Double) -> CGPath {
        let clamped = min(1, max(0, progress))
        guard clamped > 0 else { return CGMutablePath() }
        let sweep = volumeArcStartAngle - volumeArcEndAngle
        let end = volumeArcStartAngle - sweep * CGFloat(clamped)
        let path = CGMutablePath()
        path.addArc(
            center: batteryCenter,
            radius: batteryRadius,
            startAngle: volumeArcStartAngle,
            endAngle: end,
            clockwise: true
        )
        return path
    }

    static func batteryArc(
        from start: Double,
        to end: Double,
        hasTopGap: Bool,
        topGapWidth: CGFloat
    ) -> CGPath {
        guard start.isFinite, end.isFinite else { return CGMutablePath() }
        let clampedStart = clampedUnit(start)
        let clampedEnd = clampedUnit(end)
        guard clampedEnd > clampedStart else { return CGMutablePath() }

        let path = CGMutablePath()
        guard hasTopGap else {
            path.addPath(arc(
                center: batteryCenter,
                radius: batteryRadius,
                start: batteryStart + batterySweep * CGFloat(clampedStart),
                end: batteryStart + batterySweep * CGFloat(clampedEnd)
            ))
            return path
        }

        let gapFraction = batteryGapFraction(topGapWidth: topGapWidth)
        let gapStartProgress = (1 - gapFraction) / 2
        let gapEndProgress = gapStartProgress + gapFraction

        let firstSegmentEnd = min(clampedEnd, gapStartProgress)
        if firstSegmentEnd > clampedStart {
            path.addPath(arc(
                center: batteryCenter,
                radius: batteryRadius,
                start: batteryStart + batterySweep * CGFloat(clampedStart),
                end: batteryStart + batterySweep * CGFloat(firstSegmentEnd)
            ))
        }

        let secondSegmentStart = max(clampedStart, gapEndProgress)
        if clampedEnd > secondSegmentStart {
            path.addPath(arc(
                center: batteryCenter,
                radius: batteryRadius,
                start: batteryStart + batterySweep * CGFloat(secondSegmentStart),
                end: batteryStart + batterySweep * CGFloat(clampedEnd)
            ))
        }
        return path
    }

    private static func arc(
        center: CGPoint,
        radius: CGFloat,
        start: CGFloat,
        end: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        return path
    }
    private static let wifiOuterCenter = CGPoint(x: artworkCenterX, y: 78.3)
    private static let wifiOuterRadius: CGFloat = 31
    private static let wifiOuterStart: CGFloat = 227.35 * .pi / 180
    private static let wifiOuterEnd: CGFloat = 312.65 * .pi / 180
    static func wifiArcs(level: Int) -> [CGPath] {
        let bars = min(3, max(0, level))
        let middle = arc(
            center: CGPoint(x: artworkCenterX, y: 78.89),
            radius: 18.5,
            start: 227.5 * .pi / 180,
            end: 312.5 * .pi / 180
        )

        switch bars {
        case 3:
            return [wifiOuterArc(), middle]
        case 2:
            return [middle]
        case 1:
            // Level 1 intentionally returns no arcs because the dot is drawn separately.
            return []
        default:
            return []
        }
    }

    static func wifiOuterArc() -> CGPath {
        arc(
            center: wifiOuterCenter,
            radius: wifiOuterRadius,
            start: wifiOuterStart,
            end: wifiOuterEnd
        )
    }

    static func wifiDot() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: artworkCenterX, y: 69.9))
        path.addCurve(to: CGPoint(x: 66.5, y: 73), control1: CGPoint(x: 61.0, y: 69.9), control2: CGPoint(x: 65.2, y: 70.8))
        path.addCurve(to: CGPoint(x: 66.5, y: 75), control1: CGPoint(x: 66.7, y: 73.8), control2: CGPoint(x: 66.7, y: 74.3))
        path.addCurve(to: CGPoint(x: artworkCenterX, y: 80.95), control1: CGPoint(x: 63.8, y: 78.8), control2: CGPoint(x: 61.15, y: 80.95))
        path.addCurve(to: CGPoint(x: 52.5, y: 75), control1: CGPoint(x: 57.85, y: 80.95), control2: CGPoint(x: 55.2, y: 78.8))
        path.addCurve(to: CGPoint(x: 52.5, y: 73), control1: CGPoint(x: 52.3, y: 74.3), control2: CGPoint(x: 52.3, y: 73.8))
        path.addCurve(to: CGPoint(x: artworkCenterX, y: 69.9), control1: CGPoint(x: 53.8, y: 70.8), control2: CGPoint(x: 58.0, y: 69.9))
        path.closeSubpath()
        return path
    }

}
