//
//  VoiceAssistantMessageProvider.swift
//  Weekly Plan
//

import Foundation

struct VoiceCoachMessage: Identifiable {
    let id = UUID()
    let category: String
    let text: String

    var paceCategory: PaceCoachCategory? {
        PaceCoachCategory(rawValue: category)
    }
}

enum VoiceAssistantMessageProvider {
    static func messages(for profile: OnboardingProfile, plan: WeeklyPlan) -> [VoiceCoachMessage] {
        PaceCoachCategory.allCases
            .flatMap { categoryMessages(for: $0, profile: profile, plan: plan, run: plan.runs.first) }
            .shuffled()
    }

    static func openingLine(for profile: OnboardingProfile, plan: WeeklyPlan) -> VoiceCoachMessage {
        let nextRun = plan.runs.first
        let runLabel = nextRun.map { "\($0.title.lowercased()) on \(shortDay($0.weekday))" } ?? "your next run"

        return VoiceCoachMessage(
            category: "Mid-run coach",
            text: "Sample prompts for \(runLabel). Tap through to hear what I'd say if you're on pace, a little slow, or a little fast."
        )
    }

    /// Picks a contextual message for a live coaching category during a run.
    static func message(
        for category: PaceCoachCategory,
        profile: OnboardingProfile,
        plan: WeeklyPlan,
        run: PlannedRun?,
        mile: Int? = nil,
        excluding: Set<String> = []
    ) -> VoiceCoachMessage {
        let pool = categoryMessages(for: category, profile: profile, plan: plan, run: run, mile: mile)
        if let match = pool.first(where: { !excluding.contains($0.text) }) {
            return match
        }
        return pool.randomElement() ?? msg(category, "Keep going, you're doing great.")
    }

    static func categoryMessages(
        for category: PaceCoachCategory,
        profile: OnboardingProfile,
        plan: WeeklyPlan,
        run: PlannedRun?,
        mile: Int? = nil
    ) -> [VoiceCoachMessage] {
        // One coach, one voice: rally co driver style — clipped, urgent,
        // numbers first. Struggling and GPS fall through to plainer, kinder
        // copy: safety and sensor caveats should never sound like commands.
        if let pack = rallyMessages(for: category, mile: mile) {
            return pack
        }
        switch category {
        case .gpsWeak: return gpsWeakMessages()
        default:       return strugglingMessages(profile: profile, plan: plan)
        }
    }

    // MARK: - Rally pack (co driver style: clipped, urgent, numbers first)
    //
    // Kept deliberately short — timing critical calls, no fluff. Struggling and
    // GPS categories return nil so they fall through to the steady copy: safety
    // and sensor caveats should never sound like commands.
    private static func rallyMessages(for category: PaceCoachCategory, mile: Int?) -> [VoiceCoachMessage]? {
        switch category {
        case .onPace:
            return [
                msg(.onPace, "On target. Hold."),
                msg(.onPace, "Pace good. Steady."),
                msg(.onPace, "Locked in. Don't chase."),
                msg(.onPace, "Clean line. Keep it."),
            ]
        case .slightlySlow:
            return [
                msg(.slightlySlow, "Five down. Lift."),
                msg(.slightlySlow, "Off pace. Quick feet, go."),
                msg(.slightlySlow, "Losing time. Pick it up."),
            ]
        case .slightlyFast:
            return [
                msg(.slightlyFast, "Five quick. Ease off."),
                msg(.slightlyFast, "Too hot. Settle."),
                msg(.slightlyFast, "Ahead of plan. Back it down."),
            ]
        case .tooSlow:
            return [
                msg(.tooSlow, "Big gap. Push one minute, go."),
                msg(.tooSlow, "Well down. Commit or call it an easy day."),
            ]
        case .tooFast:
            return [
                msg(.tooFast, "Way hot. Back off now."),
                msg(.tooFast, "Blowup pace. Ease. Trust the plan."),
            ]
        case .startingOut:
            return [
                msg(.startingOut, "And we're off. Easy first mile."),
                msg(.startingOut, "Go steady. Target comes later."),
            ]
        case .closingIn:
            return [
                msg(.closingIn, "Final stretch. Hold form."),
                msg(.closingIn, "Two hundred out. Quick feet, finish."),
            ]
        case .finished:
            return [
                msg(.finished, "Done. Good stage."),
                msg(.finished, "Stage complete. Strong work."),
            ]
        case .mileSplit:
            return [
                msg(.mileSplit, "Steady."),
                msg(.mileSplit, "Hold rhythm."),
            ]
        case .struggling, .gpsWeak:
            return nil
        }
    }

    // MARK: - Struggling

    private static func strugglingMessages(profile: OnboardingProfile, plan: WeeklyPlan) -> [VoiceCoachMessage] {
        [
            msg(.struggling, "Pace is falling and effort is rising. Consider walking 60 seconds, then reset."),
            msg(.struggling, "Rough patch. Shorten your stride, slow your breath, and get through this mile."),
            msg(.struggling, "You're fighting it today. It's okay to drop pace and finish the run."),
            msg(.struggling, "Form is breaking down. Walk for 30 seconds, shake out your arms, jog again."),
            msg(.struggling, "Bad days happen. Completing the run at any pace still counts."),
            msg(.struggling, "If you can't hold planned pace, switch to effort-based running and call it done."),
        ]
    }

    // MARK: - GPS weak

    private static func gpsWeakMessages() -> [VoiceCoachMessage] {
        [
            msg(.gpsWeak, "GPS signal is weak, so pace coaching is paused until it steadies."),
            msg(.gpsWeak, "Can't get a reliable pace right now. Keep running; I'll check back soon."),
        ]
    }

    // MARK: - Helpers

    private static func msg(_ category: PaceCoachCategory, _ text: String) -> VoiceCoachMessage {
        VoiceCoachMessage(category: category.rawValue, text: text)
    }

    private static func msg(_ category: String, _ text: String) -> VoiceCoachMessage {
        VoiceCoachMessage(category: category, text: text)
    }

    private static func shortDay(_ weekday: Weekday) -> String {
        switch weekday {
        case .sunday: "Sunday"
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        }
    }
}
