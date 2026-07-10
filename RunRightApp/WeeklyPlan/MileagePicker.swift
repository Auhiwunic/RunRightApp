//
//  MileagePicker.swift
//  Weekly Plan
//

import SwiftUI

struct MileagePicker: View {
    @Binding var selection: WeeklyMileageRange?

    @Environment(\.planAccent) private var accent

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(WeeklyMileageRange.allCases) { range in
                let isSelected = selection == range

                Button {
                    selection = range
                } label: {
                    VStack(spacing: 6) {
                        Text(range.rangeLabel)
                            .font(AppTheme.display(22))
                            .foregroundStyle(PlanTheme.textPrimary)

                        Text(range.unitLabel)
                            .font(AppTheme.body(12))
                            .foregroundStyle(PlanTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 100)
                    .padding(16)
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
