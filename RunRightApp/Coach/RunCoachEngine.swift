//
//  RunCoachEngine.swift
//  Weekly Plan
//

import Foundation

enum CoachTrigger: Equatable {
    case runStart
    case runFinish
    case mileSplit(mile: Int)
    case categoryChange(PaceCoachCategory)
    case gpsWeak
}

struct CoachPromptDecision: Equatable {
    let category: PaceCoachCategory
    let trigger: CoachTrigger
    let mile: Int?
}

struct RunCoachEngineState: Equatable {
    var lastCategory: PaceCoachCategory?
    var lastPromptDate: Date?
    var lastCategoryPromptDates: [PaceCoachCategory: Date] = [:]
    var lastAnnouncedMile: Int = 0
    var hasSpokenStart = false
    var hasSpokenFinish = false
    var hasSpokenGPSWeak = false
    var gpsNilSince: Date?
    var previousPhase: LiveRunState.Phase = .idle
}

struct RunCoachEngine {
    private let onPaceThreshold: Double = 15
    private let slightlyThreshold: Double = 45
    // Mid-run the coach should mostly stay quiet: mile splits are the anchor
    // cues (they bypass this throttle); between them, at most one pace cue per
    // 3 minutes and the same nag no more than once per 5 — a runner drifting
    // around the target must not get a running commentary.
    private let minSameCategoryInterval: TimeInterval = 300
    private let minOverallInterval: TimeInterval = 180
    private let gpsWeakDelay: TimeInterval = 30

    mutating func evaluate(
        state: LiveRunState,
        plannedRun: PlannedRun,
        engineState: inout RunCoachEngineState,
        now: Date = .now
    ) -> CoachPromptDecision? {
        defer { engineState.previousPhase = state.phase }

        if state.phase == .finished, !engineState.hasSpokenFinish {
            engineState.hasSpokenFinish = true
            recordPrompt(category: .finished, at: now, engineState: &engineState)
            return CoachPromptDecision(category: .finished, trigger: .runFinish, mile: nil)
        }

        guard state.phase == .running else { return nil }

        if !engineState.hasSpokenStart {
            engineState.hasSpokenStart = true
            recordPrompt(category: .startingOut, at: now, engineState: &engineState)
            return CoachPromptDecision(category: .startingOut, trigger: .runStart, mile: nil)
        }

        let wholeMiles = state.completedWholeMiles
        if wholeMiles > engineState.lastAnnouncedMile, wholeMiles > 0 {
            engineState.lastAnnouncedMile = wholeMiles
            let category: PaceCoachCategory
            if let paceCategory = paceCategory(for: state, plannedRun: plannedRun) {
                category = paceCategory
            } else {
                category = .mileSplit
            }
            if canPrompt(category: category, at: now, engineState: engineState, bypassThrottle: true) {
                recordPrompt(category: category, at: now, engineState: &engineState)
                return CoachPromptDecision(
                    category: category == .mileSplit ? .mileSplit : category,
                    trigger: .mileSplit(mile: wholeMiles),
                    mile: wholeMiles
                )
            }
        }

        if let gpsDecision = evaluateGPSWeak(state: state, engineState: &engineState, now: now) {
            return gpsDecision
        }

        guard let category = paceCategory(for: state, plannedRun: plannedRun) else {
            return nil
        }

        // Between mile splits the coach only speaks up for a BIG deviation.
        // The onPace / slightly-off commentary made it talk constantly on a
        // normal run (pace naturally hovers around the target and every hover
        // was a category change) — the mile-split pace note covers those.
        guard category == .tooSlow || category == .tooFast else {
            engineState.lastCategory = category
            return nil
        }

        guard category != engineState.lastCategory else { return nil }
        guard canPrompt(category: category, at: now, engineState: engineState, bypassThrottle: false) else {
            return nil
        }

        recordPrompt(category: category, at: now, engineState: &engineState)
        engineState.lastCategory = category
        return CoachPromptDecision(category: category, trigger: .categoryChange(category), mile: nil)
    }

    func paceCategory(for state: LiveRunState, plannedRun: PlannedRun) -> PaceCoachCategory? {
        guard
            let rolling = state.rollingPaceSecPerMile ?? state.currentPaceSecPerMile,
            let target = state.targetPaceSecPerMile ?? plannedRun.targetPaceSecPerMile.map(Double.init)
        else {
            return nil
        }

        let delta = rolling - target

        if abs(delta) <= onPaceThreshold {
            return .onPace
        }
        if delta > slightlyThreshold {
            return .tooSlow
        }
        if delta > onPaceThreshold {
            return .slightlySlow
        }
        if delta < -slightlyThreshold {
            return .tooFast
        }
        return .slightlyFast
    }

    private func shouldSkipEasyRunPrompt(category: PaceCoachCategory, plannedRun: PlannedRun) -> Bool {
        guard plannedRun.runType == .easy || plannedRun.runType == .recovery else { return false }
        switch category {
        case .slightlySlow, .slightlyFast:
            return true
        default:
            return false
        }
    }

    private mutating func evaluateGPSWeak(
        state: LiveRunState,
        engineState: inout RunCoachEngineState,
        now: Date
    ) -> CoachPromptDecision? {
        let hasPace = state.rollingPaceSecPerMile != nil || state.currentPaceSecPerMile != nil

        if hasPace {
            engineState.gpsNilSince = nil
            return nil
        }

        if engineState.gpsNilSince == nil {
            engineState.gpsNilSince = now
            return nil
        }

        guard
            !engineState.hasSpokenGPSWeak,
            let nilSince = engineState.gpsNilSince,
            now.timeIntervalSince(nilSince) >= gpsWeakDelay
        else {
            return nil
        }

        engineState.hasSpokenGPSWeak = true
        recordPrompt(category: .gpsWeak, at: now, engineState: &engineState)
        return CoachPromptDecision(category: .gpsWeak, trigger: .gpsWeak, mile: nil)
    }

    private func canPrompt(
        category: PaceCoachCategory,
        at now: Date,
        engineState: RunCoachEngineState,
        bypassThrottle: Bool
    ) -> Bool {
        if bypassThrottle { return true }

        if let lastPrompt = engineState.lastPromptDate,
           now.timeIntervalSince(lastPrompt) < minOverallInterval {
            return false
        }

        if let lastCategoryPrompt = engineState.lastCategoryPromptDates[category],
           now.timeIntervalSince(lastCategoryPrompt) < minSameCategoryInterval {
            return false
        }

        return true
    }

    private func recordPrompt(
        category: PaceCoachCategory,
        at now: Date,
        engineState: inout RunCoachEngineState
    ) {
        engineState.lastPromptDate = now
        engineState.lastCategoryPromptDates[category] = now
    }
}
