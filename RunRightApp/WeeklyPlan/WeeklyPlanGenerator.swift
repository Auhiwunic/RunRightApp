//
//  WeeklyPlanGenerator.swift
//  Weekly Plan
//

import Foundation

enum WeeklyPlanGenerator {

    // MARK: - Public entry point

    static func generate(from profile: OnboardingProfile) -> WeeklyPlan {
        // Order Monday-first. Weekday raw values are Sunday=1…Saturday=7, so a
        // plain sort puts Sunday first and days.prefix(count) systematically drops
        // Saturday when the user picks more days than their run count (#9).
        let sortedDays = profile.availableDays
            .compactMap { Weekday(rawValue: $0) }
            .sorted { (($0.rawValue + 5) % 7) < (($1.rawValue + 5) % 7) }
        let mandateNotes = PlanMandateChecker.planNotes(from: profile)

        let totalMiles = resolvedWeeklyMiles(profile: profile)
        let template = weekTemplate(
            goal: profile.runningGoal,
            experience: profile.experienceLevel,
            days: sortedDays
        )
        let assignedDays = assignDays(sortedDays, to: template, goal: profile.runningGoal)
        let runs = buildRuns(
            assignments: assignedDays,
            totalMiles: totalMiles,
            goal: profile.runningGoal,
            experience: profile.experienceLevel
        )

        return WeeklyPlan(
            focusTitle: focusTitle(for: profile.runningGoal),
            focusDetail: focusDetail(for: profile.runningGoal, experience: profile.experienceLevel),
            totalMilesLabel: formatTotalMiles(totalMiles),
            runs: runs,
            notes: mandateNotes
        )
    }

    // MARK: - Mileage

    private static func resolvedWeeklyMiles(profile: OnboardingProfile) -> Double {
        var base: Double
        switch profile.weeklyMileage {
        case .zeroToFive:           base = 4
        case .fiveToFifteen:        base = 10
        case .fifteenToTwentyFive:  base = 18
        case .twentyFivePlus:       base = 28
        }

        // Experience modifier
        switch profile.experienceLevel {
        case .beginner:     base *= 0.85
        case .competitive:  base *= 1.1
        default: break
        }

        // Mandate caps and bumps
        if profile.runningGoal == .justStarting {
            base = min(base, 8)
        }

        if let floor = PlanMandateChecker.effectiveMileageFloor(
            goal: profile.runningGoal,
            experience: profile.experienceLevel,
            mileage: profile.weeklyMileage
        ) {
            base = max(base, floor)
        }

        // Goal adjustments
        switch profile.runningGoal {
        case .trainForRace, .buildEndurance: base *= 1.08
        case .loseWeight: base *= 1.05
        default: break
        }

        return max(base, 3)
    }

    // MARK: - Week templates

    /// Returns an ordered list of RunType slots for the given goal and available day count.
    /// The list length matches the number of run days to schedule (may be <= sortedDays.count).
    private static func weekTemplate(
        goal: RunningGoal,
        experience: ExperienceLevel,
        days: [Weekday]
    ) -> [RunType] {
        let count = runDayCount(experience: experience, available: days.count, goal: goal)

        switch goal {

        case .trainForRace:
            switch count {
            case 1: return [.longRun]
            case 2: return [.workout, .longRun]
            case 3: return [.easy, .workout, .longRun]
            case 4: return [.easy, .workout, .easy, .longRun]
            default: return [.easy, .workout, .mediumLong, .easy, .longRun]
            }

        case .getFaster:
            // Demote tempo to steadyRun for beginners
            let qualityRun: RunType = experience == .beginner ? .steadyRun : .tempo
            switch count {
            case 1: return [qualityRun]
            case 2: return [qualityRun, .longRun]
            case 3: return [.easy, qualityRun, .longRun]
            case 4: return [.easy, qualityRun, .recovery, .longRun]
            default: return [.recovery, .easy, qualityRun, .mediumLong, .longRun]
            }

        case .buildEndurance:
            switch count {
            case 1: return [.longRun]
            case 2: return [.easy, .longRun]
            case 3: return [.easy, .mediumLong, .longRun]
            default: return [.easy, .easy, .mediumLong, .longRun]
            }

        case .loseWeight:
            return Array(repeating: .easy, count: count)

        case .justStarting:
            return Array(repeating: .walkRun, count: count)

        case .clearMyHead, .stayActive, .health:
            // Mostly easy with one recovery if 4+ days
            var types = Array(repeating: RunType.easy, count: count)
            if count >= 4 { types[0] = .recovery }
            return types
        }
    }

    private static func runDayCount(experience: ExperienceLevel, available: Int, goal: RunningGoal) -> Int {
        let target: Int
        switch experience {
        case .beginner:       target = 3
        case .someExperience: target = 3
        case .regularRunner:  target = 4
        case .competitive:    target = 5
        }
        // Soft cap for low-intensity goals
        let goalCap: Int
        switch goal {
        case .justStarting: goalCap = 3
        case .stayActive, .clearMyHead, .health: goalCap = available
        default: goalCap = available
        }
        return min(min(target, available), goalCap)
    }

