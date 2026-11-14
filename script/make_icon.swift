import AppKit
import Foundation

@main
struct IconBuilder {
    static func main() throws {
        let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let bitmap = draw(pixels: size * scale)
                let suffix = scale == 2 ? "@2x" : ""
                let file = destination.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: file)
            }
        }
    }

    private static func draw(pixels: Int) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        bitmap.size = NSSize(width: 1024, height: 1024)
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        let background = NSBezierPath(roundedRect: NSRect(x: 92, y: 92, width: 840, height: 840), xRadius: 185, yRadius: 185)
        NSGradient(
            starting: NSColor(calibratedRed: 0.14, green: 0.23, blue: 0.35, alpha: 1),
            ending: NSColor(calibratedRed: 0.04, green: 0.08, blue: 0.14, alpha: 1)
        )!.draw(in: background, angle: -90)

        let context = graphics.cgContext
        context.translateBy(x: 179, y: 845)
        context.scaleBy(x: 5.55, y: -5.55)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(10)
        context.setStrokeColor(CGColor(red: 0.44, green: 0.91, blue: 0.75, alpha: 1))
        context.addPath(StatusIconGeometry.batteryTrack())
        context.strokePath()

        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(7)
        for path in StatusIconGeometry.wifiArcs(level: 3) {
            context.addPath(path)
            context.strokePath()
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.addPath(StatusIconGeometry.wifiDot())
        context.fillPath()
        for (index, point) in StatusIconGeometry.volumeDots().enumerated() {
            let radius = StatusIconGeometry.volumeDotRadius
            context.setFillColor(CGColor(gray: 1, alpha: index < 3 ? 1 : 0.22))
            context.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
        }
        return bitmap
    }
}
