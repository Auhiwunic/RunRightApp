//
//  WeekdayBarSelector.swift
//  Weekly Plan
//

import SwiftUI

struct WeekdayBarSelector: View {
    @Binding var selectedDays: Set<Int>

    @Environment(\.planAccent) private var accent

    private let barHeight: CGFloat = 120

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ForEach(Weekday.allCases) { day in
                let isSelected = selectedDays.contains(day.rawValue)

                Button {
                    if isSelected {
                        selectedDays.remove(day.rawValue)
                    } else {
                        selectedDays.insert(day.rawValue)
                    }
                } label: {
                    VStack(spacing: 10) {
                        Text(day.shortLabel)
                            .font(AppTheme.bodySemibold(12))
                            .foregroundStyle(isSelected ? accent : PlanTheme.textSecondary)

                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? accent : PlanTheme.barUnselected)
                            .frame(height: isSelected ? barHeight : barHeight * 0.45)
                            .elevatedCard(isSelected: isSelected)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSelected)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
