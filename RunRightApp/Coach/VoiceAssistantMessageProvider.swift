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
        return pool.randomElement() ?? msg(category, "Keep going — you're doing great.")
    }

    static func categoryMessages(
        for category: PaceCoachCategory,
        profile: OnboardingProfile,
        plan: WeeklyPlan,
        run: PlannedRun?,
        mile: Int? = nil
    ) -> [VoiceCoachMessage] {
        switch category {
        case .onPace:          return onPaceMessages(profile: profile, plan: plan, run: run)
        case .slightlySlow:   return slightlySlowMessages(profile: profile, plan: plan, run: run)
        case .slightlyFast:   return slightlyFastMessages(profile: profile, plan: plan, run: run)
        case .tooSlow:        return tooSlowMessages(profile: profile, plan: plan, run: run)
        case .tooFast:        return tooFastMessages(profile: profile, plan: plan, run: run)
        case .startingOut:    return runStartMessages(profile: profile, plan: plan, run: run)
        case .closingIn:      return runFinishMessages(profile: profile, plan: plan)
        case .finished:       return runCompleteMessages(profile: profile, plan: plan)
        case .struggling:     return strugglingMessages(profile: profile, plan: plan)
        case .gpsWeak:        return gpsWeakMessages()
        case .mileSplit:      return mileSplitMessages(mile: mile ?? 1, profile: profile, plan: plan, run: run)
        }
    }

    // MARK: - On pace

    private static func onPaceMessages(
        profile: OnboardingProfile,
        plan: WeeklyPlan,
        run: PlannedRun?
    ) -> [VoiceCoachMessage] {
        let runContext = runContextLabel(from: run, plan: plan)
        return [
            msg(.onPace, "Right on target. Hold this rhythm — shoulders relaxed, breath steady."),
            msg(.onPace, "Pace check: you're exactly where you should be. Don't chase faster."),
            msg(.onPace, "Nailed it. This is the effort we planned for \(runContext)."),
            msg(.onPace, "Splits look good. Stay smooth — no need to push from here."),
            msg(.onPace, "You're locked in. Keep the same cadence for the next half mile."),
            msg(.onPace, "Perfect. This pace builds fitness without frying your legs."),
            msg(.onPace, "On plan and on pace. Trust this effort and keep going."),
        ]
    }

    // MARK: - Slightly slow

    private static func slightlySlowMessages(
        profile: OnboardingProfile,
        plan: WeeklyPlan,
        run: PlannedRun?
    ) -> [VoiceCoachMessage] {
        let runContext = runContextLabel(from: run, plan: plan)
        var messages = [
            msg(.slightlySlow, "Pace is slightly behind target. Pick up just 5 to 10 seconds per mile — small adjustment."),
            msg(.slightlySlow, "You're a touch slow. Shorten your stride and add a little arm drive."),
            msg(.slightlySlow, "Slightly off pace — not a big deal. Ease into a bit more effort for the next quarter mile."),
            msg(.slightlySlow, "Running a little slow today. Try lifting your knees slightly and see if pace comes back."),
            msg(.slightlySlow, "Behind target by a few seconds per mile. Breathe a little deeper and push gently."),
        ]

        if profile.runningGoal == .getFaster || profile.runningGoal == .trainForRace {
            messages.append(msg(.slightlySlow, "Tempo pace is slipping. You're close — tighten up for the next minute, not the whole run."))
        }

        if runContext.contains("easy") || runContext.contains("recovery") {
            messages.append(msg(.slightlySlow, "Actually, on an easy run, slow is fine. Ignore this unless it feels too sluggish."))
        }

        return messages
    }

    // MARK: - Slightly fast

    private static func slightlyFastMessages(
        profile: OnboardingProfile,
        plan: WeeklyPlan,
        run: PlannedRun?
    ) -> [VoiceCoachMessage] {
        var messages = [
            msg(.slightlyFast, "You're a bit quick. Ease off 5 seconds per mile — save energy for later."),
            msg(.slightlyFast, "Pace is creeping fast. Relax your shoulders and let it settle."),
            msg(.slightlyFast, "Slightly ahead of target. Back off now so you don't pay for it at the end."),
            msg(.slightlyFast, "Running hot. Shorten your effort, not your stride — calm the breathing."),
            msg(.slightlyFast, "A little fast today. This isn't a race — dial it back to planned pace."),
        ]

        if profile.runningGoal == .buildEndurance || profile.experienceLevel == .beginner {
            messages.append(msg(.slightlyFast, "Easy days shouldn't feel like this. Slow down — you should be able to talk."))
        }

        return messages
    }

    // MARK: - Too slow

    private static func tooSlowMessages(
        profile: OnboardingProfile,
        plan: WeeklyPlan,
        run: PlannedRun?
    ) -> [VoiceCoachMessage] {
        [
            msg(.tooSlow, "Pace is well below target. If you feel good, pick it up for the next minute."),
            msg(.tooSlow, "You're dragging today. Check form — are you slouching? Lift your chest and reset."),
            msg(.tooSlow, "Significantly off pace. If legs feel heavy, this might be a recovery day — listen to your body."),
            msg(.tooSlow, "Way slower than planned. Either push the pace or accept an easy day and adjust the plan."),
            msg(.tooSlow, "Splits are dropping. Try a slight surge for 30 seconds to wake your legs up."),
            msg(.tooSlow, "If this is a workout day, you need more effort. If it's easy day, ignore me and keep it slow."),
        ]
    }

    // MARK: - Too fast

    private static func tooFastMessages(
        profile: OnboardingProfile,
        plan: WeeklyPlan,
        run: PlannedRun?
    ) -> [VoiceCoachMessage] {
        [
            msg(.tooFast, "You're way above target pace. Slow down now — this run has a purpose."),
            msg(.tooFast, "Too hot too early. Pull back before you blow up in the second half."),
            msg(.tooFast, "Heart rate is climbing too fast. Ease off until breathing calms down."),
            msg(.tooFast, "This pace won't last. Back off 15 to 20 seconds per mile immediately."),
            msg(.tooFast, "Banking time now means suffering later. Trust the plan and slow down."),
            msg(.tooFast, "You're racing a training run. Relax — championship form comes from disciplined pacing."),
        ]
    }

    // MARK: - Run start

    private static func runStartMessages(
        profile: OnboardingProfile,
        plan: WeeklyPlan,
        run: PlannedRun?
    ) -> [VoiceCoachMessage] {
        guard let run else {
            return [msg(.startingOut, "First mile should feel easy. Don't let adrenaline set the pace.")]
        }

        return [
            msg(.startingOut, "First quarter mile — settle in. Don't chase your target pace yet."),
            msg(.startingOut, "Starting \(run.title.lowercased()). Ease into it for the first 5 minutes."),
            msg(.startingOut, "Warm-up pace only. You'll hit target effort once your legs wake up."),
            msg(.startingOut, "Mile one should feel almost too easy for \(run.title.lowercased()). That's correct."),
            msg(.startingOut, "You're off. Keep the first mile 15 seconds slower than goal pace."),
        ]
    }

    // MARK: - Run finish

    private static func runFinishMessages(profile: OnboardingProfile, plan: WeeklyPlan) -> [VoiceCoachMessage] {
        [
            msg(.closingIn, "Final stretch. If you're on pace, hold steady — don't sprint the finish."),
            msg(.closingIn, "Last half mile. Stay controlled — a strong finish beats a heroic start."),
            msg(.closingIn, "Almost done. Same effort, same form. You trained for this moment."),
            msg(.closingIn, "Home stretch. If you have something left, use it now — not before."),
            msg(.closingIn, "200 meters to go. Quick cadence, relaxed face, finish strong."),
        ]
    }

    // MARK: - Run complete (spoken when the user ends the run)

    private static func runCompleteMessages(profile: OnboardingProfile, plan: WeeklyPlan) -> [VoiceCoachMessage] {
        [
            msg(.finished, "Run complete. Nice work out there."),
            msg(.finished, "That's the run done. Strong effort — recover well."),
            msg(.finished, "Nice work. Walk it out and hydrate."),
            msg(.finished, "Run finished. Be proud of that one."),
            msg(.finished, "Done. Good session — stretch and refuel."),
        ]
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
            msg(.gpsWeak, "GPS signal is weak — pace coaching is paused until it stabilizes."),
            msg(.gpsWeak, "Can't get a reliable pace right now. Keep running; I'll check back soon."),
        ]
    }

    // MARK: - Mile split

    private static func mileSplitMessages(
        mile: Int,
        profile: OnboardingProfile,
        plan: WeeklyPlan,
        run: PlannedRun?
    ) -> [VoiceCoachMessage] {
        let runContext = runContextLabel(from: run, plan: plan)
        return [
            msg(.mileSplit, "Mile \(mile) complete. Stay smooth for \(runContext)."),
            msg(.mileSplit, "That's mile \(mile). Check in with your breathing and form."),
            msg(.mileSplit, "Mile \(mile) done. Same effort, same rhythm."),
        ]
    }

    // MARK: - Helpers

    private static func msg(_ category: PaceCoachCategory, _ text: String) -> VoiceCoachMessage {
        VoiceCoachMessage(category: category.rawValue, text: text)
    }

    private static func msg(_ category: String, _ text: String) -> VoiceCoachMessage {
        VoiceCoachMessage(category: category, text: text)
    }

    private static func runContextLabel(from run: PlannedRun?, plan: WeeklyPlan) -> String {
        guard let run else { return primaryRunContext(from: plan) }
        return run.title.lowercased()
    }

    private static func primaryRunContext(from plan: WeeklyPlan) -> String {
        guard let run = plan.runs.first else { return "today's run" }
        return run.title.lowercased()
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
