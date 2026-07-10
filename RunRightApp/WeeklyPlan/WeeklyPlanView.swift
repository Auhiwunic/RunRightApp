//
//  WeeklyPlanView.swift
//  Weekly Plan
//

import SwiftUI

struct WeeklyPlanView: View {
    let profile: OnboardingProfile
    let onRestart: () -> Void
    var onDone: () -> Void = {}

    private var plan: WeeklyPlan {
        WeeklyPlanGenerator.generate(from: profile)
    }

    var body: some View {
        ZStack {
            AnimatedBackground()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        focusCard
                        runsSection
                        restartButton
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
                }

                // Pinned so it's always reachable without scrolling past the schedule.
                continueButton
                    .padding(.horizontal, 28)
                    .padding(.top, 10)
                    .padding(.bottom, 20)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var continueButton: some View {
        Button(action: onDone) {
            Text("Continue")
                .font(AppTheme.bodySemibold(17))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(PlanTheme.accent)
                .foregroundStyle(.black)
                .clipShape(Capsule())
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your week")
                .font(AppTheme.display(32))
                .foregroundStyle(PlanTheme.textPrimary)

            Text(plan.totalMilesLabel)
                .font(AppTheme.bodySemibold(15))
                .foregroundStyle(PlanTheme.accent)
        }
    }

    // MARK: - Focus card

    private var focusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(plan.focusTitle)
                .font(AppTheme.bodySemibold(17))
                .foregroundStyle(PlanTheme.textPrimary)

            Text(plan.focusDetail)
                .font(AppTheme.body(15))
                .foregroundStyle(PlanTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: PlanTheme.cardRadius)
                .fill(PlanTheme.card)
        )
    }

    // MARK: - Runs

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Schedule")
                .font(AppTheme.bodySemibold(17))
                .foregroundStyle(PlanTheme.textPrimary)

            ForEach(plan.runs) { run in
                runCard(run)
            }
        }
    }

    private func runCard(_ run: PlannedRun) -> some View {
        HStack(alignment: .top, spacing: 16) {
            // Day column
            VStack(spacing: 2) {
                Text(shortDayName(for: run.weekday))
                    .font(AppTheme.bodySemibold(12))
                    .foregroundStyle(PlanTheme.accent)

                Text(run.weekday.shortLabel)
                    .font(AppTheme.headBold(20))
                    .foregroundStyle(PlanTheme.textPrimary)
            }
            .frame(width: 36)

            // Run info
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center) {
                    Text(run.title)
                        .font(AppTheme.bodySemibold(15))
                        .foregroundStyle(PlanTheme.textPrimary)

                    Spacer()

                    // Distance badge
                    Text(run.distanceLabel)
                        .font(AppTheme.bodySemibold(12))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(PlanTheme.accent)
                        .clipShape(Capsule())
                }

                // Run type tag
                runTypeTag(run.runType)

                Text(run.detail)
                    .font(AppTheme.body(12))
                    .foregroundStyle(PlanTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: PlanTheme.cardRadius)
                .fill(PlanTheme.card)
        )
    }

    private func runTypeTag(_ runType: RunType) -> some View {
        Text(runType.rawValue)
            .font(AppTheme.meta(10))
            .foregroundStyle(runType.isHighIntensity ? Color.black : PlanTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(runType.isHighIntensity
                          ? PlanTheme.accent
                          : PlanTheme.barUnselected)
            )
    }

    // MARK: - Restart

    private var restartButton: some View {
        Button(action: onRestart) {
            Text("Restart onboarding")
                .font(AppTheme.bodySemibold(17))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(PlanTheme.card)
                .foregroundStyle(PlanTheme.textPrimary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(PlanTheme.textSecondary.opacity(0.3), lineWidth: 1)
                )
        }
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private func shortDayName(for weekday: Weekday) -> String {
        switch weekday {
        case .sunday: "Sun"
        case .monday: "Mon"
        case .tuesday: "Tue"
        case .wednesday: "Wed"
        case .thursday: "Thu"
        case .friday: "Fri"
        case .saturday: "Sat"
        }
    }
}

#Preview {
    WeeklyPlanView(
        profile: OnboardingProfile(
            runningGoal: .trainForRace,
            experienceLevel: .regularRunner,
            availableDays: [2, 4, 6, 7],
            weeklyMileage: .fiveToFifteen
        ),
        onRestart: {}
    )
}
