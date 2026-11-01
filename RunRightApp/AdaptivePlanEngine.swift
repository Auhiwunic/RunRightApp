//
//  AdaptivePlanEngine.swift
//  RunRightApp
//
//  Makes the weekly plan ADAPTIVE: it reconciles what the plan says with what
//  the runner actually did, using standard coaching rules — the same class of
//  adjustment the big adaptive platforms make, done deterministically on device.
//
//  Rules (priority: long run > quality > easy):
//  - Missed LONG RUN: it is the anchor workout, so it moves to today (or the
//    next free day). Whatever it displaces is re-homed onto a later rest day or
//    dropped. If a run this week already covered ~the long distance, it counts
//    as done instead. The day AFTER the new long run is never left hard.
//  - Missed QUALITY (tempo/intervals): rescheduled onto the first future easy
//    or rest day that has no hard neighbors; if no safe slot exists it is
//    dropped — quality is never stacked against other hard days.
//  - Missed EASY/RECOVERY: dropped silently. Chasing missed easy miles adds
//    injury risk for no fitness gain.
//
//  The engine only ever writes TODAY-or-later days (past days keep what was
//  planned; a relocated workout's old slot becomes rest so it isn't duplicated).
//  Evaluation is cheap and idempotent: it re-runs on foreground/run-saved and
//  only saves when something actually changed.
//

import Foundation
import FirebaseAuth

@MainActor
final class AdaptivePlanEngine {
    static let shared = AdaptivePlanEngine()
    private init() {}

    private static let noteKey = "plan.adaptationNote"
    private static let noteDayKey = "plan.adaptationNoteDay"
    private var lastEvaluationKey = ""

    /// The adjustment note to show on the Run tab (nil when none was made today).
    static var todaysNote: String? {
        guard UserDefaults.standard.string(forKey: noteDayKey) == dayKey(Date()) else { return nil }
        return UserDefaults.standard.string(forKey: noteKey)
    }

    // MARK: - Evaluation

    /// Reconcile this week's plan with this week's completed runs. Called on
    /// app foreground and after every saved run; skips repeat work for the same
    /// (week, day, run-count) state.
    func evaluateIfNeeded() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let todayIdx = Self.mondayIndex(of: Date())
        guard todayIdx > 0 else { return }   // Monday: nothing can be missed yet

        let weekId = PlanRepository.shared.weekId(for: Date())
        // A fetch failure must NOT read as "the user ran nothing" — that would
        // rewrite the plan off a network blip. Bail and retry on the next trigger.
        let runs: [RunSummaryDTO]
        do {
            runs = try await RunRepository.shared.fetchRunsForWeek(uid: uid, date: Date())
        } catch {
            return
        }
        let evalKey = "\(weekId)|\(todayIdx)|\(runs.count)"
        guard evalKey != lastEvaluationKey else { return }

        guard var week = try? await PlanRepository.shared.loadWeeklyPlan(uid: uid, weekId: weekId),
              week.count == 7 else { return }   // transient load failure — key unset, retries next trigger
        lastEvaluationKey = evalKey

        let milesByDay = Self.milesByDay(runs)
        guard let note = Self.adapt(week: &week, completedMilesByDay: milesByDay, todayIndex: todayIdx) else {
            return
        }

