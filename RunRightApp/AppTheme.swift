//
//  AppTheme.swift
//  RunRightApp
//
//  Exact color and style definitions matching the HTML prototype
//

import SwiftUI
import Neumorphic

// MARK: - Debug-only logging
// Logs in DEBUG builds only — keeps PII (emails, uids, tokens) and noise out of
// production device logs. No-ops entirely in release.
#if DEBUG
func debugLog(_ items: Any...) {
    print(items.map { "\($0)" }.joined(separator: " "))
}
#else
@inline(__always) func debugLog(_ items: Any...) {}
#endif

// MARK: - Color Extension for Hex Support
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Adaptive color (dark = original palette, light = gaita-site paper/ink)
extension Color {
    /// Resolves per trait collection: `dark` is the app's original palette,
    /// `light` is the marketing site's bone/ink editorial palette.
    init(light: Color, dark: Color) {
        self.init(UIColor { trait in
            trait.userInterfaceStyle == .light ? UIColor(light) : UIColor(dark)
        })
    }

    init(lightHex: String, darkHex: String) {
        self.init(light: Color(hex: lightHex), dark: Color(hex: darkHex))
    }
}

// MARK: - App Theme
struct AppTheme {
    // MARK: - Colors
    // Dark mode: the original cyan/spring-green scheme, untouched.
    // Light mode ("white mode"): the gaita-site palette — bone paper canvas,
    // ink type, shell recessed tiles. Elevation ladder keeps the same token
    // order in both modes: bgColor < cardBgAlt < cardBg < raisedFill.
    static let bgColor = Color(lightHex: "#E3E3DE", darkHex: "#121518")
    static let accentColor = Color(hex: "#00CED1")      // Cyan
    static let accentGreen = Color(hex: "#00FF7F")      // Spring green
    static let fitnessGreen = Color(hex: "#B7F75C")     // Apple Fitness+ green
    static let accentDim = Color(hex: "#00A5A8")        // Darker cyan
    static let formRed = Color(hex: "#FF2D2D")          // legacy red (skeleton overlay, scorecard)
    static let analyzePink = Color(hex: "#FF2D9B")      // RETIRED: the app now uses one unified UI accent (accentColor). Kept only so any stray reference still compiles.
    static let darkAccent = Color(hex: "#006666")       // Dark teal
    static let darkerAccent = Color(hex: "#003333")     // Very dark teal
    static let primaryText = Color(lightHex: "#141412", darkHex: "#FFFFFF")   // site ink / white
    static let secondaryText = Color(lightHex: "#6D6D68", darkHex: "#7A7A7A") // site mid
    /// Tertiary/meta text — site "soft".
    static let tertiaryText = Color(lightHex: "#A3A39E", darkHex: "#5F5F5F")
    static let tabBarBg = Color(lightHex: "#E6E6E2", darkHex: "#20262B")
    static let cardBg = Color(lightHex: "#FAFAF9", darkHex: "#252B31")
    static let cardBgAlt = Color(lightHex: "#E8E8E3", darkHex: "#181D21")     // light = darkened paper (more card contrast)
    /// Fill for boxes raised above a card — one step lighter than cardBg so the
    /// lift reads as elevation, not decoration. No gradient, no shine.
    static let raisedFill = Color(lightHex: "#FFFFFF", darkHex: "#30373F")
    /// Recessed/inset tile fill — light mode a touch below the page bg so inset
    /// tiles still read as recessed against the darkened background.
    static let insetFill = Color(lightHex: "#DCDCD7", darkHex: "#181D21")
    static let dividerColor = Color(light: Color(hex: "#141412").opacity(0.10),
                                    dark: Color.white.opacity(0.08))
    static let subtleBorder = Color(light: Color(hex: "#141412").opacity(0.16),
                                    dark: Color.white.opacity(0.15))
    /// Text/icons drawn on top of a solid accent fill — high contrast in both modes.
    static let onAccentPrimary = Color(hex: "#121212")
    
    // MARK: - Gradients
    
