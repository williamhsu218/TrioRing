// Portions adapted from Status Trio v1.9.5 by lingyired (Apache-2.0).
// TrioRing uses the upstream static drawing rules with its own status model.
import AppKit
import CoreText

struct StatusIcon: Equatable {
    var size: CGFloat { CGFloat(preferences.menuBarSize) }

    private enum Marker: Equatable {
        case none, number(Int), bolt, plug

        var gapWidth: CGFloat {
            switch self {
            case .none: 0
            case .number: StatusIconGeometry.batteryValueTopGapWidth
            case .bolt, .plug: StatusIconGeometry.batteryChargingBoltTopGapWidth
            }
        }
    }

    private struct Glyph: Hashable {
        let name: String
        var value = 1.0
        var pointSize = 38.0 * 1.6
        var dimmed = false
    }

    private struct SymbolImage {
        let image: NSImage
        let inkOffset: CGFloat
    }

    private enum Center: Equatable {
        case empty, wired
        case text(String)
        case glyph(Glyph)
    }

    private let ringLevel: Double
    private let marker: Marker
    private let batteryAccent: BatteryAccent?
    private let center: Center
    private let volume: Double
    private let preferences: IconPreferences

    private let blueVolume: Bool

    init(battery: BatteryStatus, network: NetworkStatus, audio: AudioStatus, preferences: IconPreferences,
         inputSource: String? = nil, systemWatts: Int? = nil) {
        self.preferences = preferences
        if preferences.usesBatteryColors, let reading = battery.reading {
            if reading.percent < preferences.criticalLevel {
                batteryAccent = .critical
            } else if reading.lowPower {
                batteryAccent = .lowPower
            } else {
                batteryAccent = reading.charging && !preferences.monochromeCharging ? .charging : nil
            }
        } else {
            batteryAccent = nil
        }

        switch battery {
        case .unavailable:
            ringLevel = 0
            marker = .none
        case .noBattery:
            ringLevel = 1
            marker = Self.marker(preferences.noBatteryMarker, percent: nil)
        case let .battery(reading):
            ringLevel = Double(reading.percent) / 100
            let selection = reading.charging ? preferences.chargingMarker
                : reading.pluggedIn ? preferences.connectedMarker : preferences.onBatteryMarker
            marker = Self.marker(selection, percent: reading.percent)
        }

        let middleSize = Double(preferences.middleSize) * 0.38
        func glyph(_ name: String, value: Double = 1, dimmed: Bool = false) -> Center {
            .glyph(Glyph(name: name, value: value, pointSize: middleSize, dimmed: dimmed))
        }
        let path = network.effectivePath
        let source = preferences.prioritizesNetworkWarnings && path == .offline ? .network : preferences.middleSource
        switch source {
        case .bluetooth:
            center = audio.isBluetooth ? glyph(audio.deviceSymbol) : glyph("headphones", dimmed: true)
        case .inputSource:
            center = inputSource.map(Center.text) ?? .empty
        case .batteryPercentage:
            center = battery.percent.map { .text(String($0)) } ?? .empty
        case .power:
            center = systemWatts.map { .text(String($0)) } ?? .empty
        case .chargingStatus:
            center = glyph(battery.reading?.charging == true ? "bolt.fill" : battery.symbol)
        case .network:
            switch path {
            case .wifi:
                if network.wifiIsHotspot && !preferences.showsWiFiForHotspot {
                    center = glyph("personalhotspot")
                } else {
                    let bars = WiFiSignalStrength.bars(for: network.signalDBm)
                    center = glyph("wifi", value: WiFiSignalStrength.variableValue(for: network.signalDBm),
                                   dimmed: network.signalDBm != nil && bars == 0)
                }
            case .ethernet:
                center = preferences.showsWiFiForWired ? glyph("wifi") : .wired
            case .offline:
                center = glyph("wifi.slash")
            case .unknown:
                center = glyph("wifi", value: 0, dimmed: true)
            case .other:
                center = glyph("network")
            case .tunnel:
                center = glyph("point.3.connected.trianglepath.dotted")
            }
        }

        let level = audio.muted == true ? 0 : min(1, max(0, audio.volume ?? 0))
        volume = preferences.volumeIndicator == .dots ? (level * 4).rounded(.up) / 4 : level
        blueVolume = volume > 0 && audio.isBluetooth && preferences.usesBlueForBluetoothVolume
    }