    // MARK: - Day assignment

    /// Maps RunType slots to actual Weekday values, preferring the weekend for long/quality runs.
    private static func assignDays(
        _ days: [Weekday],
        to template: [RunType],
        goal: RunningGoal
    ) -> [(day: Weekday, runType: RunType)] {
        guard !days.isEmpty, !template.isEmpty else { return [] }

        let count = min(template.count, days.count)
        var remainingDays = Array(days.prefix(count))

        // Pull the long run to Saturday/Sunday when possible
        let longIndices = template.indices.filter { template[$0] == .longRun }
        if let longIndex = longIndices.first {
            let weekend = remainingDays.filter { $0 == .saturday || $0 == .sunday }
            if let preferredDay = weekend.last,
               let dayIndex = remainingDays.firstIndex(of: preferredDay) {
                remainingDays.swapAt(dayIndex, min(longIndex, remainingDays.count - 1))
            }
        }

        return zip(remainingDays, template.prefix(count)).map { ($0, $1) }
    }

    // MARK: - Build runs

    private static func buildRuns(
        assignments: [(day: Weekday, runType: RunType)],
        totalMiles: Double,
        goal: RunningGoal,
        experience: ExperienceLevel
    ) -> [PlannedRun] {
        let shares = mileageShares(for: assignments.map(\.runType), totalMiles: totalMiles)

        return assignments.enumerated().map { index, pair in
            let miles = shares[index]
            let (title, detail) = runCopy(type: pair.runType, goal: goal, experience: experience)
            return PlannedRun(
                weekday: pair.day,
                runType: pair.runType,
                title: title,
                detail: detail,
                distanceLabel: formatMiles(miles),
                targetPaceSecPerMile: TargetPaceCalculator.targetPaceSecPerMile(
                    runType: pair.runType,
                    experience: experience
                )
            )
        }
    }

    /// Distribute total weekly miles across run types according to canonical fractions.
    private static func mileageShares(for types: [RunType], totalMiles: Double) -> [Double] {
        guard !types.isEmpty else { return [] }

        // Walk-run: flat distance, ignore mileage input
        if types.allSatisfy({ $0 == .walkRun }) {
            let walkMiles = min(totalMiles / Double(types.count), 3.0)
            return Array(repeating: walkMiles, count: types.count)
        }

        let longCount     = types.filter { $0 == .longRun }.count
        let medLongCount  = types.filter { $0 == .mediumLong }.count
        let tempoCount    = types.filter { $0 == .tempo || $0 == .workout || $0 == .steadyRun }.count
        let easyCount     = types.filter { $0 == .easy || $0 == .recovery }.count

        var longShare    = longCount    > 0 ? 0.32 * totalMiles / Double(longCount) : 0
        let medShare     = medLongCount > 0 ? 0.20 * totalMiles / Double(medLongCount) : 0
        let qualityShare = tempoCount   > 0 ? 0.15 * totalMiles / Double(tempoCount) : 0
        let allocatedFixed = (longCount > 0 ? 0.32 : 0)
                           + (medLongCount > 0 ? 0.20 * Double(medLongCount) : 0)
                           + (tempoCount   > 0 ? 0.15 * Double(tempoCount) : 0)
        let easyPool = max(totalMiles * (1 - allocatedFixed), totalMiles * 0.3)
        let easyShare = easyCount > 0 ? easyPool / Double(easyCount) : 0

        // Ensure long run is always the longest run
        let longestOther = max(medShare, qualityShare, easyShare)
        longShare = max(longShare, longestOther + 1.0)

        return types.map { type in
            let raw: Double
            switch type {
            case .longRun:               raw = longShare
            case .mediumLong:            raw = medShare
            case .tempo, .workout, .steadyRun: raw = qualityShare
            case .easy, .recovery:       raw = easyShare
            case .walkRun:               raw = min(totalMiles / Double(types.count), 3.0)
            case .strides:               raw = easyShare
            }
            return halfMileRound(max(raw, 1.5))
        }
    }

    // MARK: - Copy

    private static func runCopy(
        type: RunType,
        goal: RunningGoal,
        experience: ExperienceLevel
    ) -> (String, String) {
        switch type {
        case .longRun:
            return longRunCopy(goal: goal, experience: experience)
        case .mediumLong:
            return mediumLongCopy(goal: goal)
        case .tempo:
            return tempoCopy(goal: goal)
        case .workout:
            return workoutCopy(goal: goal)
        case .steadyRun:
            return ("Steady run", "Moderate effort — building aerobic base before speed work")
        case .walkRun:
            return walkRunCopy(experience: experience)
        case .recovery:
            return recoveryCopy(experience: experience)
        case .easy:
            return easyRunCopy(goal: goal, experience: experience)
        case .strides:
            return ("Easy run + strides", "Easy run ending with 4–6 x 20-sec accelerations")
        }
    }

