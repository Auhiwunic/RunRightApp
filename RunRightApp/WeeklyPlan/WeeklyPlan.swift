//
//  WeeklyPlan.swift
//  Weekly Plan
//

import Foundation

enum RunType: String {
    case easy       = "EASY"
    case longRun    = "LONG"
    case tempo      = "TEMPO"
    case workout    = "WORKOUT"
    case walkRun    = "WALK-RUN"
    case recovery   = "RECOVERY"
    case mediumLong = "MED-LONG"
    case strides    = "STRIDES"
    case steadyRun  = "STEADY"

    var isHighIntensity: Bool {
        switch self {
        case .tempo, .workout, .strides: true
        default: false
        }
    }
}

struct PlannedRun: Identifiable {
    let id = UUID()
    let weekday: Weekday
    let runType: RunType
    let title: String
    let detail: String
    let distanceLabel: String
    /// Derived target pace for mid-run coaching; nil for walk-run intervals.
    let targetPaceSecPerMile: Int?
}

struct WeeklyPlan {
    let focusTitle: String
    let focusDetail: String
    let totalMilesLabel: String
    let runs: [PlannedRun]
    let notes: [String]
}