        do {
            try await PlanRepository.shared.saveWeeklyPlan(uid: uid, weekId: weekId, days: week)
            UserDefaults.standard.set(note, forKey: Self.noteKey)
            UserDefaults.standard.set(Self.dayKey(Date()), forKey: Self.noteDayKey)
            NotificationCenter.default.post(name: .planUpdated, object: nil)
        } catch {
            // Save failed — leave the plan untouched and allow a retry.
            lastEvaluationKey = ""
        }
    }

    // MARK: - The adaptation rules (pure + deterministic)

    /// Apply the coaching rules to `week`. Returns a human note describing the
    /// change, or nil when the plan already matches reality.
    static func adapt(week: inout [DayPlan], completedMilesByDay: [Int: Double], todayIndex: Int) -> String? {
        guard week.count == 7, (1...6).contains(todayIndex) else { return nil }

        func plannedMiles(_ d: DayPlan) -> Double? { parseMiles(d.totalDistance) }
        func isHard(_ d: DayPlan) -> Bool {
            !d.isRest && ["Long Run", "Medium Long", "Tempo", "Intervals"].contains(d.runType)
        }
        func isDone(_ i: Int) -> Bool {
            guard !week[i].isRest else { return true }
            let logged = completedMilesByDay[i] ?? 0
            let need = max(0.75, (plannedMiles(week[i]) ?? 3) * 0.5)
            return logged >= need
        }
        func ranAnything(_ i: Int) -> Bool { (completedMilesByDay[i] ?? 0) > 0.25 }

        let missed = (0..<todayIndex).filter { !week[$0].isRest && !isDone($0) }
        guard !missed.isEmpty else { return nil }

        // ---- Missed long run: the anchor workout gets rescued first.
        if let li = missed.first(where: { week[$0].runType == "Long Run" }) {
            let long = week[li]
            // Credit: a run this week that already covered ~the long distance
            // means the work happened, just not on the planned day. Returns a
            // note so the cleared slot actually SAVES (a nil here would discard
            // the mutation and leave the stale long run shadowing the week).
            if let dist = plannedMiles(long),
               let best = completedMilesByDay.values.max(), best >= dist * 0.85 {
                week[li] = restDay(named: long.dayName)
                return "Plan adjusted: your \(String(format: "%.1f", best)) mi run already covered \(long.dayName)'s long run."
            }

            // Today is the new home unless the user already ran today. A rest
            // day today is fair game — rescuing the long run outranks resting
            // (treating rest as "occupied" made the rescue impossible on weeks
            // that end in a rest day, which is exactly the common layout).
            var target = todayIndex
            if ranAnything(target) { target += 1 }
            guard target <= 6, week[target].runType != "Long Run" else { return nil }

            let displaced = week[target]
            var moved = long
            moved.dayName = week[target].dayName
            week[target] = moved
            week[li] = restDay(named: long.dayName)   // no duplicate long runs
            var note = "Plan adjusted: you missed \(long.dayName)'s long run, so it's today's run now."
            if target != todayIndex {
                note = "Plan adjusted: you missed \(long.dayName)'s long run, so it moved to \(moved.dayName)."
            }

            // Re-home a displaced easy run onto a later rest day; quality only
            // lands where it keeps a gap from hard days. Otherwise it's dropped.
            if !displaced.isRest {
                var rehomed = false
                if target + 1 <= 6 {
                    for t in (target + 1)...6 where week[t].isRest {
                        let prevHard = isHard(week[t - 1])
                        let nextHard = t + 1 <= 6 ? isHard(week[t + 1]) : false
                        if isHard(displaced) && (prevHard || nextHard) { continue }
                        var d2 = displaced
                        d2.dayName = week[t].dayName
                        week[t] = d2
                        note += " Your \(displaced.runType.lowercased()) moved to \(d2.dayName)."
                        rehomed = true
                        break
                    }
                }
                if !rehomed {
                    note += " Your \(displaced.runType.lowercased()) is dropped this week."
                }
            }

            // Never two hard days in a row: ease the day after the new long run.
            if target + 1 <= 6, isHard(week[target + 1]) {
                week[target + 1] = eased(week[target + 1])
                note += " \(week[target + 1].dayName) is eased so you can recover."
            }
            return note
        }

        // ---- Missed quality: reschedule only into a slot with no hard neighbors.
        if let qi = missed.last(where: { ["Tempo", "Intervals"].contains(week[$0].runType) }) {
            let quality = week[qi]
            for t in todayIndex...6 {
                if ranAnything(t) { continue }   // rest days ARE valid slots
                let slot = week[t]
                guard slot.isRest || ["Easy", "Recovery"].contains(slot.runType) else { continue }
                // The quality run's own old slot becomes rest after the move,
                // so it must not count as a hard neighbor here.
                let prevHard = t - 1 >= 0 && t - 1 != qi && isHard(week[t - 1])
                let nextHard = t + 1 <= 6 && t + 1 != qi && isHard(week[t + 1])
                if prevHard || nextHard { continue }
                var moved = quality
                moved.dayName = slot.dayName
                week[t] = moved
                week[qi] = restDay(named: quality.dayName)
                if t == todayIndex {
                    return "Plan adjusted: you missed \(quality.dayName)'s \(quality.runType.lowercased()), so it's today's run now."
                }
                return "Plan adjusted: you missed \(quality.dayName)'s \(quality.runType.lowercased()), so it moved to \(moved.dayName)."
            }
            return nil   // no safe slot — quality is quietly dropped, never stacked
        }

        // ---- Missed easy/recovery: dropped, no reshuffle.
        return nil
    }

    // MARK: - Helpers

    private static func restDay(named name: String) -> DayPlan {
        DayPlan(dayName: name, runType: "Rest", isRest: true,
                totalDistance: "—", targetPace: "—", segments: [], zoneTargets: [])
    }

    /// Downgrade a hard day to an easy run (used to protect the day after a
    /// rescheduled long run).
    private static func eased(_ plan: DayPlan) -> DayPlan {
        var p = plan
        p.runType = "Easy"
        p.isRest = false
        let miles = parseMiles(p.totalDistance) ?? 3
        let down = max(1.5, (miles * 0.7 * 10).rounded() / 10)
        p.totalDistance = "\(down) mi"
        p.segments = [WorkoutSegment(name: "Easy Run", distance: p.totalDistance, pace: p.targetPace)]
        p.zoneTargets = [ZoneTarget(zoneName: "Zone 2", minutes: Int(down * 10), colorHex: "#5ECC3A")]
        return p
    }

    static func parseMiles(_ label: String) -> Double? {
        Double(label.lowercased()
            .replacingOccurrences(of: "mi", with: "")
            .trimmingCharacters(in: .whitespaces))
    }

    /// Total logged miles per plan index (Mon=0 … Sun=6) for this week's runs.
    static func milesByDay(_ runs: [RunSummaryDTO]) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for run in runs {
            let idx = mondayIndex(of: run.startTime)
            out[idx, default: 0] += run.distanceMeters / 1609.344
        }
        return out
    }

    /// Calendar weekday → Mon=0 … Sun=6 (matches the plan array order).
    static func mondayIndex(of date: Date) -> Int {
        (Calendar.current.component(.weekday, from: date) + 5) % 7
    }

    private static func dayKey(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
}
