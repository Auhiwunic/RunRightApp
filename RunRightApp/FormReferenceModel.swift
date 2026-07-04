//
//  FormReferenceModel.swift
//  RunRightApp
//
//  Research-backed "optimal form" reference curves and target ranges for the
//  full-metrics graphs. These are NORMATIVE references from published running
//  kinematics, drawn as BANDS (not single lines) because good form is
//  individual. Sprint and distance are separate models — they are mechanically
//  different runs and should never share one target.
//
//  Sources: Novacheck 1998 (Gait & Posture, "The biomechanics of running");
//  Schache 2011; Bramah 2018 (AJSM); Souza 2016 (JOSPT); Nagahara 2019
//  (Frontiers); Weyand 2000/2010 (J Appl Physiol); Hunter 2005; Heiderscheit
//  2011 (MSSE); Garmin running-dynamics percentile data. Angles are sagittal,
//  positive = flexion (dorsiflexion for ankle), gait cycle 0% = foot strike,
//  toe-off ~40%, swing peak ~70%.
//

import SwiftUI

enum RunMode: String, CaseIterable, Identifiable {
    case distance
    case sprint
    var id: String { rawValue }
    var title: String { self == .distance ? "Distance" : "Sprint" }
}

/// One joint's optimal-reference curve over 0–100% of the gait cycle, sampled
/// at each decile as a mean plus a half-band (the shaded acceptable range).
struct JointReference {
    let name: String
    let unit: String
    /// 11 mean values at 0,10,…,100% of the cycle.
    let mean: [Double]
    /// Half-width of the shaded band at each decile (research spread; wider
    /// where the literature is a range, e.g. hip, or measurement is noisy).
    let band: [Double]
    /// Cited landmarks the chart annotates: (cyclePercent 0…1, label).
    let landmarks: [(Double, String)]
    /// FIXED research axis for this joint — the SAME for distance and sprint so
    /// the optimal band renders identically every scan and only the user's line
    /// moves. Chosen to bound the published range across both modes plus normal
    /// human/measurement spread, so it never rescales to one runner's data.
    let axisLo: Double
    let axisHi: Double
}

enum FormReference {

    // MARK: - Joint-angle reference curves

    static func knee(_ mode: RunMode) -> JointReference {
        switch mode {
        case .distance:
            return JointReference(
                name: "Knee flexion", unit: "°",
                mean: [12, 31, 42, 30, 17, 50, 90, 95, 75, 35, 12],
                band: [6, 7, 6, 7, 7, 9, 9, 8, 9, 8, 6],
                landmarks: [(0.20, "Stance peak ~42°"), (0.40, "Toe-off"), (0.70, "Swing peak ~95°")],
                axisLo: -10, axisHi: 140)
        case .sprint:
            return JointReference(
                name: "Knee flexion", unit: "°",
                mean: [15, 33, 40, 25, 12, 70, 115, 125, 95, 40, 15],
                band: [8, 9, 8, 9, 8, 11, 11, 10, 11, 9, 8],
                landmarks: [(0.40, "Toe-off"), (0.70, "Heel-to-hip ~125°")],
                axisLo: -10, axisHi: 140)
        }
    }

    static func hip(_ mode: RunMode) -> JointReference {
        switch mode {
        case .distance:
            return JointReference(
                name: "Hip flexion", unit: "°",
                mean: [35, 27, 12, -2, -8, 7, 27, 40, 50, 42, 35],
                band: [8, 8, 8, 8, 9, 8, 8, 8, 9, 8, 8],
                landmarks: [(0.40, "Extension ~ -8°"), (0.80, "Drive ~50°")],
                axisLo: -25, axisHi: 80)
        case .sprint:
            return JointReference(
                name: "Hip flexion", unit: "°",
                mean: [45, 33, 12, -5, -15, 10, 38, 55, 65, 55, 45],
                band: [10, 10, 9, 9, 10, 9, 10, 10, 11, 10, 10],
                landmarks: [(0.40, "Extension ~ -15°"), (0.80, "Knee drive ~65°")],
                axisLo: -25, axisHi: 80)
        }
    }

    static func ankle(_ mode: RunMode) -> JointReference {
        switch mode {
        case .distance:
            return JointReference(
                name: "Ankle", unit: "°",
                mean: [3, 0, 22, 10, -20, -10, 0, 5, 3, 1, 3],
                band: [6, 6, 6, 7, 7, 6, 6, 6, 6, 6, 6],
                landmarks: [(0.20, "Dorsiflex ~22°"), (0.40, "Push-off ~ -20°")],
                axisLo: -40, axisHi: 35)
        case .sprint:
            return JointReference(
                name: "Ankle", unit: "°",
                mean: [-8, -5, 15, 0, -28, -18, -2, 5, 3, 0, -8],
                band: [8, 7, 7, 8, 8, 7, 7, 6, 6, 7, 8],
                landmarks: [(0.0, "Forefoot land"), (0.40, "Push-off ~ -28°")],
                axisLo: -40, axisHi: 35)
        }
    }

    static func joints(_ mode: RunMode) -> [JointReference] {
        [knee(mode), hip(mode), ankle(mode)]
    }

    // MARK: - Scalar target ranges (for target-zone bands on time series)

    struct TargetRange {
        let label: String
        let unit: String
        let lo: Double
        let hi: Double
        let note: String
    }

    static func cadence(_ mode: RunMode) -> TargetRange {
        mode == .distance
            ? TargetRange(label: "Cadence", unit: "spm", lo: 170, hi: 190,
                          note: "Distance runners settle 170–190 spm. Raise your own rate 5–10%, don't force 180.")
            : TargetRange(label: "Cadence", unit: "spm", lo: 240, hi: 260,
                          note: "Max-velocity sprinting runs ~250–260 spm. Bolt held ~257 in his 9.58.")
    }

    static func groundContact(_ mode: RunMode) -> TargetRange {
        mode == .distance
            ? TargetRange(label: "Ground contact", unit: "ms", lo: 200, hi: 300,
                          note: "200–300 ms is steady distance. Trained runners sit near 200.")
            : TargetRange(label: "Ground contact", unit: "ms", lo: 85, hi: 120,
                          note: "Elite sprint contact is under 100–120 ms with ~4× bodyweight of force.")
    }

    static func verticalOsc(_ mode: RunMode) -> TargetRange {
        TargetRange(label: "Bounce", unit: "cm", lo: 6, hi: 9,
                    note: mode == .distance
                        ? "6–9 cm is efficient. Less bounce means more of your energy goes forward."
                        : "Sprinting adds height, but keep bounce small next to the long stride.")
    }
}
