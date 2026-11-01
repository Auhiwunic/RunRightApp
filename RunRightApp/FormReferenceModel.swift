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

    /// Plain-language, one line: what this joint's curve means for a beginner.
    /// Keyed off `name` so the six mode variants share one explanation.
    var explain: String {
        switch name {
        case "Knee flexion":
            return "How much your knee bends. Nearly straight when your foot lands, then it folds up to swing your leg through."
        case "Hip flexion":
            return "How far your thigh swings. Forward as your knee drives up, backward as you push off behind you."
        case "Ankle":
            return "How your ankle bends. It flexes up toward your shin as you land, then points down to push off."
        default:
            return ""
        }
    }
}

enum FormReference {

    // MARK: - Joint-angle reference curves

    static func knee(_ mode: RunMode) -> JointReference {
        switch mode {
        case .distance:
            return JointReference(
                name: "Knee flexion", unit: "°",
                // Novacheck 1998 run curve + n=50 recreational runners at 3.0 m/s
                // (knee ~11° at contact, stance peak ~41°); swing peak ~94° for
                // distance pace (below the ~105° sprint value). Band = published
                // between-subject SD, widened through swing where a 2D markerless
                // side view is noisiest (fast, out-of-plane, trailing-limb occlusion).
                mean: [15, 38, 40, 28, 22, 48, 80, 94, 74, 38, 15],
                band: [5, 5, 5, 6, 6, 7, 8, 8, 8, 6, 5],
                landmarks: [(0.20, "Stance peak ~40°"), (0.40, "Toe-off"), (0.70, "Swing peak ~94°")],
                axisLo: -10, axisHi: 125)
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
                // Dorsiflexion positive. Near-neutral at contact, dorsiflexes
                // through loading to a midstance peak ~+23° (Fukuchi 2017 ~22-25°),
                // then plantarflexes fast through toe-off to a peak ~-16° in early
                // swing, returning toward neutral. The old curve wrongly showed 0°
                // dorsiflexion during loading. Widest band at push-off (highest
                // variability, and the least reliable phase from a side view).
                mean: [3, 15, 23, 22, -8, -16, -6, 2, 4, 5, 3],
                band: [5, 5, 5, 6, 8, 8, 7, 6, 5, 5, 5],
                landmarks: [(0.20, "Dorsiflex ~23°"), (0.50, "Push-off ~ -16°")],
                axisLo: -38, axisHi: 40)
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
        // Hip intentionally excluded: from a single 2D side view the hip angle is
        // thigh-relative-to-trunk, so any forward lean (which every runner has,
        // and which changes with speed and fatigue) is baked into it with no
        // vertical/pelvis reference to remove it. Knee is safe (thigh-vs-shank,
        // no external reference); ankle is kept but flagged as least reliable.
        [knee(mode), ankle(mode)]
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

// MARK: - Adaptive (per-user) reference

/// Blends the fixed population band with the runner's OWN history so the
/// reference "adapts to what the person already does" without ever becoming
/// pure self-endorsement. Everything is aligned to the population mean first so
/// the systematic markerless offset (BlazePose joint centers ≠ anatomical, worst
/// at the ankle) cancels and we compare SHAPE, not absolute degrees. Research-
/// backed (Nigg preferred-movement-path; markerless-offset validation): a rigid
/// absolute-angle band mislabels normal runners, but a purely self-referenced
/// band can bless a bad habit — so we blend, cap the personalization, keep the
/// band width honest to both the runner's consistency and the sensor's noise
/// floor, and (in the chart) always show the population line as a second trace.
enum AdaptiveForm {

    struct Overlay {
        let center: [Double]      // 11 deciles — band center, axis space
        let halfWidth: [Double]   // 11 deciles — band half-width
        let wSelf: Double         // 0…1 personalization weight (0 = pure population)
        let nRuns: Int            // qualifying past runs used
    }

    private static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }

    /// Build the personalized band for one joint from the user's PAST curves
    /// (exclude the current run). Returns nil → the chart falls back to the fixed
    /// population band (cold start, run 1). `pastCurves` are raw measured
    /// 11-decile curves in the joint's own units.
    static func overlay(joint: JointReference, pastCurves: [[Double]]) -> Overlay? {
        let popMean = joint.mean.reduce(0, +) / Double(joint.mean.count)
        // Align each past curve to the population mean (removes the DC offset so
        // history from different sessions/offsets stacks in one shape space).
        let aligned: [[Double]] = pastCurves.compactMap { c in
            guard c.count == 11, c.allSatisfy({ $0.isFinite }) else { return nil }
            let m = c.reduce(0, +) / 11.0
            let shift = popMean - m
            return c.map { $0 + shift }
        }
        let n = aligned.count
        // Need a few clean past runs before a per-user baseline is meaningful
        // (research: 3-5). Below that, spread is undefined (a single run has MAD 0,
        // which would falsely "tighten" on one sample) so we fall back to the
        // fixed population band via a nil return.
        guard n >= 3 else { return nil }

        let span = max(joint.axisHi - joint.axisLo, 0.0001)
        // Personalization weight grows to a hard cap of 0.85 by ~5 runs, so the
        // population anchor never fully disappears (a guardrail in itself).
        let wSelf = min(max(Double(n) / 5.0, 0), 0.85)

        var center = [Double](repeating: 0, count: 11)
        var half = [Double](repeating: 0, count: 11)
        for k in 0..<11 {
            let col = aligned.map { $0[k] }
            let med = median(col)
            let mad = median(col.map { abs($0 - med) })
            let robustSD = 1.4826 * mad                       // MAD → SD
            let popBand = max(joint.band[k] * 2.5, span * 0.08)  // matches the chart's lenient pop width
            // Floor = sensor noise (can't resolve tighter). Ceiling = the
            // population band ITSELF (per-joint, so it scales with the knee's
            // larger range too): a very consistent runner tightens toward the
            // floor, an inconsistent one widens back to the population width, and
            // personalization can never force a band narrower than population for
            // a genuinely variable runner (a fixed 12deg cap did, on the knee).
            let userBand = min(max(1.75 * robustSD, 4.0), popBand)
            center[k] = (1 - wSelf) * joint.mean[k] + wSelf * med
            // Hard physiologic clamp: personalize only inside the sane axis range.
            center[k] = min(max(center[k], joint.axisLo), joint.axisHi)
            half[k] = (1 - wSelf) * popBand + wSelf * userBand
        }
        return Overlay(center: center, halfWidth: half, wSelf: wSelf, nRuns: n)
    }
}
