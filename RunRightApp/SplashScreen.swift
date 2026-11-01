//
//  SplashScreen.swift
//  RunRightApp
//
//  Branded launch splash. Shown while anonymous sign-in bootstraps (first
//  install / cache miss). It reuses the app's own visual language — the ambient
//  AnimatedBackground and the GaitaLogo — so it seams cleanly out of the static
//  UILaunchScreen (a solid LaunchBackground fill = bgColor) and into MainTabView.
//  The old raw ProgressView system-icon spinner is replaced by a branded
//  rotating accent ring around the logo.
//

import SwiftUI

struct BrandedSplashScreen: View {
    /// Auth error (offline first install). When set, the ring stops and a retry
    /// button is offered instead — the same recovery path the old spinner had.
    var errorMessage: String? = nil
    var onRetry: (() -> Void)? = nil

    @State private var spin = false
    @State private var pulse = false

    // Theme aware (user request 2026-07-11, supersedes the earlier "always pure
    // white"): the splash matches the chosen appearance — clean white in light
    // mode, the app's dark base in dark mode — so a dark-theme launch never
    // flashes white. No tint, no ambient orbs in either theme. The static
    // UILaunchScreen colorset carries a matching dark variant.
    private var ink: Color { AppTheme.primaryText }

    var body: some View {
        ZStack {
            AppTheme.bgColor.ignoresSafeArea()

            VStack(spacing: 26) {
                // The logo itself spins — the same branded motion as the Coach
                // chat header, not a separate ring around it. Stops on error.
                Image("GaitaLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .rotationEffect(.degrees(errorMessage == nil && spin ? 360 : 0))
                    .animation(
                        errorMessage == nil
                            ? .linear(duration: 1.4).repeatForever(autoreverses: false)
                            : .default,
                        value: spin
                    )
                    .scaleEffect(pulse ? 1.0 : 0.96)
                    .animation(
                        .easeInOut(duration: 1.3).repeatForever(autoreverses: true),
                        value: pulse
                    )

                if let errorMessage {
                    Text(errorMessage)
                        .font(AppTheme.bodyMedium(13))
                        .foregroundColor(ink.opacity(0.75))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)

                    if let onRetry {
                        Button("Try Again", action: onRetry)
                            .font(AppTheme.bodySemibold(15))
                            .foregroundColor(.black)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(AppTheme.accentColor))
                    }
                } else {
                    Text("Getting ready")
                        .font(AppTheme.bodyMedium(13))
                        .foregroundColor(ink.opacity(0.4))
                        .tracking(0.5)
                }
            }
        }
        .onAppear {
            spin = true
            pulse = true
        }
    }
}

#Preview {
    BrandedSplashScreen()
        .preferredColorScheme(.dark)
}

#Preview("Error") {
    BrandedSplashScreen(
        errorMessage: "Couldn't connect. Check your internet and try again.",
        onRetry: {}
    )
    .preferredColorScheme(.dark)
}
