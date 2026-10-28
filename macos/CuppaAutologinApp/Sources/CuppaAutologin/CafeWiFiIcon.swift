import AppKit
import SwiftUI

enum StatusCupState: Equatable {
    case online
    case signingIn
    case offline
}

/// A bright steaming cup while online, and a muted cold cup while offline.
struct CafeWiFiIcon: View {
    let isConnected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var alternateSteamFrame = false

    var body: some View {
        Image(nsImage: iconImage)
            .renderingMode(.original)
            .frame(width: 24, height: 18)
            .accessibilityLabel(
                isConnected
                    ? "Cuppa Wi-Fi, connected"
                    : "Cuppa Wi-Fi, not connected"
            )
            .task(id: isConnected && !reduceMotion) {
                alternateSteamFrame = false
                guard isConnected, !reduceMotion else { return }

                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(550))
                    guard !Task.isCancelled else { return }
                    alternateSteamFrame.toggle()
                }
            }
    }

    private var iconImage: NSImage {
        Self.menuBarImage(
            isConnected: isConnected,
            alternateSteamFrame: alternateSteamFrame,
            reduceMotion: reduceMotion
        )
    }

    /// The native status button and SwiftUI preview use the same explicit,
    /// non-template images. AppKit needs an actual button image for the
    /// system-owned menu-bar presentation, rather than a hosted subview.
    @MainActor
    static func menuBarImage(
        isConnected: Bool,
        alternateSteamFrame: Bool,
        reduceMotion: Bool
    ) -> NSImage {
        guard isConnected else {
            return CafeWiFiIconRenderer.cold
        }
        if reduceMotion || !alternateSteamFrame {
            return CafeWiFiIconRenderer.hotFrameOne
        }
        return CafeWiFiIconRenderer.hotFrameTwo
    }
}

/// The larger in-popover cup uses the same handoff geometry as the menu-bar
/// icon, scaled up and tinted for the current state.
struct StatusCupIcon: View {
    let state: StatusCupState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var alternateSteamFrame = false

    private var colour: Color {
        switch state {
        case .online:
            CoffeeTheme.connectedGreen
        case .signingIn:
            CoffeeTheme.warning
        case .offline:
            Color(nsColor: .systemGray)
        }
    }

    var body: some View {
        Canvas { context, size in
            let scaleX = size.width / 24
            let scaleY = size.height / 18
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: x * scaleX, y: y * scaleY)
            }

            if state == .online {
                var steam = Path()
                if alternateSteamFrame && !reduceMotion {
                    steam.move(to: point(8, 4.4))
                    steam.addQuadCurve(
                        to: point(8, 1.5),
                        control: point(6.9, 2.9)
                    )
                    steam.move(to: point(12, 4.4))
                    steam.addQuadCurve(
                        to: point(12, 1.5),
                        control: point(10.9, 2.9)
                    )
                } else {
                    steam.move(to: point(7, 4.4))
                    steam.addQuadCurve(
                        to: point(7, 1.5),
                        control: point(8.1, 2.9)
                    )
                    steam.move(to: point(11, 4.4))
                    steam.addQuadCurve(
                        to: point(11, 1.5),
                        control: point(12.1, 2.9)
                    )
                }
                context.stroke(
                    steam,
                    with: .color(colour),
                    style: StrokeStyle(
                        lineWidth: 1.2 * min(scaleX, scaleY),
                        lineCap: .round
                    )
                )
            }

            var bowl = Path()
            bowl.move(to: point(4, 6))
            bowl.addLine(to: point(15, 6))
            bowl.addLine(to: point(15, 10.2))
            bowl.addCurve(
                to: point(10.7, 14.5),
                control1: point(15, 12.6),
                control2: point(13.1, 14.5)
            )
            bowl.addLine(to: point(8.3, 14.5))
            bowl.addCurve(
                to: point(4, 10.2),
                control1: point(5.9, 14.5),
                control2: point(4, 12.6)
            )
            bowl.closeSubpath()
            context.fill(bowl, with: .color(colour))

