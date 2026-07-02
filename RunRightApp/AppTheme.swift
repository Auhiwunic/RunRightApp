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

// MARK: - App Theme
struct AppTheme {
    // MARK: - Colors (cyan/spring green accent scheme)
    static let bgColor = Color(hex: "#121518")
    static let accentColor = Color(hex: "#00CED1")      // Cyan
    static let accentGreen = Color(hex: "#00FF7F")      // Spring green
    static let fitnessGreen = Color(hex: "#B7F75C")     // Apple Fitness+ green
    static let accentDim = Color(hex: "#00A5A8")        // Darker cyan
    static let formRed = Color(hex: "#FF2D2D")          // Form Analysis accent (neon red)
    static let darkAccent = Color(hex: "#006666")       // Dark teal
    static let darkerAccent = Color(hex: "#003333")     // Very dark teal
    static let primaryText = Color.white
    static let secondaryText = Color(hex: "#7A7A7A")
    static let tabBarBg = Color(hex: "#20262B")
    static let cardBg = Color(hex: "#252B31")
    static let cardBgAlt = Color(hex: "#181D21")
    static let dividerColor = Color.white.opacity(0.08)
    static let subtleBorder = Color.white.opacity(0.15)
    /// Text/icons drawn on top of a solid accent fill — high contrast (used by Analyze dashboard).
    static let onAccentPrimary = Color(hex: "#121212")
    
    // MARK: - Gradients
    
    /// Main gradient for header section (gray to black) - more visible
    static let headerGradient = LinearGradient(
        stops: [
            .init(color: Color(hex: "#5a5a5a"), location: 0.0),
            .init(color: Color(hex: "#4a4a4a"), location: 0.06),
            .init(color: Color(hex: "#3a3a3a"), location: 0.12),
            .init(color: Color(hex: "#2a2a2a"), location: 0.20),
            .init(color: Color(hex: "#1a1a1a"), location: 0.32),
            .init(color: Color(hex: "#0f0f0f"), location: 0.50),
            .init(color: Color(hex: "#0a0a0a"), location: 0.75),
            .init(color: Color(hex: "#0a0a0a"), location: 1.0)
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
    
    /// Card gradient (dark but not pitch black)
    static let cardGradient = LinearGradient(
        colors: [Color(hex: "#252B31"), Color(hex: "#181D21")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    /// Top bar gradient for secondary pages - more visible
    static let topBarGradient = LinearGradient(
        stops: [
            .init(color: Color(hex: "#3a3a3a").opacity(0.8), location: 0.0),
            .init(color: Color(hex: "#2a2a2a").opacity(0.5), location: 0.25),
            .init(color: Color(hex: "#1a1a1a").opacity(0.3), location: 0.5),
            .init(color: Color.clear, location: 0.75)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    
    // MARK: - Font Sizes (Apple Fitness+ style)
    static let titleFont: Font = .system(size: 28, weight: .bold)
    static let subtitleFont: Font = .system(size: 22, weight: .semibold)
    static let bodyFont: Font = .system(size: 17, weight: .regular)
    static let captionFont: Font = .system(size: 13, weight: .regular)
    static let smallFont: Font = .system(size: 12, weight: .regular)
    static let tinyFont: Font = .system(size: 10, weight: .regular)
    static let tabBarLabelFont: Font = .system(size: 11, weight: .semibold)
    
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

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background(
                shape
                    .fill(fill)
                    .softOuterShadow(
                        darkShadow: Color(hex: "#000000").opacity(darkOpacity),
                        lightShadow: Color(hex: "#56636E").opacity(lightOpacity),
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
