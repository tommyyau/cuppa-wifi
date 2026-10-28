import AppKit

// Finder and Spotlight need a static bundle icon, separate from the animated
// menu-bar view. Match CafeWiFiIcon's cup silhouette and the app's caramel
// brand colour; the application icon does not represent connection state.
func colour(_ hex: UInt32) -> CGColor {
    CGColor(
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        components: [
            CGFloat((hex >> 16) & 0xff) / 255,
            CGFloat((hex >> 8) & 0xff) / 255,
            CGFloat(hex & 0xff) / 255,
            1,
        ]
    )!
}

func renderIcon(pixels: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let tile = CGPath(
        roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
        cornerWidth: 196,
        cornerHeight: 196,
        transform: nil
    )
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: 14),
        blur: 24,
        color: NSColor.black.withAlphaComponent(0.22).cgColor
    )
    context.addPath(tile)
    context.setFillColor(colour(0x201f22))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [colour(0x383238), colour(0x201f22)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 512, y: 64),
        end: CGPoint(x: 512, y: 960),
        options: []
    )
    context.restoreGState()

    context.addPath(tile)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    context.setLineWidth(3)
    context.strokePath()

    // Production cup coordinates, centred on the square app-icon canvas.
    context.translateBy(x: 117, y: 155)
    context.scaleBy(x: 38, y: 38)
    context.setFillColor(colour(0xd08a43))
    context.setStrokeColor(colour(0xd08a43))
    context.setLineCap(.round)

    let steam = CGMutablePath()
    steam.move(to: CGPoint(x: 7, y: 4.4))
    steam.addQuadCurve(to: CGPoint(x: 7, y: 1.5), control: CGPoint(x: 8, y: 2.9))
    steam.move(to: CGPoint(x: 11, y: 4.4))
    steam.addQuadCurve(to: CGPoint(x: 11, y: 1.5), control: CGPoint(x: 12, y: 2.9))
    context.addPath(steam)
    context.setLineWidth(1.2)
    context.strokePath()

    let bowl = CGMutablePath()
    bowl.move(to: CGPoint(x: 4, y: 6))
    bowl.addLine(to: CGPoint(x: 15, y: 6))
    bowl.addLine(to: CGPoint(x: 15, y: 10.2))
    bowl.addCurve(
        to: CGPoint(x: 10.7, y: 14.5),
        control1: CGPoint(x: 15, y: 12.6),
        control2: CGPoint(x: 13.1, y: 14.5)
    )
    bowl.addLine(to: CGPoint(x: 8.3, y: 14.5))
    bowl.addCurve(
        to: CGPoint(x: 4, y: 10.2),
        control1: CGPoint(x: 5.9, y: 14.5),
        control2: CGPoint(x: 4, y: 12.6)
    )
    bowl.closeSubpath()
    context.addPath(bowl)
    context.fillPath()

    let handle = CGMutablePath()
    handle.move(to: CGPoint(x: 15, y: 7.5))
    handle.addLine(to: CGPoint(x: 16.4, y: 7.5))
    handle.addCurve(
        to: CGPoint(x: 16.4, y: 11.9),
        control1: CGPoint(x: 19.3, y: 7.5),
        control2: CGPoint(x: 19.3, y: 11.9)
    )
    handle.addLine(to: CGPoint(x: 14.8, y: 11.9))
    context.addPath(handle)
    context.setLineWidth(1.4)
    context.strokePath()

    context.move(to: CGPoint(x: 3, y: 16.6))
    context.addLine(to: CGPoint(x: 16.5, y: 16.6))
    context.setLineWidth(1.5)
    context.strokePath()

    graphics.flushGraphics()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try renderIcon(pixels: size * scale).write(
            to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
        )
    }
}
