//
//  AppTheme.swift
//  RunRightApp
//
//  Exact color and style definitions matching the HTML prototype
//

import SwiftUI

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
    static let bgColor = Color(hex: "#121212")
    static let accentColor = Color(hex: "#00CED1")      // Cyan
    static let accentGreen = Color(hex: "#00FF7F")      // Spring green
    static let fitnessGreen = Color(hex: "#B7F75C")     // Apple Fitness+ green
    static let accentDim = Color(hex: "#00A5A8")        // Darker cyan
    static let darkAccent = Color(hex: "#006666")       // Dark teal
    static let darkerAccent = Color(hex: "#003333")     // Very dark teal
    static let primaryText = Color.white
    static let secondaryText = Color(hex: "#7A7A7A")
    static let tabBarBg = Color(hex: "#1C1C1E")
    static let cardBg = Color(hex: "#0e0e0e")
    static let cardBgAlt = Color(hex: "#0a0a0a")
    static let dividerColor = Color.white.opacity(0.08)
    static let subtleBorder = Color.white.opacity(0.15)
    
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
        colors: [Color(hex: "#0e0e0e"), Color(hex: "#0a0a0a")],
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
    
    // MARK: - Tab Bar Height
    static let tabBarHeight: CGFloat = 90
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
            .background(AppTheme.cardGradient)
            .cornerRadius(AppTheme.cardCornerRadius)
    }
}

extension View {
    func cardStyle() -> some View {
        modifier(CardStyle())
    }
}

