//
//  OnboardingOptions.swift
//  Weekly Plan
//

import Foundation

enum RunningGoal: String, CaseIterable, Identifiable {
    case trainForRace = "train_for_race"
    case stayActive = "stay_active"
    case loseWeight = "lose_weight"
    case buildEndurance = "build_endurance"
    case clearMyHead = "clear_my_head"
    case getFaster = "get_faster"
    case health = "health"
    case justStarting = "just_starting"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trainForRace: "Train for a race"
        case .stayActive: "Stay active"
        case .loseWeight: "Lose weight"
        case .buildEndurance: "Build endurance"
        case .clearMyHead: "Clear my head"
        case .getFaster: "Get faster"
        case .health: "Improve my health"
        case .justStarting: "Just getting started"
        }
    }

    var subtitle: String {
        switch self {
        case .trainForRace: "5K, half, marathon — pick your distance later"
        case .stayActive: "Keep moving without a strict target"
        case .loseWeight: "Burn calories, build consistency"
        case .buildEndurance: "Go farther, feel stronger"
        case .clearMyHead: "Running as mental reset"
        case .getFaster: "Chase a PR or beat your last time"
        case .health: "Doctor's advice, longevity, energy"
        case .justStarting: "Couch to first mile"
        }
    }
}

enum ExperienceLevel: String, CaseIterable, Identifiable {
    case beginner = "beginner"
    case someExperience = "some_experience"
    case regularRunner = "regular_runner"
    case competitive = "competitive"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .beginner: "New"
        case .someExperience: "Returning"
        case .regularRunner: "Regular"
        case .competitive: "Competitive"
        }
    }

    var detail: String {
        switch self {
        case .beginner: "Haven't run consistently yet"
        case .someExperience: "Used to run, getting back into it"
        case .regularRunner: "Run most weeks, know the routine"
        case .competitive: "Training with pace and race goals"
        }
    }
}

enum Weekday: Int, CaseIterable, Identifiable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    var id: Int { rawValue }

    var shortLabel: String {
        switch self {
        case .sunday: "S"
        case .monday: "M"
        case .tuesday: "T"
        case .wednesday: "W"
        case .thursday: "T"
        case .friday: "F"
        case .saturday: "S"
        }
    }
}

enum WeeklyMileageRange: String, CaseIterable, Identifiable {
    case zeroToFive = "0_5"
    case fiveToFifteen = "5_15"
    case fifteenToTwentyFive = "15_25"
    case twentyFivePlus = "25_plus"

    var id: String { rawValue }

    var rangeLabel: String {
        switch self {
        case .zeroToFive: "0–5"
        case .fiveToFifteen: "5–15"
        case .fifteenToTwentyFive: "15–25"
        case .twentyFivePlus: "25+"
        }
    }

    var unitLabel: String { "miles / week" }
}