    private static func marker(_ selection: TopMarker, percent: Int?) -> Marker {
        switch selection {
        case .percentage: percent.map(Marker.number) ?? .none
        case .bolt: .bolt
        case .plug: .plug
        case .hidden: .none
        }
    }

    enum Layer {
        case template, accent, preview
    }

    private struct SymbolOffsetKey: Hashable {
        let name: String
        let value: Double
    }

    private static let inactiveAlpha: CGFloat = 0.22
    private static let centerAnchor = CGPoint(x: StatusIconGeometry.artworkCenterX, y: StatusIconGeometry.batteryCenterY)
    private static let textSize = StatusIconGeometry.batteryValueBaseFontSize * 1.8
    private static let inkReferencePointSize: CGFloat = 100

    @MainActor private static var normalizedSymbolOffsets: [SymbolOffsetKey: CGFloat] = [:]

    @MainActor static var cachedInkOffsetCount: Int { normalizedSymbolOffsets.count }
    @MainActor static func resetInkOffsetCache() { normalizedSymbolOffsets.removeAll() }

    @MainActor
    func image(size overrideSize: CGFloat? = nil, layer: Layer, previewForeground: NSColor? = nil) -> NSImage? {
        if layer == .accent, batteryAccent == nil, !blueVolume { return nil }
        let size = overrideSize ?? self.size
        let markerScale = CGFloat(preferences.markerSize) / 100
        let foreground = layer == .preview ? (previewForeground ?? .labelColor) : .black
        let centerSymbol: SymbolImage?
        if layer != .accent, case let .glyph(glyph) = center {
            centerSymbol = Self.symbol(glyph, color: foreground)
        } else {
            centerSymbol = nil
        }
        let plug = layer != .accent && marker == .plug ? Self.plug(color: foreground, scale: markerScale) : nil
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            let scale = size / StatusIconGeometry.canvas.width
            context.translateBy(x: 0, y: size)
            context.scaleBy(x: scale, y: -scale)
            context.setLineCap(.round)
            context.setLineJoin(.round)

            let ink = foreground.cgColor
            let inactive = ink.copy(alpha: Self.inactiveAlpha) ?? ink
            let gap = marker.gapWidth
            let stroke = preferences.ringWeight.scale
            if layer != .accent {
                Self.stroke(StatusIconGeometry.batteryTrack(hasTopGap: gap > 0, topGapWidth: gap), width: 8 * stroke, color: inactive, in: context)
            }
            if layer == .preview || (layer == .accent) == (batteryAccent != nil) {
                let fill = batteryAccent.map { Self.color(for: $0).cgColor } ?? ink
                let progress = preferences.splitsProgress
                    ? StatusIconGeometry.splitFillProgress(ringLevel, topGapWidth: gap) : ringLevel
                Self.stroke(StatusIconGeometry.batteryFill(progress: progress, hasTopGap: gap > 0, topGapWidth: gap),
                            width: 8 * stroke, color: fill, in: context)
            }
            drawVolume(foreground: ink, inactive: inactive, layer: layer, in: context)
            guard layer != .accent else { return true }

            drawMarker(plug: plug, color: ink, in: context)
            if let centerSymbol {
                Self.drawSymbol(centerSymbol, at: Self.centerAnchor, in: context)
            } else if center == .wired {
                drawWired(color: ink, in: context)
            }
            if case let .text(text) = center {
                Self.drawCenterText(text, size: CGFloat(preferences.middleSize) * 0.31, color: foreground, in: context)
            }
            return true
        }
        image.isTemplate = layer == .template
        return image
    }

    private static func color(for accent: BatteryAccent) -> NSColor {
        switch accent {
        case .charging: .systemGreen
        case .lowPower: .systemYellow
        case .critical: .systemRed
        }
    }

    private func drawMarker(plug: SymbolImage?, color: CGColor, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setShadow(offset: CGSize(width: 0, height: 0.75), blur: 0.75, color: CGColor(gray: 0, alpha: 0.38))
        let scale = CGFloat(preferences.markerSize) / 100
        switch marker {
        case .none:
            break
        case let .number(number):
            let size = Self.textSize * scale
            let line = Self.numberLine(String(number), size: size, color: NSColor(cgColor: color) ?? .labelColor)
            let baseline = StatusIconGeometry.batteryValueBaseline(fontSize: size)
            let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: baseline.x - bounds.midX, y: baseline.y)
            CTLineDraw(line, context)
        case .bolt:
            context.setFillColor(batteryAccent == .charging ? NSColor.systemGreen.cgColor : color)
            context.addPath(StatusIconGeometry.batteryChargingBolt(scale: Self.boltScale * scale))
            context.fillPath()
        case .plug:
            if let plug {
                Self.drawSymbol(plug, at: StatusIconGeometry.batteryTopIndicatorCenter(boltScale: Self.boltScale * scale), in: context)
            }
        }
    }

    private func drawWired(color: CGColor, in context: CGContext) {
        let scale = CGFloat(preferences.middleSize) / 160
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: Self.centerAnchor.x * (1 - scale), y: Self.centerAnchor.y * (1 - scale))
        context.scaleBy(x: scale, y: scale)
        for path in StatusIconGeometry.ethernetChevrons() {
            Self.stroke(path, width: StatusIconGeometry.ethernetStrokeWidth, color: color, in: context)
        }
        for point in StatusIconGeometry.ethernetDots() {
            Self.dot(at: point, radius: StatusIconGeometry.ethernetDotRadius, color: color, in: context)
        }
    }

    private func drawVolume(foreground: CGColor, inactive: CGColor, layer: Layer, in context: CGContext) {
        let scale = preferences.ringWeight.scale
        let drawsActive = layer == .preview || (layer == .accent) == blueVolume
        let active = blueVolume ? NSColor.systemBlue.cgColor : foreground
        switch preferences.volumeIndicator {
        case .dots:
            let radius = StatusIconGeometry.volumeDotRadius * (1 + (scale - 1) * 0.5)
            for (index, point) in StatusIconGeometry.volumeDots().enumerated() {
                if Double(index) < volume * 4 {
                    if drawsActive { Self.dot(at: point, radius: radius, color: active, in: context) }
                } else if layer != .accent {
                    Self.dot(at: point, radius: radius, color: inactive, in: context)
                }
            }
        case .arc:
            if layer != .accent {
                Self.stroke(StatusIconGeometry.volumeArcTrack(), width: 7 * scale, color: inactive, in: context)
            }
            if drawsActive {
                Self.stroke(StatusIconGeometry.volumeArcFill(progress: volume), width: 7 * scale, color: active, in: context)
            }
        }
    }

    private static func drawCenterText(_ text: String, size: CGFloat, color: NSColor, in context: CGContext) {
        var line = numberLine(text, size: size, color: color)
        var bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let maxWidth: CGFloat = 72
        if bounds.width > maxWidth {
            line = numberLine(text, size: size * maxWidth / bounds.width, color: color)
            bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        }
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: centerAnchor.x - bounds.midX, y: centerAnchor.y + bounds.midY)
        CTLineDraw(line, context)
    }

    private static func stroke(_ path: CGPath, width: CGFloat, color: CGColor, in context: CGContext) {
        context.setLineWidth(width)
        context.setStrokeColor(color)
        context.addPath(path)
        context.strokePath()
    }

    private static func dot(at point: CGPoint, radius: CGFloat, color: CGColor, in context: CGContext) {
        context.setFillColor(color)
        context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius))
    }

    private static func numberLine(_ text: String, size textSize: CGFloat = Self.textSize, color: NSColor) -> CTLine {
        let base = NSFont.systemFont(ofSize: textSize, weight: .bold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: textSize) } ?? base
        return CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [.font: font, .kern: -textSize * 0.04, .foregroundColor: color]
        ))
    }

    private static let boltScale: CGFloat = {
        let height = CTLineGetBoundsWithOptions(numberLine("100", color: .black), [.useGlyphPathBounds]).height
        let boltHeight = StatusIconGeometry.batteryChargingBolt().boundingBoxOfPath.height
        return height / boltHeight * StatusIconGeometry.batteryChargingBoltCalibration
    }()

    @MainActor
    private static func plug(color: NSColor, scale: CGFloat) -> SymbolImage? {
        let name = NSImage(systemSymbolName: "powerplug.portrait.fill", accessibilityDescription: nil) == nil
            ? "powerplug.fill" : "powerplug.portrait.fill"
        let targetHeight = StatusIconGeometry.batteryChargingBolt(scale: boltScale).boundingBoxOfPath.height
            * StatusIconGeometry.batteryPlugHeightScale
        let referenceHeight = configuredImage(Glyph(name: name, pointSize: 200), color: .black)?.size.height ?? 268
        return symbol(Glyph(name: name, pointSize: targetHeight / referenceHeight * 200 * scale), color: color)
    }

    private static func configuredImage(_ glyph: Glyph, color: NSColor) -> NSImage? {
        let tint = glyph.dimmed ? color.withAlphaComponent(inactiveAlpha) : color
        let configuration = NSImage.SymbolConfiguration(pointSize: glyph.pointSize, weight: .semibold)
            .applying(.init(hierarchicalColor: tint))
        return NSImage(systemSymbolName: glyph.name, variableValue: glyph.value, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    @MainActor
    private static func symbol(_ glyph: Glyph, color: NSColor) -> SymbolImage? {
        guard let image = configuredImage(glyph, color: color) else { return nil }
        let key = SymbolOffsetKey(name: glyph.name, value: glyph.value)
        let ratio: CGFloat
        if let cached = normalizedSymbolOffsets[key] {
            ratio = cached
        } else {
            let reference = configuredImage(
                Glyph(name: glyph.name, value: glyph.value, pointSize: inkReferencePointSize),
                color: .black
            )
            let target = reference ?? image
            let referenceSize = reference != nil ? inkReferencePointSize : glyph.pointSize
            let measured = measureInkOffset(target)
            ratio = referenceSize > 0 ? measured / referenceSize : 0
            normalizedSymbolOffsets[key] = ratio
        }
        return SymbolImage(image: image, inkOffset: ratio * glyph.pointSize)
    }

    private static func drawSymbol(_ symbol: SymbolImage, at point: CGPoint, in context: CGContext) {
        context.saveGState()
        NSGraphicsContext.saveGraphicsState()
        defer {
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
        }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.scaleBy(x: 1, y: -1)
        let size = symbol.image.size
        symbol.image.draw(in: CGRect(
            x: point.x - size.width / 2 - symbol.inkOffset, y: -point.y - size.height / 2,
            width: size.width, height: size.height
        ))
    }

    private static func measureInkOffset(_ image: NSImage) -> CGFloat {
        let scale: CGFloat = 6
        let width = Int((image.size.width * scale).rounded(.up))
        let height = Int((image.size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        var first = width
        var last = -1
        for y in 0..<height {
            for x in 0..<width where bytes[y * context.bytesPerRow + x * 4 + 3] != 0 {
                first = min(first, x)
                last = max(last, x)
            }
        }
        guard first <= last else { return 0 }
        return CGFloat(first + last + 1) / 2 / scale - image.size.width / 2
    }
}

final class StatusIconAccentView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
