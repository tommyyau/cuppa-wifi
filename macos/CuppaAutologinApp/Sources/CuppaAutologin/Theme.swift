import SwiftUI

/// Espresso-caramel dark palette (design "7a"). One coffee machine: caramel is
/// the only interactive accent, green is reserved for the connected cup, and
/// everything sits on a warm-dark surface.
enum CoffeeTheme {
    // Surfaces
    static let surface = Color(hex: 0x201f22)
    static let surfaceBorder = Color.white.opacity(0.09)
    static let groupedBackground = Color.white.opacity(0.04)
    static let groupedBorder = Color.white.opacity(0.08)
    static let divider = Color.white.opacity(0.08)

    // Text
    static let primaryText = Color(hex: 0xf2f0ee)
    static let muted = Color(hex: 0x96918b)
    static let helpBody = Color(hex: 0xa49f99)

    // Accent (caramel)
    static let caramel = Color(hex: 0xd08a43)
    static let caramelOnFill = Color(hex: 0x2a1a00)
    static let caramelLink = Color(hex: 0xe0a25c)

    // Inputs / secondary chrome
    static let inputBackground = Color(hex: 0x2b2a2e)
    static let inputBorder = Color.white.opacity(0.14)
    static let secondaryFill = Color(hex: 0x34323a)
    static let secondaryBorder = Color.white.opacity(0.16)
    static let toggleOff = Color(hex: 0x3a373c)

    // Semantic
    static let warning = Color(hex: 0xf0a53d)
    static let destructive = Color(hex: 0xff8a7d)
    static let unreadBadge = Color(hex: 0xff5f52)

    // Green — connected cup only
    static let connectedGreen = Color(hex: 0x34c759)
    static let connectedGreenMenuBar = Color(hex: 0x4ec27f)

    // Receipt parchment (kept light on purpose, rendered in a light subtree)
    static let receiptPaper = Color(hex: 0xf3ece0)
}

extension Color {
    init(hex: UInt) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255
        )
    }
}

// MARK: - Buttons

/// Filled caramel — primary actions (Check Now, Save…, confirm quit).
struct CaramelPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration)
    }

    private struct Chrome: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                // Dark ink on caramel when active; light muted text on a grey
                // fill when disabled, so the label stays legible either way.
                .foregroundStyle(
                    isEnabled ? CoffeeTheme.caramelOnFill : CoffeeTheme.muted
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(minHeight: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            isEnabled
                                ? CoffeeTheme.caramel
                                : CoffeeTheme.secondaryFill
                        )
                )
                .opacity(configuration.isPressed ? 0.82 : 1)
        }
    }
}

/// Dark chrome + hairline border — secondary actions (Discard, Generate, Copy…).
struct SecondaryButtonStyle: ButtonStyle {
    var role: Role = .neutral

    enum Role { case neutral, destructive }

    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration, role: role)
    }

    private struct Chrome: View {
        let configuration: Configuration
        let role: Role
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    role == .destructive
                        ? CoffeeTheme.destructive
                        : CoffeeTheme.primaryText
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .frame(minHeight: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(CoffeeTheme.secondaryFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(CoffeeTheme.secondaryBorder, lineWidth: 1)
                )
                .opacity(opacity)
        }

        private var opacity: Double {
            guard isEnabled else { return 0.4 }
            return configuration.isPressed ? 0.82 : 1
        }
    }
}

/// Transparent + caramel text — quiet accent actions (Test Speed, Settle Up).
struct QuietCaramelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Chrome(configuration: configuration)
    }

    private struct Chrome: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CoffeeTheme.caramelLink)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(minHeight: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(CoffeeTheme.secondaryBorder, lineWidth: 1)
                )
                .opacity(opacity)
        }

        private var opacity: Double {
            guard isEnabled else { return 0.4 }
            return configuration.isPressed ? 0.7 : 1
        }
    }
}

extension ButtonStyle where Self == CaramelPrimaryButtonStyle {
    static var caramelPrimary: Self { .init() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var coffeeSecondary: Self { .init() }
    static var coffeeDestructive: Self { .init(role: .destructive) }
}

extension ButtonStyle where Self == QuietCaramelButtonStyle {
    static var quietCaramel: Self { .init() }
}

// MARK: - Grouped cards (Settings)

struct CoffeeGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            configuration.label
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CoffeeTheme.muted)
            configuration.content
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(CoffeeTheme.groupedBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(CoffeeTheme.groupedBorder, lineWidth: 1)
        )
    }
}
