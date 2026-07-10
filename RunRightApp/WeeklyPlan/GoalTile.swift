//
//  GoalTile.swift
//  Weekly Plan
//

import SwiftUI

struct GoalTile: View {
    let goal: RunningGoal
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.planAccent) private var accent

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(goal.title)
                    .font(AppTheme.bodySemibold(15))
                    .foregroundStyle(PlanTheme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(goal.subtitle)
                    .font(AppTheme.body(12))
                    .foregroundStyle(PlanTheme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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

struct GoalGrid: View {
    @Binding var selection: RunningGoal?

    var body: some View {
        VStack(spacing: 12) {
            ForEach(RunningGoal.allCases) { goal in
                GoalTile(goal: goal, isSelected: selection == goal) {
                    selection = goal
                }
            }
        }
    }
}
