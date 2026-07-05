//
//  PlanTheme.swift
//  Weekly Plan
//

import SwiftUI

enum PlanTheme {
    static let background = Color.black
    static let card = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let cardSelected = Color(red: 0.14, green: 0.14, blue: 0.15)
    static let barUnselected = Color(red: 0.17, green: 0.17, blue: 0.18)
    static let accent = AppTheme.accentColor          // signature blue (was lime)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.72)   // reads white, kept slightly softer for hierarchy
    static let cardRadius: CGFloat = 20

    /// Intro branding spectrum — a blue family (light → deep) so every accent in
    /// onboarding stays the signature blue rather than a rainbow of zone colors.
    static let zoneColors: [Color] = [
        Color(hex: "#8CF2F4"),
        Color(hex: "#33DEE1"),
        Color(hex: "#00CED1"),  // signature blue
        Color(hex: "#00A5A8"),
        Color(hex: "#00767A")
    ]

    /// Left→right spectrum across all five zones — used to brand the intro screen.
    static let zoneSpectrum = LinearGradient(
        colors: zoneColors,
        startPoint: .leading,
        endPoint: .trailing
    )
}

extension View {
    func elevatedCard(isSelected: Bool = false) -> some View {
        shadow(color: .black.opacity(0.55), radius: isSelected ? 14 : 10, x: 0, y: isSelected ? 10 : 6)
            .shadow(
                color: isSelected ? PlanTheme.accent.opacity(0.18) : .black.opacity(0.2),
                radius: isSelected ? 16 : 4,
                x: 0,
                y: 2
            )
    }
}

// Per-step accent propagated through the onboarding flow so each question can
// cycle through the training-zone colors. Defaults to the base accent.
private struct PlanAccentKey: EnvironmentKey {
    static let defaultValue: Color = PlanTheme.accent
}

extension EnvironmentValues {
    var planAccent: Color {
        get { self[PlanAccentKey.self] }
        set { self[PlanAccentKey.self] = newValue }
    }
}
