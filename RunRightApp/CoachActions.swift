//
//  CoachActions.swift
//  RunRightApp
//
//  Lets the AI coach take real actions, not just chat. The coachChat function
//  returns an optional structured `action` alongside its reply; this file parses
//  it and applies it to the user's actual weekly plan (PlanRepository) or triggers
//  a profile rebuild. Day adjustments ("easier run tomorrow") operate directly on
//  the saved [DayPlan]; profile rebuilds re-run onboarding and regenerate the week.
//

import Foundation
import FirebaseAuth

extension Notification.Name {
    /// Posted after the coach (or onboarding) writes a new weekly plan, so RunView
    /// and Home reload instead of showing a stale week.
    static let planUpdated = Notification.Name("gaita.planUpdated")
}

/// A structured intent the coach can return. `null` action = plain chat reply.
enum CoachAction: Equatable {
    /// Change a single day: change is "easier" | "harder" | "rest".
    case adjustDay(day: String, change: String)
    /// Move a run from one day to another; the source day becomes rest.
    case moveRun(from: String, to: String)
    /// Exchange two days' runs.
    case swapDays(a: String, b: String)
    /// Scale every run in the week: change is "easier" | "harder".
    case adjustWeek(change: String)
    /// The user asked to change their training profile — re-run onboarding.
    case editProfile

    init?(json: [String: Any]) {
        guard let type = json["type"] as? String else { return nil }
        switch type {
        case "adjust_day":
            let day = (json["day"] as? String)?.lowercased() ?? "tomorrow"
            let change = (json["change"] as? String)?.lowercased() ?? "easier"
            self = .adjustDay(day: day, change: change)
        case "move_run":
            let from = (json["day"] as? String)?.lowercased() ?? "tomorrow"
            let to = (json["to"] as? String)?.lowercased() ?? "sunday"
            self = .moveRun(from: from, to: to)
        case "swap_days":
            guard let a = (json["day"] as? String)?.lowercased(),
                  let b = (json["to"] as? String)?.lowercased() else { return nil }
            self = .swapDays(a: a, b: b)
        case "adjust_week":
            self = .adjustWeek(change: (json["change"] as? String)?.lowercased() ?? "easier")
        case "edit_profile":
            self = .editProfile
        default:
            return nil
        }
    }
}

/// The coach's full response: the text to show, plus an optional action to run.
struct CoachReply {
    let text: String
    let action: CoachAction?
}

enum CoachPlanActions {

