//
//  PlanMandate.swift
//  Weekly Plan
//

import Foundation

struct PlanMandate {
    enum Severity { case warning, critical }
    let severity: Severity
    let message: String
    let planNote: String
}

enum PlanMandateChecker {
    static func check(
        goal: RunningGoal,
        experience: ExperienceLevel,
        dayCount: Int,
        mileage: WeeklyMileageRange?
    ) -> [PlanMandate] {
        dayMandates(goal: goal, experience: experience, dayCount: dayCount)
        + mileageMandates(goal: goal, experience: experience, mileage: mileage)
        + profileMandates(goal: goal, experience: experience)
    }

    // MARK: - Day mandates

    private static func dayMandates(
        goal: RunningGoal,
        experience: ExperienceLevel,
        dayCount: Int
    ) -> [PlanMandate] {
        var mandates: [PlanMandate] = []

        if (goal == .getFaster || goal == .trainForRace) && dayCount > 0 && dayCount < 3 {
            mandates.append(PlanMandate(
                severity: .critical,
                message: "This goal needs at least 3 days to be safe and effective.",
                planNote: "Plan restructured — only \(dayCount == 1 ? "1 day" : "2 days") selected."
            ))
        } else if (goal == .getFaster || goal == .trainForRace) && dayCount >= 3 && dayCount < 4 {
            mandates.append(PlanMandate(
                severity: .warning,
                message: "Speed and race training really needs 4+ days. We'll do what we can with fewer.",
                planNote: "Limited days — quality sessions are compressed."
            ))
        }

        if goal == .buildEndurance && dayCount > 0 && dayCount < 3 {
            mandates.append(PlanMandate(
                severity: .warning,
                message: "Endurance builds best with 3+ days — a long run alone isn't enough.",
                planNote: "Long run only — add 2+ days for real base building."
            ))
        }

        if experience == .competitive && dayCount > 0 && dayCount < 4 {
            mandates.append(PlanMandate(
                severity: .warning,
                message: "Competitive runners typically need 4–6 days. You've picked fewer.",
                planNote: "High intensity compressed into limited days."
            ))
        }

        return mandates
    }

    // MARK: - Mileage mandates

    private static func mileageMandates(
        goal: RunningGoal,
        experience: ExperienceLevel,
        mileage: WeeklyMileageRange?
    ) -> [PlanMandate] {
        guard let mileage else { return [] }
        var mandates: [PlanMandate] = []

        // Goals that need meaningful weekly volume — 0–5 is too low
        if mileage == .zeroToFive {
            switch goal {
            case .getFaster:
                mandates.append(PlanMandate(
                    severity: experience == .competitive ? .critical : .warning,
                    message: "Chasing a PR on 0–5 miles/week isn't enough volume. Aim for at least 5–15.",
                    planNote: "Volume bumped — PR training needs more weekly miles."
                ))
            case .trainForRace:
                mandates.append(PlanMandate(
                    severity: .warning,
                    message: "Race training needs a base — 0–5 miles is too low to build fitness.",
                    planNote: "Volume increased to support race prep."
                ))
            case .buildEndurance:
                mandates.append(PlanMandate(
                    severity: .warning,
                    message: "Building endurance requires more weekly volume — consider 5–15 miles.",
                    planNote: "Mileage adjusted upward for base building."
                ))
            case .loseWeight:
                mandates.append(PlanMandate(
                    severity: .warning,
                    message: "Weight loss benefits from more consistency — 5–15 miles/week is a better range.",
                    planNote: "Mileage adjusted upward for sustainable calorie burn."
                ))
            default:
                break
            }

            if experience == .competitive && goal != .justStarting && goal != .clearMyHead && goal != .stayActive {
                if !mandates.contains(where: { $0.message.contains("competitive") }) {
                    mandates.append(PlanMandate(
                        severity: .warning,
                        message: "That's low for a competitive runner — 5–15+ miles is more typical.",
                        planNote: "Mileage is low for your experience — volume bumped slightly."
                    ))
                }
            }
        }

        // High mileage for beginners
        if goal == .justStarting,
           mileage == .fifteenToTwentyFive || mileage == .twentyFivePlus {
            mandates.append(PlanMandate(
                severity: .warning,
                message: "That's a lot of miles for a first week — we'll scale it back.",
                planNote: "Volume capped for safety."
            ))
        }

        // Competitive runners chasing speed on modest volume
        if experience == .competitive,
           goal == .getFaster || goal == .trainForRace,
           mileage == .fiveToFifteen {
            mandates.append(PlanMandate(
                severity: .warning,
                message: "Competitive PR training usually needs 15+ miles/week — we'll push volume where we can.",
                planNote: "Volume nudged up for competitive race prep."
            ))
        }

        return mandates
    }

    // MARK: - Cross-profile mandates (no inline message)

    private static func profileMandates(
        goal: RunningGoal,
        experience: ExperienceLevel
    ) -> [PlanMandate] {
        if goal == .getFaster && experience == .beginner {
            return [PlanMandate(
                severity: .warning,
                message: "",
                planNote: "Speed work added carefully — base fitness first."
            )]
        }
        return []
    }

    // MARK: - Public helpers

    static func inlineWarningsForDays(
        goal: RunningGoal,
        experience: ExperienceLevel,
        dayCount: Int
    ) -> [PlanMandate] {
        dayMandates(goal: goal, experience: experience, dayCount: dayCount)
            .filter { !$0.message.isEmpty }
    }

    static func inlineWarningsForMileage(
        goal: RunningGoal,
        experience: ExperienceLevel,
        mileage: WeeklyMileageRange
    ) -> [PlanMandate] {
        mileageMandates(goal: goal, experience: experience, mileage: mileage)
            .filter { !$0.message.isEmpty }
    }

    static func planNotes(from profile: OnboardingProfile) -> [String] {
        check(
            goal: profile.runningGoal,
            experience: profile.experienceLevel,
            dayCount: profile.availableDays.count,
            mileage: profile.weeklyMileage
        )
        .map(\.planNote)
        .filter { !$0.isEmpty }
    }

    /// Minimum weekly miles the generator should use when the user's selection is below goal requirements.
    static func effectiveMileageFloor(
        goal: RunningGoal,
        experience: ExperienceLevel,
        mileage: WeeklyMileageRange
    ) -> Double? {
        switch mileage {
        case .zeroToFive:
            switch goal {
            case .getFaster:       return experience == .competitive ? 12 : 8
            case .trainForRace:    return 10
            case .buildEndurance:  return 10
            case .loseWeight:      return 8
            default:               return nil
            }
        case .fiveToFifteen:
            if experience == .competitive && (goal == .getFaster || goal == .trainForRace) {
                return 14
            }
            return nil
        default:
            return nil
        }
    }
}
