//
//  AnimatedBackground.swift
//  Weekly Plan
//

import SwiftUI

struct AnimatedBackground: View {
    @State private var animate = false

    var body: some View {
        ZStack {
            PlanTheme.background

            // Ambient glow, all in the signature-blue family (was a zone rainbow).
            orb(color: Color(hex: "#00CED1").opacity(0.18), size: 320)
                .offset(x: animate ? -70 : -130, y: animate ? -200 : -140)
                .animation(.easeInOut(duration: 9).repeatForever(autoreverses: true), value: animate)

            orb(color: Color(hex: "#33DEE1").opacity(0.12), size: 360)
                .offset(x: animate ? 130 : 80, y: animate ? 230 : 170)
                .animation(.easeInOut(duration: 12).repeatForever(autoreverses: true), value: animate)

            orb(color: Color(hex: "#00A5A8").opacity(0.16), size: 300)
                .offset(x: animate ? 120 : 160, y: animate ? -150 : -90)
                .animation(.easeInOut(duration: 11).repeatForever(autoreverses: true), value: animate)

            orb(color: Color(hex: "#00767A").opacity(0.14), size: 260)
                .offset(x: animate ? -120 : -80, y: animate ? 180 : 240)
                .animation(.easeInOut(duration: 14).repeatForever(autoreverses: true), value: animate)
        }
        .ignoresSafeArea()
        .clipped()
        .allowsHitTesting(false)
        .onAppear { animate = true }
    }

    private func orb(color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .blur(radius: 80)
    }
}

#Preview {
    AnimatedBackground()
        .preferredColorScheme(.dark)
}
