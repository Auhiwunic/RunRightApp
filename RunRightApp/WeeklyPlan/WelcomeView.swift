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
                        .font(AppTheme.display(44))
                        .foregroundStyle(PlanTheme.textPrimary)

                    Text("week.")
                        .font(AppTheme.display(44))
                        .foregroundStyle(PlanTheme.textPrimary)
                }

                Text("A few quick questions to shape your plan.")
                    .font(AppTheme.body(17))
                    .foregroundStyle(PlanTheme.textSecondary)
                    .padding(.top, 20)

                Spacer()

                Button(action: onGetStarted) {
                    Text("Let's go")
                        .font(AppTheme.bodySemibold(17))
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