    /// Weekday order used across the app (Mon = index 0 … Sun = index 6).
    private static let weekOrder = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]

    /// Run a plan-changing action and return its confirmation. Returns nil for
    /// `editProfile` (the caller decides how to present onboarding) and for any
    /// action that couldn't apply. Shared by the coach chat and the run-screen
    /// "Hey Gaita" listener.
    @MainActor
    static func apply(_ action: CoachAction) async -> String? {
        switch action {
        case let .adjustDay(day, change): return await applyAdjustDay(day: day, change: change)
        case let .moveRun(from, to):      return await applyMoveRun(from: from, to: to)
        case let .swapDays(a, b):         return await applySwapDays(a: a, b: b)
        case let .adjustWeek(change):     return await applyAdjustWeek(change: change)
        case .editProfile:               return nil
        }
    }

    // MARK: - Apply actions to the saved plan

    /// Load this week's plan (or the default), run a transform that mutates it and
    /// returns a chat confirmation, then save + notify the UI. Returns nil (no
    /// save) when not signed in or the transform declines.
    @MainActor
    private static func mutateWeek(_ transform: (inout [DayPlan]) -> String?) async -> String? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        let weekId = PlanRepository.shared.weekId(for: Date())

        var week: [DayPlan]
        do {
            if let saved = try await PlanRepository.shared.loadWeeklyPlan(uid: uid, weekId: weekId), saved.count == 7 {
                week = saved
            } else {
                week = DayPlan.defaultWeek()   // genuinely no plan yet → seed from default
            }
        } catch {
            // Transient load failure (offline): do NOT fall back to defaultWeek and
            // save it — that would overwrite the user's real personalized plan.
            return "I couldn't reach your plan just now. Try that again in a moment."
        }

        guard let confirmation = transform(&week) else { return nil }

        do {
            try await PlanRepository.shared.saveWeeklyPlan(uid: uid, weekId: weekId, days: week)
            NotificationCenter.default.post(name: .planUpdated, object: nil)
        } catch {
            return nil
        }
        return confirmation
    }

    /// Change one day (easier / harder / rest).
    @MainActor
    static func applyAdjustDay(day: String, change: String) async -> String? {
        await mutateWeek { week in
            guard let idx = resolveDayIndex(day) else { return nil }
            let dayName = week[idx].dayName
            week[idx] = adjusted(week[idx], change: change)
            switch change {
            case "rest":   return "Done. I turned \(dayName) into a rest day. Your other runs stay the same."
            case "harder": return "Done. I bumped \(dayName) up a notch. Check the Run tab for the new target."
            default:       return "Done. I made \(dayName) easier, shorter with a relaxed pace. It's on your Run tab."
            }
        }
    }

    /// Move a run to another day; the source day becomes rest.
    @MainActor
    static func applyMoveRun(from: String, to: String) async -> String? {
        await mutateWeek { week in
            guard let fi = resolveDayIndex(from), let ti = resolveDayIndex(to), fi != ti else { return nil }
            let fromName = week[fi].dayName, toName = week[ti].dayName
            let what = week[fi].isRest ? "rest day" : week[fi].runType.lowercased()
            // If the destination already has a run, swap the two days instead of
            // overwriting it — silently deleting a scheduled workout is data loss (#5).
            if !week[ti].isRest {
                var newTo = week[fi]; newTo.dayName = toName
                var newFrom = week[ti]; newFrom.dayName = fromName
                week[ti] = newTo
                week[fi] = newFrom
                return "Done. \(toName) already had a run, so I swapped it with \(fromName) instead of dropping it."
            }
            var moved = week[fi]; moved.dayName = toName
            week[ti] = moved
            week[fi] = restDay(named: fromName)
            return "Done. I moved your \(what) to \(toName), and \(fromName) is now rest."
        }
    }

    /// Swap two days' runs.
    @MainActor
    static func applySwapDays(a: String, b: String) async -> String? {
        await mutateWeek { week in
            guard let ai = resolveDayIndex(a), let bi = resolveDayIndex(b), ai != bi else { return nil }
            let aName = week[ai].dayName, bName = week[bi].dayName
            var newA = week[bi]; newA.dayName = aName
            var newB = week[ai]; newB.dayName = bName
            week[ai] = newA; week[bi] = newB
            return "Done. I swapped \(aName) and \(bName)."
        }
    }

    /// Scale every non-rest day in the week easier or harder.
    @MainActor
    static func applyAdjustWeek(change: String) async -> String? {
        await mutateWeek { week in
            for i in week.indices where !week[i].isRest {
                week[i] = adjusted(week[i], change: change)
            }
            return change == "harder"
                ? "Done. I turned up every run this week. Take the rest days seriously."
                : "Done. I made your whole week easier, shorter and more relaxed. It's on your Run tab."
        }
    }

    private static func restDay(named: String) -> DayPlan {
        DayPlan(dayName: named, runType: "Rest", isRest: true,
                totalDistance: "—", targetPace: "—", segments: [], zoneTargets: [])
    }

    /// Map "tomorrow" / "today" / a weekday name to an index in weekOrder.
    private static func resolveDayIndex(_ day: String) -> Int? {
        let d = day.lowercased().trimmingCharacters(in: .whitespaces)
        let todayIdx = todayIndex()
        if d.contains("tomorrow") {
            // On Sunday (todayIdx 6) "tomorrow" is NEXT week's Monday, which isn't
            // in this week's plan — wrapping to index 0 used to mutate the already-
            // past Monday. Decline instead so the coach doesn't change the wrong day.
            let t = todayIdx + 1
            return t <= 6 ? t : nil
        }
        if d.contains("today") { return todayIdx }
        for (i, name) in weekOrder.enumerated() where d.contains(name.lowercased()) { return i }
        // No recognizable day → return nil so the caller can decline rather than
        // silently mutating the WRONG day from a hallucinated LLM day string.
        return nil
    }

    /// Today as a Mon=0…Sun=6 index (matches the plan array order).
    private static func todayIndex() -> Int {
        // Calendar weekday: 1=Sun … 7=Sat. Convert to Mon=0.
        let wd = Calendar.current.component(.weekday, from: Date())
        return (wd + 5) % 7
    }

    // MARK: - The actual change

    private static func adjusted(_ plan: DayPlan, change: String) -> DayPlan {
        var p = plan
        switch change {
        case "rest":
            p.runType = "Rest"; p.isRest = true
            p.totalDistance = "—"; p.targetPace = "—"
            p.segments = []; p.zoneTargets = []

        case "harder":
            p.isRest = false
            if p.runType == "Rest" || p.runType == "Recovery" || p.runType == "Easy" { p.runType = "Tempo" }
            let miles = parseMiles(p.totalDistance) ?? 3
            let up = (miles * 1.2).rounded(toPlaces: 1)
            p.totalDistance = "\(up) mi"
            p.targetPace = easePace(p.targetPace, bySeconds: -20)

        default: // "easier"
            p.isRest = false
            p.runType = (p.runType == "Recovery") ? "Recovery" : "Easy"
            let miles = parseMiles(p.totalDistance) ?? 3
            let down = max(1.5, (miles * 0.7).rounded(toPlaces: 1))
            p.totalDistance = "\(down) mi"
            let pace = easePace(p.targetPace, bySeconds: 30)
            p.targetPace = pace
            p.segments = [
                WorkoutSegment(name: "Warm Up", distance: "0.5 mi", pace: easePace(pace, bySeconds: 30)),
                WorkoutSegment(name: "Easy Run", distance: "\(max(0.5, down - 1).rounded(toPlaces: 1)) mi", pace: pace),
                WorkoutSegment(name: "Cool Down", distance: "0.5 mi", pace: easePace(pace, bySeconds: 30))
            ]
            p.zoneTargets = [ZoneTarget(zoneName: "Zone 2", minutes: Int(down * 10), colorHex: "#5ECC3A")]
        }
        return p
    }

    // MARK: - WeeklyPlan (generator output) → [DayPlan] (what the app saves)

    /// Convert a generated WeeklyPlan into the 7-day [DayPlan] the app persists,
    /// filling unscheduled days as rest. Used when a profile rebuild regenerates
    /// the week.
    static func dayPlans(from plan: WeeklyPlan) -> [DayPlan] {
        var byWeekday: [String: PlannedRun] = [:]
        for run in plan.runs { byWeekday[weekdayName(run.weekday)] = run }

        return weekOrder.map { name in
            if let run = byWeekday[name] {
                let pace = run.targetPaceSecPerMile.map { paceLabel($0) } ?? "varies"
                let dist = run.distanceLabel.isEmpty ? "—" : run.distanceLabel
                return DayPlan(
                    dayName: name,
                    runType: runTypeLabel(run.runType),
                    isRest: false,
                    totalDistance: dist,
                    targetPace: pace,
                    segments: [WorkoutSegment(name: run.title, distance: dist, pace: pace)],
                    zoneTargets: []
                )
            }
            return DayPlan(dayName: name, runType: "Rest", isRest: true,
                           totalDistance: "—", targetPace: "—", segments: [], zoneTargets: [])
        }
    }

    // MARK: - small helpers

    private static func weekdayName(_ w: Weekday) -> String {
        switch w {
        case .monday: return "Monday"; case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"; case .thursday: return "Thursday"
        case .friday: return "Friday"; case .saturday: return "Saturday"
        case .sunday: return "Sunday"
        }
    }

    private static func runTypeLabel(_ t: RunType) -> String {
        switch t {
        case .easy: return "Easy"
        case .longRun: return "Long Run"
        case .mediumLong: return "Medium Long"   // distinct label so a week never has two "Long Run" days (adaptive engine keys off it)
        case .tempo, .steadyRun: return "Tempo"
        case .workout, .strides: return "Intervals"
        case .recovery, .walkRun: return "Recovery"
        }
    }

    private static func parseMiles(_ label: String) -> Double? {
        Double(label.lowercased().replacingOccurrences(of: "mi", with: "").trimmingCharacters(in: .whitespaces))
    }

    private static func paceLabel(_ secPerMile: Int) -> String {
        "\(secPerMile / 60):" + String(format: "%02d", secPerMile % 60) + "/mi"
    }

    /// Shift a "m:ss/mi" pace by N seconds (positive = slower/easier). Returns the
    /// original for non-numeric paces like "varies".
    private static func easePace(_ label: String, bySeconds: Int) -> String {
        let cleaned = label.lowercased().replacingOccurrences(of: "/mi", with: "").trimmingCharacters(in: .whitespaces)
        let parts = cleaned.split(separator: ":")
        guard parts.count == 2, let m = Int(parts[0]), let s = Int(parts[1]) else { return label }
        let total = max(240, m * 60 + s + bySeconds)   // never faster than 4:00/mi
        return "\(total / 60):" + String(format: "%02d", total % 60) + "/mi"
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let p = pow(10.0, Double(places))
        return (self * p).rounded() / p
    }
}
