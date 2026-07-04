//
//  MandateWarningView.swift
//  Weekly Plan
//

import SwiftUI

struct MandateWarningView: View {
    let mandates: [PlanMandate]

    var body: some View {
        if !mandates.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(mandates.enumerated()), id: \.offset) { _, mandate in
                    mandateCard(mandate)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func mandateCard(_ mandate: PlanMandate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(mandate.severity == .critical
                      ? Color(red: 1, green: 0.35, blue: 0.35)
                      : Color(red: 1, green: 0.78, blue: 0.25))
                .frame(width: 3)

            Text(mandate.message)
                .font(AppTheme.body(12))
                .foregroundStyle(mandate.severity == .critical
                                 ? Color(red: 1, green: 0.5, blue: 0.5)
                                 : Color(red: 1, green: 0.85, blue: 0.45))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(PlanTheme.card)
        )
    }
}
