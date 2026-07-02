//
//  TargetPaceCalculator.swift
//  Weekly Plan
//

import Foundation

enum TargetPaceCalculator {
    /// Returns target pace in seconds per mile, or nil when pace coaching doesn't apply.
    static func targetPaceSecPerMile(
        runType: RunType,
        experience: ExperienceLevel
    ) -> Int? {
        switch runType {
        case .walkRun:
            return nil
        case .easy, .recovery, .longRun:
            return easyPace(for: experience)
        case .mediumLong:
            return easyPace(for: experience) + 15
        case .tempo, .workout, .steadyRun, .strides:
            return max(easyPace(for: experience) - 52, 360)
        }
    }

    private static func easyPace(for experience: ExperienceLevel) -> Int {
        switch experience {
        case .beginner:       return 690   // 11:30 / mi
        case .someExperience: return 630   // 10:30 / mi
        case .regularRunner:  return 570   // 9:30 / mi
        case .competitive:    return 480   // 8:00 / mi
        }
    }
}
