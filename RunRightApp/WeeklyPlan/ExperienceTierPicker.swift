//
//  ExperienceTierPicker.swift
//  Weekly Plan
//

import SwiftUI

struct ExperienceTierPicker: View {
    @Binding var selection: ExperienceLevel?

    @Environment(\.planAccent) private var accent

    private let cardHeight: CGFloat = 72

    var body: some View {
        VStack(spacing: 12) {
            ForEach(ExperienceLevel.allCases) { level in
                let isSelected = selection == level

                Button {
                    selection = level
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(level.title)
                            .font(AppTheme.bodySemibold(15))
                            .foregroundStyle(PlanTheme.textPrimary)
                            .lineLimit(1)

                        Text(level.detail)
                            .font(AppTheme.body(12))
                            .foregroundStyle(PlanTheme.textSecondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: cardHeight, maxHeight: cardHeight, alignment: .topLeading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: PlanTheme.cardRadius)
                            .fill(isSelected ? PlanTheme.cardSelected : PlanTheme.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: PlanTheme.cardRadius)
                            .stroke(isSelected ? accent : Color.clear, lineWidth: 1.5)
                    )
                    .elevatedCard(isSelected: isSelected)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