    private static func longRunCopy(goal: RunningGoal, experience: ExperienceLevel) -> (String, String) {
        switch goal {
        case .trainForRace: return ("Long run", "Steady aerobic pace — build race-day endurance")
        case .buildEndurance: return ("Long run", "Conversational pace — extend time on feet")
        case .getFaster: return ("Long run", "Easy effort — builds the aerobic base for speed")
        case .justStarting: return ("Long walk-run", "Alternate jogging and walking — finish feeling good")
        default:
            return ("Long run", experience == .beginner ? "Slow and steady — no need to push" : "Comfortable effort throughout")
        }
    }

    private static func mediumLongCopy(goal: RunningGoal) -> (String, String) {
        switch goal {
        case .trainForRace: return ("Medium-long run", "Controlled effort — bridge between easy days and the long run")
        case .buildEndurance: return ("Medium-long run", "Hold a comfortable pace — stack time on feet through the week")
        default: return ("Medium-long run", "Aerobic effort — longer than easy, shorter than long run")
        }
    }

    private static func tempoCopy(goal: RunningGoal) -> (String, String) {
        switch goal {
        case .getFaster: return ("Tempo run", "Warm up 10 min, 20–25 min at threshold pace, cool down 10 min")
        default: return ("Tempo run", "Comfortably hard for 20 min — you can speak in short phrases only")
        }
    }

    private static func workoutCopy(goal: RunningGoal) -> (String, String) {
        switch goal {
        case .trainForRace: return ("Race-pace workout", "4–6 x 1 mile at goal race pace, 90-sec jog recovery between")
        default: return ("Interval workout", "6 x 3 min hard, 2 min easy — build strength and speed")
        }
    }

    private static func walkRunCopy(experience: ExperienceLevel) -> (String, String) {
        switch experience {
        case .beginner, .someExperience:
            return ("Walk-run", "1 min jog, 2 min walk — repeat for the full duration")
        default:
            return ("Walk-run", "2 min jog, 1 min walk — build to continuous running gradually")
        }
    }

    private static func recoveryCopy(experience: ExperienceLevel) -> (String, String) {
        switch experience {
        case .competitive: return ("Recovery run", "Truly easy — 60–70% max HR. Absorb the harder days.")
        default: return ("Recovery run", "Very relaxed pace — legs should feel fresh when done")
        }
    }

    private static func easyRunCopy(goal: RunningGoal, experience: ExperienceLevel) -> (String, String) {
        switch goal {
        case .loseWeight: return ("Easy run", "Aerobic zone — keep heart rate low and conversational")
        case .clearMyHead: return ("Easy run", "No pace target — just move and unwind")
        case .stayActive, .health: return ("Easy run", "Light effort — stay active without strain")
        default:
            return ("Easy run", experience == .competitive
                ? "Truly easy — protect your legs for quality days"
                : "Relaxed pace, focus on form and breathing")
        }
    }

    // MARK: - Focus text

    private static func focusTitle(for goal: RunningGoal) -> String {
        switch goal {
        case .trainForRace:  "Race-ready week"
        case .stayActive:    "Stay moving"
        case .loseWeight:    "Consistency first"
        case .buildEndurance:"Build your base"
        case .clearMyHead:   "Run to reset"
        case .getFaster:     "Speed + endurance"
        case .health:        "Healthy habits"
        case .justStarting:  "Your first week"
        }
    }

    private static func focusDetail(for goal: RunningGoal, experience: ExperienceLevel) -> String {
        let expNote: String
        switch experience {
        case .beginner:       expNote = "Volume and intensity paced for where you're starting."
        case .someExperience: expNote = "Eased back in at a sensible volume."
        case .regularRunner:  expNote = "Built around your usual rhythm."
        case .competitive:    expNote = "Includes a quality session and recovery management."
        }

        let goalNote: String
        switch goal {
        case .trainForRace:   goalNote = "Long run + race-pace workout to sharpen fitness."
        case .stayActive:     goalNote = "Short easy runs on your open days — no pressure."
        case .loseWeight:     goalNote = "Frequent aerobic miles to build a calorie-burning habit."
        case .buildEndurance: goalNote = "A progressive long run anchors the week."
        case .clearMyHead:    goalNote = "Easy efforts only — running as mental reset."
        case .getFaster:      goalNote = "One tempo session paired with aerobic volume."
        case .health:         goalNote = "Gentle volume focused on long-term health."
        case .justStarting:   goalNote = "Walk-run intervals — build the habit before the mileage."
        }

        return "\(goalNote) \(expNote)"
    }

    // MARK: - Helpers

    private static func halfMileRound(_ miles: Double) -> Double {
        (miles * 2).rounded() / 2
    }

    private static func formatMiles(_ miles: Double) -> String {
        miles == miles.rounded() ? "\(Int(miles)) mi" : String(format: "%.1f mi", miles)
    }

    private static func formatTotalMiles(_ miles: Double) -> String {
        miles == miles.rounded()
            ? "\(Int(miles)) mi target this week"
            : String(format: "%.0f mi target this week", miles)
    }
}
