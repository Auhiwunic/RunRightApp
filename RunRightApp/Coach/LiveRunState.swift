//
//  LiveRunState.swift
//  Weekly Plan
//

import Foundation

struct LiveRunState: Equatable {
    enum Phase: Equatable {
        case idle
        case running
        case paused
        case finished
    }

    var phase: Phase
    var elapsedSeconds: TimeInterval
    var distanceMeters: Double
    var currentPaceSecPerMile: Double?
    var rollingPaceSecPerMile: Double?
    var targetPaceSecPerMile: Double?

    static let idle = LiveRunState(
        phase: .idle,
        elapsedSeconds: 0,
        distanceMeters: 0,
        currentPaceSecPerMile: nil,
        rollingPaceSecPerMile: nil,
        targetPaceSecPerMile: nil
    )

    var distanceMiles: Double {
        distanceMeters / Self.metersPerMile
    }

    var completedWholeMiles: Int {
        Int(distanceMiles)
    }

    static let metersPerMile = 1609.344
}

enum PaceCoachCategory: String, CaseIterable, Equatable {
    case onPace = "On pace"
    case slightlySlow = "A little slow"
    case slightlyFast = "A little fast"
    case tooSlow = "Too slow"
    case tooFast = "Too fast"
    case startingOut = "Starting out"
    case closingIn = "Closing in"
    case finished = "Finished"
    case struggling = "Struggling"
    case gpsWeak = "GPS weak"
    case mileSplit = "Mile split"

    var displayName: String { rawValue }
}