    /// Main gradient for header section (gray to black) - more visible.
    /// Light mode: warm paper grays fading to bone, same geometry.
    static let headerGradient = LinearGradient(
        stops: [
            .init(color: Color(lightHex: "#D9D9D5", darkHex: "#5a5a5a"), location: 0.0),
            .init(color: Color(lightHex: "#DEDEDA", darkHex: "#4a4a4a"), location: 0.06),
            .init(color: Color(lightHex: "#E2E2DE", darkHex: "#3a3a3a"), location: 0.12),
            .init(color: Color(lightHex: "#E7E7E3", darkHex: "#2a2a2a"), location: 0.20),
            .init(color: Color(lightHex: "#EBEBE8", darkHex: "#1a1a1a"), location: 0.32),
            .init(color: Color(lightHex: "#EEEEEB", darkHex: "#0f0f0f"), location: 0.50),
            .init(color: Color(lightHex: "#F1F1EF", darkHex: "#0a0a0a"), location: 0.75),
            .init(color: Color(lightHex: "#F1F1EF", darkHex: "#0a0a0a"), location: 1.0)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    /// Progress ring gradient (dark blue to cyan to green)
    static let progressGradient = LinearGradient(
        stops: [
            .init(color: Color(hex: "#0a1a3d"), location: 0.0),
            .init(color: Color(hex: "#1a3a6e"), location: 0.2),
            .init(color: Color(hex: "#006666"), location: 0.4),
            .init(color: Color(hex: "#00A5A8"), location: 0.6),
            .init(color: Color(hex: "#00CED1"), location: 0.8),
            .init(color: Color(hex: "#00FF7F"), location: 1.0)
        ],
        startPoint: .bottomLeading,
        endPoint: .topTrailing
    )
    
    /// Widget gradient (cyan/green tones)
    static let widgetRunGradient = LinearGradient(
        stops: [
            .init(color: Color(hex: "#003333"), location: 0.0),
            .init(color: Color(hex: "#006666"), location: 0.25),
            .init(color: Color(hex: "#00A5A8"), location: 0.5),
            .init(color: Color(hex: "#00CED1"), location: 0.75),
            .init(color: Color(hex: "#00FF7F"), location: 1.0)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    /// Card gradient (adapts: dark grays / paper whites)
    static let cardGradient = LinearGradient(
        colors: [cardBg, cardBgAlt],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Top bar gradient for secondary pages - more visible
    static let topBarGradient = LinearGradient(
        stops: [
            .init(color: Color(lightHex: "#DEDEDA", darkHex: "#3a3a3a").opacity(0.8), location: 0.0),
            .init(color: Color(lightHex: "#E7E7E3", darkHex: "#2a2a2a").opacity(0.5), location: 0.25),
            .init(color: Color(lightHex: "#EDEDEA", darkHex: "#1a1a1a").opacity(0.3), location: 0.5),
            .init(color: Color.clear, location: 0.75)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Type system (ported from gaita-site "track day")
    // Archivo carries every heading, label and readout; Switzer carries body
    // copy. The four Archivo cuts are static instances of the variable font at
    // the site's exact weight/width values.

    // Every token passes `relativeTo:` so the custom faces SCALE with the user's
    // Dynamic Type setting (accessibility) instead of being pinned to one size.
    // The relativeTo style is chosen by the token's role, not the call-site size.

    /// Massive display caps and big number readouts — Archivo 650, 90% width.
    /// Site `.display-caps`. Pair with `.tracking(size * -0.02)` on standalone Text.
    static func display(_ size: CGFloat) -> Font { .custom("Archivo-Display", size: size, relativeTo: .title) }
    /// Section heads — Archivo 600, 93% width. Site `.head-caps`.
    static func head(_ size: CGFloat) -> Font { .custom("Archivo-Head", size: size, relativeTo: .headline) }
    /// Screen titles / logo weight — Archivo 700, 93% width.
    static func headBold(_ size: CGFloat) -> Font { .custom("Archivo-HeadBold", size: size, relativeTo: .title) }
    /// Tiny wide-tracked meta labels — Archivo 500, never condensed. Site `.meta`.
    /// Pair with `.tracking(size * 0.12)` for the site's letterspacing.
    static func meta(_ size: CGFloat) -> Font { .custom("Archivo-Meta", size: size, relativeTo: .caption) }
    /// Body copy — Switzer 400 / 500 / 600.
    static func body(_ size: CGFloat) -> Font { .custom("Switzer-Regular", size: size, relativeTo: .body) }
    static func bodyMedium(_ size: CGFloat) -> Font { .custom("Switzer-Medium", size: size, relativeTo: .body) }
    static func bodySemibold(_ size: CGFloat) -> Font { .custom("Switzer-Semibold", size: size, relativeTo: .body) }

    /// Display cut with tabular figures — for live readouts (timers, paces,
    /// tickers) whose digits must not jitter as values change. Site `.tabular`.
    /// Goes through `.custom(relativeTo:)` + `.monospacedDigit()` so it scales
    /// with Dynamic Type AND honors the app-root `.dynamicTypeSize` cap, exactly
    /// like the other tokens (the old UIFontMetrics path scaled off the uncapped
    /// global category and could overflow fixed frames past the cap).
    static func displayTabular(_ size: CGFloat) -> Font {
        .custom("Archivo-Display", size: size, relativeTo: .title).monospacedDigit()
    }

    // MARK: - Font tokens (sizes unchanged; faces now match the site)
    static let titleFont: Font = headBold(28)

    /// CANONICAL section / graph / card title — the ONE title font used app-wide.
    /// primaryText ink/white, Archivo head caps, deliberately larger. Every heading
    /// (Home, Analyze, charts, tables) uses this; titles are never gray and never smaller.
    static let sectionTitleFont: Font = head(15)
    static let subtitleFont: Font = head(22)
    static let bodyFont: Font = body(17)
    static let captionFont: Font = body(13)
    static let smallFont: Font = body(12)
    static let tinyFont: Font = meta(10)
    static let tabBarLabelFont: Font = meta(11)
    
    // MARK: - Spacing
    static let screenPadding: CGFloat = 20
    static let cardCornerRadius: CGFloat = 14
    static let widgetCornerRadius: CGFloat = 20
    static let buttonCornerRadius: CGFloat = 12
    static let homeWidgetCornerRadius: CGFloat = 22   // Analyze dashboard widget cards
    static let homeButtonCornerRadius: CGFloat = 14   // Analyze dashboard buttons
    
    // MARK: - Tab Bar Height
    static let tabBarHeight: CGFloat = 90
}

// MARK: - Shared Neumorphic Surface
struct AppRaisedSurface: ViewModifier {
    let fill: Color
    let cornerRadius: CGFloat
    let shadowRadius: CGFloat
    let x: CGFloat
    let y: CGFloat
    let lightOpacity: Double
    let darkOpacity: Double

    @Environment(\.colorScheme) private var colorScheme

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        // Light mode swaps the shadow pair for paper: a warm gray drop shadow
        // and a white top light. Same geometry, softer contrast.
        let darkShadow = colorScheme == .light
            ? Color(hex: "#B4B4AE").opacity(min(darkOpacity, 0.55))
            : Color(hex: "#000000").opacity(darkOpacity)
        let lightShadow = colorScheme == .light
            ? Color.white.opacity(min(lightOpacity * 5, 0.9))
            : Color(hex: "#56636E").opacity(lightOpacity)
        content
            .background(
                shape
                    .fill(fill)
                    .softOuterShadow(
                        darkShadow: darkShadow,
                        lightShadow: lightShadow,
                        offset: max(x, y),
                        radius: shadowRadius
                    )
            )
    }
}

extension View {
    func appRaisedSurface(
        fill: Color = AppTheme.cardBg,
        cornerRadius: CGFloat = AppTheme.cardCornerRadius,
        shadowRadius: CGFloat = 14,
        x: CGFloat = 8,
        y: CGFloat = 8,
        lightOpacity: Double = 0.18,
        darkOpacity: Double = 0.70
    ) -> some View {
        modifier(
            AppRaisedSurface(
                fill: fill,
                cornerRadius: cornerRadius,
                shadowRadius: shadowRadius,
                x: x,
                y: y,
                lightOpacity: lightOpacity,
                darkOpacity: darkOpacity
            )
        )
    }

    /// The standard raised text box: a subtle lift above a card surface.
    /// One recipe app-wide so every raised element reads as the same material.
    func appRaisedBox(cornerRadius: CGFloat = AppTheme.buttonCornerRadius) -> some View {
        appRaisedSurface(
            fill: AppTheme.raisedFill,
            cornerRadius: cornerRadius,
            shadowRadius: 6,
            x: 3,
            y: 4,
            lightOpacity: 0.10,
            darkOpacity: 0.50
        )
    }

    func appInsetSurface(
        fill: Color = AppTheme.cardBgAlt,
        cornerRadius: CGFloat = AppTheme.buttonCornerRadius,
        shadowRadius: CGFloat = 6,
        x: CGFloat = 3,
        y: CGFloat = 4,
        lightOpacity: Double = 0.04,
        darkOpacity: Double = 0.34
    ) -> some View {
        appRaisedSurface(
            fill: fill,
            cornerRadius: cornerRadius,
            shadowRadius: shadowRadius,
            x: x,
            y: y,
            lightOpacity: lightOpacity,
            darkOpacity: darkOpacity
        )
    }
}

// MARK: - Noise Texture Overlay
struct NoiseTexture: View {
    var opacity: Double = 0.12
    
    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                for _ in 0..<Int(size.width * size.height / 20) {
                    let x = CGFloat.random(in: 0..<size.width)
                    let y = CGFloat.random(in: 0..<size.height)
                    let gray = CGFloat.random(in: 0.3...0.7)
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)),
                        with: .color(Color(white: gray, opacity: opacity))
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Card Modifier
struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .appRaisedSurface(fill: AppTheme.cardBg, cornerRadius: AppTheme.cardCornerRadius)
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}
