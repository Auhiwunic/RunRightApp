//
//  WelcomeView.swift
//  Weekly Plan
//

import SwiftUI

struct WelcomeView: View {
    let onGetStarted: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Build your")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(PlanTheme.textPrimary)

                    Text("week.")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(PlanTheme.textPrimary)
                }

                Text("A few quick questions to shape your plan.")
                    .font(.body)
                    .foregroundStyle(PlanTheme.textSecondary)
                    .padding(.top, 20)

                Spacer()

                Button(action: onGetStarted) {
                    Text("Let's go")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color.white)
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
        }
    }
}

#Preview {
    WelcomeView(onGetStarted: {})
        .background(PlanTheme.background)
        .preferredColorScheme(.dark)
}