            var handle = Path()
            handle.move(to: point(15, 7.5))
            handle.addLine(to: point(16.4, 7.5))
            handle.addCurve(
                to: point(16.4, 11.9),
                control1: point(19.3, 7.5),
                control2: point(19.3, 11.9)
            )
            handle.addLine(to: point(14.8, 11.9))
            context.stroke(
                handle,
                with: .color(colour),
                style: StrokeStyle(
                    lineWidth: 1.4 * min(scaleX, scaleY),
                    lineCap: .round
                )
            )

            var saucer = Path()
            saucer.move(to: point(3, 16.6))
            saucer.addLine(to: point(16.5, 16.6))
            context.stroke(
                saucer,
                with: .color(colour),
                style: StrokeStyle(
                    lineWidth: 1.5 * min(scaleX, scaleY),
                    lineCap: .round
                )
            )
        }
        .frame(width: 44, height: 33)
        .accessibilityLabel(accessibilityText)
        .task(id: state == .online && !reduceMotion) {
            alternateSteamFrame = false
            guard state == .online, !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(550))
                guard !Task.isCancelled else { return }
                alternateSteamFrame.toggle()
            }
        }
    }

    private var accessibilityText: String {
        switch state {
        case .online:
            "Online"
        case .signingIn:
            "Signing in"
        case .offline:
            "Offline"
        }
    }
}

@MainActor
private enum CafeWiFiIconRenderer {
    // Green + steam when online — the one place green appears, so the menu bar
    // reads instantly as "you're connected".
    static let onlineGreen = NSColor(
        srgbRed: 0x4e / 255,
        green: 0xc2 / 255,
        blue: 0x7f / 255,
        alpha: 1
    )
    static let cold = makeImage(steamFrame: nil, colour: .systemGray)
    static let hotFrameOne = makeImage(steamFrame: 0, colour: onlineGreen)
    static let hotFrameTwo = makeImage(steamFrame: 1, colour: onlineGreen)

    private static func makeImage(
        steamFrame: Int?,
        colour: NSColor
    ) -> NSImage {
        let image = NSImage(
            size: NSSize(width: 24, height: 18),
            flipped: false
        ) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }

            // The supplied SVGs use a top-left origin. Flip Core Graphics so
            // these coordinates remain identical to the design assets.
            context.saveGState()
            context.translateBy(x: 0, y: 18)
            context.scaleBy(x: 1, y: -1)
            context.setAllowsAntialiasing(true)
            context.setShouldAntialias(true)

            if let steamFrame {
                let steam = CGMutablePath()
                if steamFrame == 0 {
                    steam.move(to: CGPoint(x: 7, y: 4.4))
                    steam.addQuadCurve(
                        to: CGPoint(x: 7, y: 1.5),
                        control: CGPoint(x: 8, y: 2.9)
                    )
                    steam.move(to: CGPoint(x: 11, y: 4.4))
                    steam.addQuadCurve(
                        to: CGPoint(x: 11, y: 1.5),
                        control: CGPoint(x: 12, y: 2.9)
                    )
                } else {
                    steam.move(to: CGPoint(x: 8, y: 4.4))
                    steam.addQuadCurve(
                        to: CGPoint(x: 8, y: 1.5),
                        control: CGPoint(x: 7, y: 2.9)
                    )
                    steam.move(to: CGPoint(x: 12, y: 4.4))
                    steam.addQuadCurve(
                        to: CGPoint(x: 12, y: 1.5),
                        control: CGPoint(x: 11, y: 2.9)
                    )
                }
                stroke(
                    steam,
                    colour: colour,
                    width: 1.2,
                    lineCap: .round,
                    in: context
                )
            }

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
            context.setFillColor(colour.cgColor)
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
            stroke(
                handle,
                colour: colour,
                width: 1.4,
                lineCap: .butt,
                in: context
            )

            let saucer = CGMutablePath()
            saucer.move(to: CGPoint(x: 3, y: 16.6))
            saucer.addLine(to: CGPoint(x: 16.5, y: 16.6))
            stroke(
                saucer,
                colour: colour,
                width: 1.5,
                lineCap: .round,
                in: context
            )

            context.restoreGState()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func stroke(
        _ path: CGPath,
        colour: NSColor,
        width: CGFloat,
        lineCap: CGLineCap,
        in context: CGContext
    ) {
        context.addPath(path)
        context.setStrokeColor(colour.cgColor)
        context.setLineWidth(width)
        context.setLineCap(lineCap)
        context.strokePath()
    }
}
