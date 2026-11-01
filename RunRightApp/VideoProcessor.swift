//
//  VideoProcessor.swift
//  RunRightApp
//
//  Processes videos with Apple Vision body pose detection and draws skeleton overlay
//

import Foundation
import AVFoundation
import UIKit
import CoreImage
import simd
import Combine

enum VideoMode: String, CaseIterable, Identifiable {
    case angled
    case side
    
    var id: String { rawValue }
}

enum BodySide {
    case left
    case right
}

/// Side-view facing: nose lateral offset vs shoulder midpoint (2D screen space).
/// `minMarginFraction` gates out ambiguous frames (nose near the shoulder
/// centre, e.g. head bob) so they don't cast a flickering vote.
func detectFacingSide(from points: [PoseJoint: CGPoint], minMarginFraction: CGFloat = 0) -> BodySide? {
    guard let nose = points[.nose],
          let ls = points[.leftShoulder],
          let rs = points[.rightShoulder] else { return nil }
    let midX = (ls.x + rs.x) / 2
    let offset = nose.x - midX
    if minMarginFraction > 0 {
        let shoulderWidth = abs(ls.x - rs.x)
        if shoulderWidth <= 0 || abs(offset) < shoulderWidth * minMarginFraction { return nil }
    }
    return offset >= 0 ? .right : .left
}

func majoritySide(_ votes: [BodySide]) -> BodySide? {
    guard !votes.isEmpty else { return nil }
    let rightCount = votes.filter { $0 == .right }.count
    return rightCount >= (votes.count - rightCount) ? .right : .left
}

private let sideDetectionVoteThreshold = 8

// Scan-quality v1 thresholds — PROVISIONAL, tuned via the per-analysis
// calibration log (Documents/scan_quality_log.csv in DEBUG builds), biased to
// under-trigger until enough real clips have been measured.
private let scanQualityMinCleanRatio = 0.4
// ~3s of clean framing is the reliable window; shorter clips still analyse but
// are flagged low-confidence (a 2s clip is only ~3 gait cycles — noisy).
// Remote-Config tunable (ScoringConfig.scanMinCleanSeconds).
private var scanQualityMinCleanSeconds: Double { scoringConfig.scanMinCleanSeconds }
// Fraction of clean-window frames where the hip "snaps" implausibly far in one
// frame. Above this the skeleton is choppy/unstable → the metrics can't be
// trusted. Conservative (biased to under-trigger) until calibrated on real clips.
// Remote-Config tunable (ScoringConfig.scanMaxJitterRatio).
private var scanQualityMaxJitterRatio: Double { scoringConfig.scanMaxJitterRatio }

enum ShinStrideBand: String {
    case unknown
    case understride
    case goodStride
    case mildOverstride
    case moderateOverstride
    case severeOverstride
}

struct ShinStrideClassification {
    let band: ShinStrideBand
    let label: String
    let score: Int
}

enum TorsoAngleBand: String {
    case unknown
    case tooUpright
    case optimal
    case good
    case moderateLean
    case excessive
}

struct TorsoAngleClassification {
    let band: TorsoAngleBand
    let label: String
    let score: Int
}

private enum ShinStrideThresholds {
    static let unknownMin: Double = 0.1
    static let understrideSevereMax: Double = 3.0
    static let understrideMax: Double = 6.0
    static let goodMax: Double = 13.0
    static let mildOverstrideMax: Double = 17.0
    static let moderateOverstrideMax: Double = 22.0
}

func classifyShinStride(angle: Double?) -> ShinStrideClassification {
    guard let angle, angle.isFinite, angle >= ShinStrideThresholds.unknownMin else {
        return ShinStrideClassification(band: .unknown, label: "Unknown", score: 50)
    }

    if angle < ShinStrideThresholds.understrideSevereMax {
        let score = max(45, min(59, Int(45 + (angle / ShinStrideThresholds.understrideSevereMax) * 14)))
        return ShinStrideClassification(band: .understride, label: "Understride", score: score)
    }
    if angle < ShinStrideThresholds.understrideMax {
        let t = (angle - ShinStrideThresholds.understrideSevereMax) / (ShinStrideThresholds.understrideMax - ShinStrideThresholds.understrideSevereMax)
        let score = max(60, min(79, Int(60 + t * 19)))
        return ShinStrideClassification(band: .understride, label: "Understride", score: score)
    }
    if angle <= ShinStrideThresholds.goodMax {
        let center = 9.5
        let maxDist = 3.5
        let dist = min(maxDist, abs(angle - center))
        let score = max(88, min(100, Int(100 - (dist / maxDist) * 12)))
        return ShinStrideClassification(band: .goodStride, label: "Good Stride", score: score)
    }
    if angle < ShinStrideThresholds.mildOverstrideMax {
        let t = (angle - ShinStrideThresholds.goodMax) / (ShinStrideThresholds.mildOverstrideMax - ShinStrideThresholds.goodMax)
        let score = max(70, min(84, Int(84 - t * 14)))
        return ShinStrideClassification(band: .mildOverstride, label: "Mild Overstride", score: score)
    }
    if angle < ShinStrideThresholds.moderateOverstrideMax {
        let t = (angle - ShinStrideThresholds.mildOverstrideMax) / (ShinStrideThresholds.moderateOverstrideMax - ShinStrideThresholds.mildOverstrideMax)
        let score = max(55, min(69, Int(69 - t * 14)))
        return ShinStrideClassification(band: .moderateOverstride, label: "Moderate Overstride", score: score)
    }
    return ShinStrideClassification(band: .severeOverstride, label: "Severe Overstride", score: 40)
}

private enum TorsoAngleThresholds {
    static let unknownMin: Double = 0.1
    // More lenient bands (reduce false "too much lean" flags). Treadmill runners
    // often run a touch upright, so the optimal window starts low.
    static let tooUprightMax: Double = 2.5   // retained for callers; no longer penalised
    static let optimalMax: Double = 14.0
    static let goodMax: Double = 19.0
    static let moderateLeanMax: Double = 26.0
}

func classifyTorsoAngle(angle: Double?) -> TorsoAngleClassification {
    guard let angle, angle.isFinite, angle >= TorsoAngleThresholds.unknownMin else {
        return TorsoAngleClassification(band: .unknown, label: "Unknown", score: 50)
    }
    
    if angle <= TorsoAngleThresholds.optimalMax {
        // 0–14°: efficient. A near-upright trunk is the MOST economical form
        // (Carson 2024 causal experiment: upright 1.7° beat 4.3° and 8.2°); elites
        // sit ~3° and lean rises with pace. So we do NOT penalise upright running —
        // full marks across the band, easing only slightly toward the top.
        let score = angle <= 10 ? 100 : max(90, Int((100 - (angle - 10) * 2.5).rounded()))
        return TorsoAngleClassification(band: .optimal, label: "Optimal", score: score)
    }
    if angle <= TorsoAngleThresholds.goodMax {
        // Good (often speed/effort dependent)
        let t = (angle - TorsoAngleThresholds.optimalMax) / (TorsoAngleThresholds.goodMax - TorsoAngleThresholds.optimalMax)
        let score = max(75, min(87, Int(87 - t * 12)))
        return TorsoAngleClassification(band: .good, label: "Good", score: score)
    }
    if angle < TorsoAngleThresholds.moderateLeanMax {
        // Moderate lean
        let t = (angle - TorsoAngleThresholds.goodMax) / (TorsoAngleThresholds.moderateLeanMax - TorsoAngleThresholds.goodMax)
        let score = max(60, min(74, Int(74 - t * 14)))
        return TorsoAngleClassification(band: .moderateLean, label: "Moderate Lean", score: score)
    }
    // Excessive lean
    return TorsoAngleClassification(band: .excessive, label: "Excessive Lean", score: 40)
}

enum HeadAngleBand: String {
    case unknown
    case lookingAhead
    case slightDownward
    case moderateDownward
    case excessive
}

struct HeadAngleClassification {
    let band: HeadAngleBand
    let label: String
    let score: Int
}

private enum HeadAngleThresholds {
    static let unknownMin: Double = 0.1
    static let lookingAheadMax: Double = 5.0
    static let slightDownwardMax: Double = 10.0
    static let moderateDownwardMax: Double = 15.0
}

func classifyHeadAngle(angle: Double?) -> HeadAngleClassification {
    guard let angle, angle.isFinite, angle >= HeadAngleThresholds.unknownMin else {
        return HeadAngleClassification(band: .unknown, label: "Unknown", score: 50)
    }
    
    if angle <= HeadAngleThresholds.lookingAheadMax {
        // 0-5°: Looking ahead (optimal gaze direction)
        let center = 2.5
        let maxDist = 2.5
        let dist = min(maxDist, abs(angle - center))
        let score = max(88, min(100, Int(100 - (dist / maxDist) * 12)))
        return HeadAngleClassification(band: .lookingAhead, label: "Looking Ahead", score: score)
    }
    if angle <= HeadAngleThresholds.slightDownwardMax {
        // 5-10°: Slight downward gaze — still acceptable
        let t = (angle - HeadAngleThresholds.lookingAheadMax) / (HeadAngleThresholds.slightDownwardMax - HeadAngleThresholds.lookingAheadMax)
        let score = max(75, min(87, Int(87 - t * 12)))
        return HeadAngleClassification(band: .slightDownward, label: "Slight Downward", score: score)
    }
    if angle < HeadAngleThresholds.moderateDownwardMax {
        // 10-15°: Moderate downward gaze — looking too far down
        let t = (angle - HeadAngleThresholds.slightDownwardMax) / (HeadAngleThresholds.moderateDownwardMax - HeadAngleThresholds.slightDownwardMax)
        let score = max(60, min(74, Int(74 - t * 14)))
        return HeadAngleClassification(band: .moderateDownward, label: "Moderate Downward", score: score)
    }
    // 15°+: Excessive downward gaze — looking at feet
    return HeadAngleClassification(band: .excessive, label: "Looking at Feet", score: 40)
}

// MARK: - Elbow Angle Classification

enum ElbowAngleBand: String {
    case unknown
    case tooTight
    case good
    case optimal
    case slightlyOpen
    case tooStraight
}

struct ElbowAngleClassification {
    let band: ElbowAngleBand
    let label: String
    let score: Int
}

private enum ElbowAngleThresholds {
    // Arm carriage is highly individual and low-consequence; faster runners fold
    // the arm more (~55-90°). Only a genuinely locked/over-tight arm scores low.
    static let tooTightMax: Double = 52.0
    static let goodLowerMax: Double = 65.0
    static let optimalMax: Double = 100.0
    static let goodUpperMax: Double = 120.0
    // > 120° = too straight (mean carriage ~90°; up to ~120° is normal — Pontzer
    // 2019, Tartaruga 2012). Was 115; raised so a slightly-open arm isn't flagged.
}

func classifyElbowAngle(angle: Double?) -> ElbowAngleClassification {
    guard let angle, angle.isFinite, angle > 0 else {
        return ElbowAngleClassification(band: .unknown, label: "Unknown", score: 50)
    }
    
    if angle < ElbowAngleThresholds.tooTightMax {
        // 0-70°: Too tight (excessive tension)
        let t = angle / ElbowAngleThresholds.tooTightMax
        let score = max(40, min(59, Int(40 + t * 19)))
        return ElbowAngleClassification(band: .tooTight, label: "Too Tight", score: score)
    }
    if angle < ElbowAngleThresholds.goodLowerMax {
        // 70-80°: Good (slightly tight but acceptable)
        let t = (angle - ElbowAngleThresholds.tooTightMax) / (ElbowAngleThresholds.goodLowerMax - ElbowAngleThresholds.tooTightMax)
        let score = max(75, min(87, Int(75 + t * 12)))
        return ElbowAngleClassification(band: .good, label: "Good", score: score)
    }
    if angle <= ElbowAngleThresholds.optimalMax {
        // 80-100°: Optimal (close to 90°)
        let center = 90.0
        let maxDist = 10.0
        let dist = min(maxDist, abs(angle - center))
        let score = max(88, min(100, Int(100 - (dist / maxDist) * 12)))
        return ElbowAngleClassification(band: .optimal, label: "Optimal", score: score)
    }
    if angle <= ElbowAngleThresholds.goodUpperMax {
        // 100-110°: Good (slightly open but acceptable)
        let t = (angle - ElbowAngleThresholds.optimalMax) / (ElbowAngleThresholds.goodUpperMax - ElbowAngleThresholds.optimalMax)
        let score = max(75, min(87, Int(87 - t * 12)))
        return ElbowAngleClassification(band: .slightlyOpen, label: "Slightly Open", score: score)
    }
    // > 110°: Too straight (inefficient arm swing)
    return ElbowAngleClassification(band: .tooStraight, label: "Too Straight", score: 40)
}

enum FootPlacementBand: String {
    case unknown
    case heelStrike
    case mildHeelStrike
    case midfoot
    case mildForefoot
    case forefootStrike
}

struct FootPlacementClassification {
    let band: FootPlacementBand
    let label: String
    let score: Int
}

private enum FootPlacementThresholds {
    static let midfootMax: Double = 8.0       // ±8° = midfoot (optimal, accounts for pose estimation noise)
    static let mildMax: Double = 15.0         // ±8–15° = mild heel/forefoot
    static let moderateMax: Double = 22.0     // ±15–22° = moderate
    // > 22° = severe
}

func classifyFootPlacement(angle: Double?) -> FootPlacementClassification {
    guard let angle, angle.isFinite else {
        return FootPlacementClassification(band: .unknown, label: "Unknown", score: 50)
    }
    
    let absAngle = abs(angle)
    
    if absAngle <= FootPlacementThresholds.midfootMax {
        // Midfoot landing (optimal)
        let maxDist = FootPlacementThresholds.midfootMax
        let dist = min(maxDist, absAngle)
        let score = max(88, min(100, Int(100 - (dist / maxDist) * 12)))
        return FootPlacementClassification(band: .midfoot, label: "Midfoot", score: score)
    }
    if absAngle <= FootPlacementThresholds.mildMax {
        // Mild heel or forefoot strike
        let t = (absAngle - FootPlacementThresholds.midfootMax) / (FootPlacementThresholds.mildMax - FootPlacementThresholds.midfootMax)
        let score = max(70, min(87, Int(87 - t * 17)))
        let band: FootPlacementBand = angle > 0 ? .mildHeelStrike : .mildForefoot
        let label = angle > 0 ? "Mild Heel Strike" : "Mild Forefoot"
        return FootPlacementClassification(band: band, label: label, score: score)
    }
    if absAngle <= FootPlacementThresholds.moderateMax {
        // Moderate heel or forefoot strike
        let t = (absAngle - FootPlacementThresholds.mildMax) / (FootPlacementThresholds.moderateMax - FootPlacementThresholds.mildMax)
        let score = max(50, min(69, Int(69 - t * 19)))
        let band: FootPlacementBand = angle > 0 ? .heelStrike : .forefootStrike
        let label = angle > 0 ? "Heel Strike" : "Forefoot Strike"
        return FootPlacementClassification(band: band, label: label, score: score)
    }
    // Severe
    let band: FootPlacementBand = angle > 0 ? .heelStrike : .forefootStrike
    let label = angle > 0 ? "Heel-dominant" : "Forefoot-dominant"
    return FootPlacementClassification(band: band, label: label, score: 40)
}

// MARK: - Sprint-specific classifiers

struct SprintClassification {
    let category: String
    let label: String
    let score: Int
    let tip: String
}

private func sprintScoreInt(_ x: Double) -> Int {
    Int(max(0, min(100, x)).rounded())
}

/// ROM (degrees) from an averaged gait-cycle curve — robust when full-clip min/max under-reports.
func sprintRomFromCycleCurve(_ curve: [Double]) -> Double {
    let v = curve.filter { $0.isFinite && !$0.isNaN }
    guard v.count >= 2, let lo = v.min(), let hi = v.max() else { return 0 }
    let span = hi - lo
    return span > 0.25 && span.isFinite ? span : 0
}

func classifySprintGroundStrike(angle: Double?) -> SprintClassification {
    guard let angle, angle.isFinite else {
        return SprintClassification(category: "Landing (foot strike)", label: "Unknown", score: 50,
            tip: "Not enough contact data. Film a clear side view so the foot is visible at touchdown.")
    }
    let score: Double
    let label: String
    let tip: String
    if angle < -3 {
        label = "Forefoot"
        score = 86 + min(11, (-angle - 3) * 0.42)
        tip = "Forefoot loading tends to land closer under your hip, so there's less braking when your foot hits. You get a springier feel rolling into the next step, which suits faster running."
    } else if angle <= 5 {
        label = "Midfoot"
        let mid = 1.0
        score = max(74, 95.5 - abs(angle - mid) * 2.6)
        tip = "Midfoot contact is a solid pattern. You slow down smoothly without reaching far out in front of your body, and impact spreads more evenly through the foot."
    } else if angle <= 12 {
        label = "Mild heel"
        score = 71 - (angle - 5) * 4.2
        tip = "Heel-first contact adds braking right after touchdown. Try landing closer under your hip with a bit more ball of the foot so each step flows forward instead of stopping you."
    } else {
        label = "Heavy heel"
        score = max(22, 42 - (angle - 12) * 2.0)
        tip = "A strong heel-first landing exaggerates braking and makes it harder to roll smoothly into your next push-off. Flatter contact under the hips usually feels smoother and faster."
    }
    return SprintClassification(category: "Landing (foot strike)", label: label, score: sprintScoreInt(score), tip: tip)
}

/// `hipExtension` is **total hip angle ROM** (max−min of sagittal hip flex over the clip / merged cycle), typically ~50–85° for running — not a 15–30° “extension excursion.”
func classifySprintBacksideMechanics(hipExtension: Double?) -> SprintClassification {
    guard let r = hipExtension, r.isFinite, r > 0.5 else {
        return SprintClassification(category: "Flight (recovery)", label: "Unknown", score: 50,
            tip: "Not enough hip data for flight-phase recovery. Full leg in frame helps track swing-leg path after toe-off.")
    }
    let score: Double
    let tip: String
    if r < 25 {
        score = 56 + max(0, r - 12) * 0.55
        tip = "Limited hip motion in this clip weakens the flight-recovery read. Film a full-body side view so your thigh swing is visible through the whole stride."
    } else if r < 42 {
        score = 62 + (r - 25) * 1.15
        tip = "Your hip range is building. Clearer strides through the frame usually raise this score and make recovery between steps easier to see."
    } else if r <= 78 {
        let peak = 60.0
        let d = abs(r - peak)
        score = max(78, 91 - d * 0.22 - (d > 25 ? (d - 25) * 0.25 : 0))
        tip = "Flight phase looks good, with solid hip and thigh movement for recovering between strides. Your swing leg is clearing the ground without dragging."
    } else if r <= 95 {
        score = 84 - (r - 78) * 0.35
        tip = "Very large hip range, which is common at faster paces. If your recovery looks choppy, try a slightly shorter heel path and stay relaxed through the swing."
    } else {
        score = max(72, 78 - (r - 95) * 0.4)
        tip = "Extreme hip range can be tracking noise or a very aggressive swing. Confirm on clean side-view footage that your thigh is actually swinging that far."
    }
    let s = sprintScoreInt(score)
    let label: String
    switch s {
    case 82...100: label = "Efficient"
    case 64..<82: label = "OK"
    default: label = "Needs work"
    }
    return SprintClassification(category: "Flight (recovery)", label: label, score: s, tip: tip)
}

func classifySprintKneeDrive(kneeFlexionRange: Double?) -> SprintClassification {
    guard let range = kneeFlexionRange, range.isFinite, range > 0.5 else {
        return SprintClassification(category: "Flight (swing)", label: "Unknown", score: 50,
            tip: "Not enough knee motion in flight. Side view should show swing-leg path between support phases.")
    }
    let score: Double
    if range < 42 {
        score = 40 + max(0, range - 18) * 0.65
    } else if range < 62 {
        score = 55 + (range - 42) * 1.05
    } else if range < 82 {
        score = 76 + (range - 62) * 0.72
    } else if range <= 105 {
        // Natural strong drive tops out here — do NOT keep rewarding more range.
        score = min(96, 90.4 + (range - 82) * 0.24)
    } else {
        // Over ~105°: over-kipping the leg up — exaggerated and inefficient, not
        // stronger. Penalise the excess so unnatural leg lift can't read as drive.
        score = max(45, 96 - (range - 105) * 1.5)
    }
    let s = sprintScoreInt(score)
    let label: String
    switch s {
    case 84...100: label = "Strong"
    case 66..<84: label = "Moderate"
    default: label = "Low"
    }
    let tip = s >= 84
        ? "Flight phase looks strong. Your thigh swings well, so your leg is ready for the next ground contact from a powerful position. That sets up a cleaner landing underneath you."
        : "A bit more knee lift in flight improves where your next foot lands. Practice a relaxed swing between contacts so the leg clears the ground without rushing."
    return SprintClassification(category: "Flight (swing)", label: label, score: s, tip: tip)
}

/// Hip / ankle inputs are **total sagittal ROM** over the clip (same units as `AnalysisMetrics` ranges), not small extension-only windows.
func classifySprintConcentricPushOff(hipExtension: Double?, ankleFlexionRange: Double?) -> SprintClassification {
    let hip = hipExtension
    let ankle = ankleFlexionRange
    guard (hip != nil && hip! > 0.5) || (ankle != nil && ankle! > 0.5) else {
        return SprintClassification(category: "Push-off (stance)", label: "Unknown", score: 50,
            tip: "Could not estimate push-off from hip/ankle data. A clear side view helps capture the whole stance.")
    }
    func hipPushScore(_ ext: Double) -> Double {
        if ext < 24 {
            return 58 + max(0, ext - 12) * 0.5
        }
        if ext < 45 {
            return 65 + (ext - 24) * 0.95
        }
        let peak = 63.0
        let d = abs(ext - peak)
        var s = 90 - d * 0.18
        if d > 22 { s -= (d - 22) * 0.22 }
        return max(68, min(94, s))
    }
    func anklePushScore(_ r: Double) -> Double {
        if r < 18 {
            return 60 + max(0, r - 10) * 0.65
        }
        if r < 34 {
            return 68 + (r - 18) * 0.95
        }
        let peak = 44.0
        let d = abs(r - peak)
        var s = 89 - d * 0.52
        if d > 24 { s -= (d - 24) * 0.32 }
        return max(62, min(94, s))
    }
    var parts: [Double] = []
    if let h = hip, h > 0.5 { parts.append(hipPushScore(h)) }
    if let a = ankle, a > 0.5 { parts.append(anklePushScore(a)) }
    let raw = parts.isEmpty ? 50.0 : parts.reduce(0, +) / Double(parts.count)
    let score = sprintScoreInt(raw)
    let label: String
    switch score {
    case 84...100: label = "Strong"
    case 64..<84: label = "OK"
    default: label = "Limited"
    }
    return SprintClassification(category: "Push-off (stance)", label: label, score: score,
        tip: "Strong push-off comes from opening your hip and ankle while you're still on the ground. That's what launches you into the next stride instead of collapsing into contact.")
}

func classifySprintTorsoLean(angle: Double?) -> SprintClassification {
    guard let angle, angle.isFinite, angle >= 0.1 else {
        return SprintClassification(category: "Stack & alignment", label: "Unknown", score: 50,
            tip: "Not enough trunk data. A neutral stack (head–ribs–hips) carries better from foot strike through push-off.")
    }
    let center = 5.25
    var score = 95 - min(abs(angle - center), 24) * 1.58
    if angle < 1.8 {
        score = min(score, 72 + angle * 8.5)
    }
    if angle > 16 {
        score = min(score, 88 - (angle - 16) * 3.2)
    }
    score = max(26, min(98, score))
    let s = sprintScoreInt(score)
    let label: String
    let tip: String
    if angle < 2 {
        label = "Very upright"
        tip = "Almost vertical. A slight forward line from your ankle through your hip often matches sprint acceleration mechanics and helps you use gravity on the start."
    } else if angle >= 2 && angle <= 9 {
        label = "Neutral"
        tip = "Your trunk is stacked with a small forward tilt, so push-off forces can travel in a straight line without folding. Head, ribs, and hips move as one unit."
    } else if angle <= 12 {
        label = "Slight lean"
        tip = "A bit more trunk angle than a typical upright sprint. Check that your hips stay tall while your foot is down so you don't hinge at the waist."
    } else if angle <= 18 {
        label = "Excess lean"
        tip = "Leaning this far can break the line from your hip to your shoulder when you're pushing off the ground. That leaks power and loads the lower back."
    } else {
        label = "Severe lean"
        tip = "Folding this far forward breaks the chain, making it harder to use your hip and ankle power before your foot leaves the ground. Stand taller and lean from the ankles."
    }
    return SprintClassification(category: "Stack & alignment", label: label, score: s, tip: tip)
}

// MARK: - Weyand / Morin / arm-counterbalance helpers (video proxies; no force plate)

private enum SprintTimingGates {
    static let detectMinSeconds = 0.05
    static let detectMaxSeconds = 0.75
    static let sampleMinSeconds = 0.05
    static let sampleMaxSeconds = 0.80
    static let minStrideSeconds = 0.15
    static let maxStrideSeconds = 1.50
    static let minStepSeconds = 0.15
    static let maxStepSeconds = 1.50
    static let minFlightSeconds = 0.015
    static let stepTimingTolerance = 0.12
    static let minSupportRatio = 1.02
    static let maxSupportRatio = 6.50
    static let heelStrikeMinGapSeconds = 0.14
    static let toeOffFallbackDutyFactor = 0.60
}

private func sprintMedian(_ values: [Double]) -> Double? {
    let v = values.filter { $0.isFinite && !$0.isNaN }
    guard !v.isEmpty else { return nil }
    let s = v.sorted()
    let m = s.count / 2
    return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
}

/// Collects step-time / contact-time ratios and flight fractions from detected gait cycles.
func collectSprintStepTimingSamples(from gait: GaitCycleSeries) -> (ratio: [Double], flightFraction: [Double]) {
    var ratios: [Double] = []
    var flights: [Double] = []
    for c in gait.leftCycles + gait.rightCycles {
        let tStep = c.endTime - c.startTime
        let tContact = c.toeOffTime - c.startTime
        let tFlight = c.endTime - c.toeOffTime
        guard tStep > SprintTimingGates.minStepSeconds && tStep < SprintTimingGates.maxStepSeconds,
              tContact > SprintTimingGates.sampleMinSeconds && tContact < SprintTimingGates.sampleMaxSeconds,
              tFlight > SprintTimingGates.minFlightSeconds,
              abs(tStep - (tContact + tFlight)) < SprintTimingGates.stepTimingTolerance else { continue }
        let r = tStep / max(tContact, 1e-4)
        guard r > SprintTimingGates.minSupportRatio && r < SprintTimingGates.maxSupportRatio else { continue }
        ratios.append(r)
        flights.append(tFlight / max(tStep, 1e-4))
    }
    return (ratios, flights)
}

/// Resolves support ratio from collected samples, stance percent, or cadence + GCT fallback.
func estimateSupportRatio(
    from samples: [Double],
    gait: GaitCycleSeries?,
    metrics: AnalysisMetrics
) -> Double? {
    if let med = sprintMedian(samples) { return med }
    if let gait {
        let stancePcts = [gait.leftStancePercent, gait.rightStancePercent].filter { $0 > 4 && $0 < 96 }
        if !stancePcts.isEmpty {
            let avgStance = stancePcts.reduce(0, +) / Double(stancePcts.count)
            return 100.0 / avgStance
        }
    }
    let gctValues = [metrics.groundContactLeft, metrics.groundContactRight].filter { $0 > 0 }
    if metrics.cadence > 0, !gctValues.isEmpty {
        let avgGctMs = gctValues.reduce(0, +) / Double(gctValues.count)
        let stepMs = 60000.0 / metrics.cadence
        let ratio = stepMs / avgGctMs
        if ratio.isFinite && ratio > 0 { return ratio }
    }
    return nil
}

/// Scores how well ground-contact time relates to overall step time. Faster cadence generally means shorter contacts.
func classifySprintSupportTiming(supportRatio: Double?, flightFraction: Double?, cadence: Double) -> SprintClassification {
    guard let r = supportRatio, r.isFinite, r > 0 else {
        return SprintClassification(
            category: "Support timing",
            label: "Unknown",
            score: 50,
            tip: "Need clear heel-strike and toe-off events in a side-view clip. Make sure your full body is visible so foot contacts can be tracked.")
    }
    let cadenceClamped = max(80, min(240, cadence))
    let center = 2.18 - (cadenceClamped - 165) * 0.0015
    var score = 98.0 - abs(r - center) * 34.0
    if r < 1.28 { score -= 18 }
    if r > 3.45 { score -= min(22, (r - 3.45) * 18) }
    let s = sprintScoreInt(max(38, min(100, score)))
    let label: String
    let tip: String
    switch s {
    case 85...100:
        label = "Strong duty factor"
        tip = "Ground contact and flight look well balanced. You're spending enough time on the ground to push without rushing off early or staying planted too long. That rhythm helps you carry speed smoothly from one stride to the next."
    case 68..<85:
        label = "Balanced"
        tip = "Support timing looks reasonable. Each step spends a fair share of time on the ground without overcommitting to contact. Small refinements in side-view footage can sharpen this further."
    default:
        label = "Check timing"
        tip = "Contact timing may be off, either leaving the ground too early or staying down too long. That can waste push-off or add extra braking. Film from the side with your full body in frame for a clearer read."
    }
    return SprintClassification(category: "Support timing", label: label, score: s, tip: tip)
}

/// Estimates leg-spring stiffness from contact-time ratio and vertical oscillation. L0 ≈ 0.53× height.
private func legSpringStiffnessProxy(supportRatio: Double, verticalOscillationPct: Double, userBodyHeightMeters: Double) -> Double? {
    guard supportRatio > 0, verticalOscillationPct > 0, userBodyHeightMeters > 0.5 else { return nil }
    let legL0 = userBodyHeightMeters * 0.53
    let deltaL = (verticalOscillationPct / 100.0) * userBodyHeightMeters * 0.42
    let deltaOverL0 = max(deltaL / legL0, 0.018)
    return supportRatio / deltaOverL0
}

func classifySprintLegSpring(stiffnessProxy: Double?, torsoDeg: Double?) -> SprintClassification {
    guard let k = stiffnessProxy, k.isFinite, k > 0 else {
        return SprintClassification(
            category: "Leg spring",
            label: "Unknown",
            score: 50,
            tip: "Leg spring needs both vertical oscillation data and step timing. Re-record with your full body in frame so both can be measured.")
    }
    let logK = log(max(k, 6))
    let t = (logK - log(6)) / (log(38) - log(6))
    var score = 42.0 + max(0, min(1, t)) * 54.0
    if k > 42 { score -= min(12, (k - 42) * 0.35) }
    let s = sprintScoreInt(max(40, min(100, score)))
    let label: String
    let tip: String
    switch s {
    case 84...100:
        label = "Stiff spring"
        tip = "Your stride looks springy and responsive. The leg stays relatively stiff on contact, which is a sign of efficient elastic running. You rebound into the next step without excessive sinking."
    case 67..<84:
        label = "Typical spring"
        tip = "Leg spring looks typical, with normal compression while you're on the ground. You're absorbing impact without collapsing, then pushing off into flight. This is a workable pattern for most runners."
    default:
        label = "Soft / noisy"
        tip = "Leg spring reads soft or unclear in this clip. That can mean extra sinking on contact or noisy tracking. A full-body side view helps capture bounce and timing more reliably."
    }
    return SprintClassification(category: "Leg spring", label: label, score: s, tip: tip)
}

private func sprintDerivativeSeries(_ y: [Double], dt: Double) -> [Double] {
    guard y.count >= 2, dt > 1e-8 else { return [] }
    return zip(y.dropFirst(), y).map { cur, prev in (cur - prev) / dt }
}

private func sprintPearson(_ a: [Double], _ b: [Double]) -> Double? {
    let pairs = zip(a, b).filter { !$0.0.isNaN && !$0.1.isNaN && $0.0.isFinite && $0.1.isFinite }
    guard pairs.count >= 16 else { return nil }
    let xs = pairs.map(\.0)
    let ys = pairs.map(\.1)
    let n = Double(xs.count)
    let mx = xs.reduce(0, +) / n
    let my = ys.reduce(0, +) / n
    var num = 0.0, dx = 0.0, dy = 0.0
    for i in xs.indices {
        let vx = xs[i] - mx
        let vy = ys[i] - my
        num += vx * vy
        dx += vx * vx
        dy += vy * vy
    }
    let den = sqrt(dx * dy)
    guard den > 1e-12 else { return nil }
    return max(-1, min(1, num / den))
}

/// Measures how well the arms counterbalance the legs: checks arm-swing symmetry and how consistently the arm and leg movements oppose each other.
func classifySprintArmCounterbalance(metrics: AnalysisMetrics, series: MetricSeries) -> SprintClassification {
    let elbowL = metrics.elbowRangeLeft
    let elbowR = metrics.elbowRangeRight

    // Detect single-side mode: on a side-view clip the far wrist is often occluded,
    // causing armSwingSymmetry to collapse toward 0. Detect this when one elbow's range
    // dominates strongly or overall symmetry is very low despite visible arm motion.
    let dominantElbow = max(elbowL, elbowR)
    let minElbow = min(elbowL, elbowR)
    let isSingleSide = (dominantElbow > 5 && minElbow < dominantElbow * 0.25) ||
                       (metrics.armSwingSymmetry < 20 && dominantElbow > 5)

    // Arm swing amplitude: armMovementXSeries is already mean-normalised wrist X
    // (range expressed as a fraction of body height). Larger range → more active arm drive.
    let armSeriesValid = series.armMovementXSeries.filter { !$0.isNaN && $0.isFinite }
    let armAmplitude: Double
    if let minA = armSeriesValid.min(), let maxA = armSeriesValid.max(), armSeriesValid.count >= 10 {
        armAmplitude = maxA - minA
    } else {
        armAmplitude = 0
    }
    // Score amplitude: 0.08–0.22 body-height range is a healthy side-view arm swing.
    let amplitudeScore: Double = armAmplitude < 0.01
        ? 30.0
        : min(100.0, max(30.0, 50.0 + (armAmplitude - 0.08) / 0.15 * 50.0))

    // Opposition: correlate wrist VELOCITY (dArm) with foot VELOCITY directly.
    // footVelocityXSeries is already a velocity series — do NOT take another derivative
    // (that was the previous bug: it compared wrist velocity to foot acceleration).
    let count = min(series.armMovementXSeries.count, series.footVelocityXSeries.count)
    var opposition: Double?
    if count >= 20, series.durationSeconds > 0 {
        let dt = series.durationSeconds / Double(max(count - 1, 1))
        let arm = Array(series.armMovementXSeries.prefix(count))
        let dArm = sprintDerivativeSeries(arm, dt: dt)  // wrist velocity
        let foot = Array(series.footVelocityXSeries.prefix(dArm.count))  // foot velocity
        if dArm.count == foot.count, let rho = sprintPearson(dArm, foot) {
            // Negative correlation → arm and foot velocities oppose each other (good counterbalance).
            opposition = max(0, min(100, (1.0 - rho) / 2.0 * 100.0))
        }
    }

    let blended: Double
    if isSingleSide {
        // On single-side clips don't penalise for symmetry — use amplitude and opposition.
        if let o = opposition {
            blended = 0.45 * amplitudeScore + 0.55 * o
        } else {
            blended = max(amplitudeScore, 40.0)
        }
    } else {
        let sym = max(0, min(100, metrics.armSwingSymmetry))
        if let o = opposition {
            blended = 0.30 * sym + 0.35 * amplitudeScore + 0.35 * o
        } else {
            let elbowSym: Double = (elbowL + elbowR) > 1
                ? 100.0 - (abs(elbowL - elbowR) / max((elbowL + elbowR) / 2.0, 1.0)) * 100.0
                : sym
            blended = 0.40 * sym + 0.30 * amplitudeScore + 0.30 * max(0, min(100, elbowSym))
        }
    }

    let s = sprintScoreInt(max(30, min(100, blended)))
    let label: String
    switch s {
    case 82...100: label = "Countering well"
    case 64..<82: label = "OK balance"
    default: label = "Arms drifting"
    }
    let tipBase: String
    if let o = opposition {
        let oppRounded = Int(o.rounded())
        tipBase = oppRounded >= 60
            ? "Your arms and feet oppose each other well, keeping you balanced and cutting wasted rotation through the trunk. "
            : "Arm timing could be sharper. Drive your elbows back deliberately to match your foot-strike rhythm and stay balanced. "
    } else if isSingleSide {
        tipBase = "Filmed from the side, so this is scored from the visible arm's swing range and timing. "
    } else {
        tipBase = "Not enough arm data for timing analysis, so this is scored from symmetry and elbow range. "
    }
    let tip = tipBase + "Keep your elbows compact and drive them back, not across your body."
    return SprintClassification(category: "Arm counterbalance", label: label, score: s, tip: tip)
}

func mergeSprintDriveAndFlight(
    push: SprintClassification,
    knee: SprintClassification,
    back: SprintClassification
) -> SprintClassification {
    let score = sprintScoreInt(
        Double(push.score) * 0.42 + Double(knee.score) * 0.32 + Double(back.score) * 0.26
    )
    let weakest = [push, knee, back].min(by: { $0.score < $1.score })!
    let label: String
    switch score {
    case 84...100: label = "Strong"
    case 66..<84: label = "Solid"
    default: label = "Build capacity"
    }
    let tip = "Combines push-off, knee lift, and flight recovery into one read. " + weakest.tip
    return SprintClassification(category: "Drive & flight", label: label, score: score, tip: tip)
}

// MARK: - Sprint power composite (single source for UI + export)

struct SprintPowerBreakdown {
    let composite: Int
    let groundStrike: SprintClassification
    let supportTiming: SprintClassification
    let legSpring: SprintClassification
    let driveAndFlight: SprintClassification
    let posture: SprintClassification
    let armCounterbalance: SprintClassification
}

/// Composite sprint power score: landing quality, support timing, leg spring, drive & flight ROM, posture, and arm counterbalance.
func computeSprintPowerBreakdown(
    series: MetricSeries,
    metrics: AnalysisMetrics,
    userBodyHeightMeters: Double = 1.7
) -> SprintPowerBreakdown {
    let footCue = series.formCueScores.first(where: { $0.cue == .footPlacement })
    let footAngle: Double? = {
        guard let r = footCue?.rawValue, r.isFinite, abs(r) > 0.1 else { return nil }
        return r
    }()
    let groundStrike = classifySprintGroundStrike(angle: footAngle)

    var kneeM = max(metrics.kneeFlexionRangeLeft, metrics.kneeFlexionRangeRight)
    var hipM = max(metrics.hipExtensionRangeLeft, metrics.hipExtensionRangeRight)
    var ankleM = max(metrics.ankleDorsiRangeLeft, metrics.ankleDorsiRangeRight)

    if let gait = series.gaitCycleSeries {
        let kc = max(sprintRomFromCycleCurve(gait.leftKneeAngle), sprintRomFromCycleCurve(gait.rightKneeAngle))
        let hc = max(sprintRomFromCycleCurve(gait.leftHipAngle), sprintRomFromCycleCurve(gait.rightHipAngle))
        let ac = max(sprintRomFromCycleCurve(gait.leftAnkleAngle), sprintRomFromCycleCurve(gait.rightAnkleAngle))
        kneeM = max(kneeM, kc)
        hipM = max(hipM, hc)
        ankleM = max(ankleM, ac)
    }

    let pushHip = hipM > 0.5 ? hipM : nil
    let pushAnkle = ankleM > 0.5 ? ankleM : nil
    let pushOff = classifySprintConcentricPushOff(hipExtension: pushHip, ankleFlexionRange: pushAnkle)
    let kneeDrive = classifySprintKneeDrive(kneeFlexionRange: kneeM > 0.5 ? kneeM : nil)
    let backside = classifySprintBacksideMechanics(hipExtension: pushHip)
    let driveAndFlight = mergeSprintDriveAndFlight(push: pushOff, knee: kneeDrive, back: backside)

    let timingSamples: ([Double], [Double]) = series.gaitCycleSeries.map { collectSprintStepTimingSamples(from: $0) } ?? ([], [])
    let ratioMed = estimateSupportRatio(from: timingSamples.0, gait: series.gaitCycleSeries, metrics: metrics)
    let flightMed = sprintMedian(timingSamples.1)
    let supportTiming = classifySprintSupportTiming(
        supportRatio: ratioMed,
        flightFraction: flightMed,
        cadence: metrics.cadence
    )

    let kProxy = ratioMed.flatMap { legSpringStiffnessProxy(
        supportRatio: $0,
        verticalOscillationPct: max(metrics.verticalOscillation, 0.1),
        userBodyHeightMeters: userBodyHeightMeters
    ) }
    let torso = series.torsoAngleMean
    let legSpring = classifySprintLegSpring(
        stiffnessProxy: kProxy,
        torsoDeg: torso >= 0.1 ? torso : nil
    )

    let posture = classifySprintTorsoLean(angle: torso >= 0.1 ? torso : nil)
    let armCounterbalance = classifySprintArmCounterbalance(metrics: metrics, series: series)

    let w = Double(groundStrike.score) * 0.18
        + Double(supportTiming.score) * 0.20
        + Double(legSpring.score) * 0.18
        + Double(driveAndFlight.score) * 0.22
        + Double(posture.score) * 0.12
        + Double(armCounterbalance.score) * 0.10
    let composite = sprintScoreInt(w)
    return SprintPowerBreakdown(
        composite: composite,
        groundStrike: groundStrike,
        supportTiming: supportTiming,
        legSpring: legSpring,
        driveAndFlight: driveAndFlight,
        posture: posture,
        armCounterbalance: armCounterbalance
    )
}

/// Per-step ground-contact and flight times (seconds) from detected gait cycles.
func stepContactFlightTimes(from gait: GaitCycleSeries?) -> (contact: [Double], flight: [Double]) {
    guard let gait else { return ([], []) }
    var tcs: [Double] = []
    var tfs: [Double] = []
    for c in gait.leftCycles + gait.rightCycles {
        // Keep tc and tf as a CONSISTENT pair from the same toe-off frame — the
        // Power composite is tuned around this pair. (The displayed ground-contact
        // metric uses the accurate vertical-motion contactMs instead; mixing the
        // two here gives a mismatched tf/tc ratio and destabilizes the score.)
        let tc = c.toeOffTime - c.startTime
        let tf = c.endTime - c.toeOffTime
        if tc > 0 { tcs.append(tc); tfs.append(max(0, tf)) }
    }
    return (tcs, tfs)
}

/// Headline Power score — now backed by the Morin spring-mass model (see
/// RunningPowerModel.swift) plus drive-angle ROM, replacing the legacy sprint
/// composite. Mass-free, frame-rate-adaptive.
func computeSprintPowerComposite(series: MetricSeries, metrics: AnalysisMetrics, userBodyHeightMeters: Double = 1.7) -> Int {
    powerResult(series: series, metrics: metrics).score
}

/// Full Power result (score + confidence + physics read) for dial + detail + export.
func powerResult(series: MetricSeries, metrics: AnalysisMetrics) -> PowerResult {
    let cfg = scoringConfig
    let (tcs, tfs) = stepContactFlightTimes(from: series.gaitCycleSeries)

    // Drive ROMs use the camera-facing leg only. max(left, right) always
    // preferred the far side whenever occlusion jitter inflated it — clean
    // elite treadmill footage read 130-150° hip "sweeps" and the exaggeration
    // falloff zeroed the term. Older stored metrics predate the selected
    // fields (0 = absent), so fall back to the legacy max for them.
    let hipRaw = metrics.hipExtensionRangeSelected > 0.5
        ? metrics.hipExtensionRangeSelected
        : max(metrics.hipExtensionRangeLeft, metrics.hipExtensionRangeRight)
    let ankleRaw = metrics.ankleDorsiRangeSelected > 0.5
        ? metrics.ankleDorsiRangeSelected
        : max(metrics.ankleDorsiRangeLeft, metrics.ankleDorsiRangeRight)
    let kneeRaw = metrics.kneeFlexionRangeSelected > 0.5
        ? metrics.kneeFlexionRangeSelected
        : max(metrics.kneeFlexionRangeLeft, metrics.kneeFlexionRangeRight)

    // Physiological plausibility windows: a sweep no human hip/knee/ankle can
    // produce is a tracking artifact, and an artifact must read as
    // UNMEASURABLE (nil → excluded from the drive average), never as
    // "exaggerated drive" scored into the falloff. The hip window depends on
    // the source: the camera-facing read gets falloff runway up to
    // hipPlausibleMax (real 90-115° over-kips stay penalized; measured
    // occlusion artifacts at 129-150° stay excluded), while the legacy
    // max(left,right) fallback keeps the strict scan window because it is
    // the occlusion-inflated read this fix targets.
    func plausible(_ v: Double, upTo maxDeg: Double) -> Double? {
        (v > 0.5 && v <= maxDeg) ? v : nil
    }
    let hipCap = metrics.hipExtensionRangeSelected > 0.5
        ? cfg.hipPlausibleMax : cfg.scanMaxPlausibleHipROM
    let hip = plausible(hipRaw, upTo: hipCap)
    let ankle = plausible(ankleRaw, upTo: cfg.anklePlausibleMax)
    let knee = plausible(kneeRaw, upTo: cfg.scanMaxPlausibleKneeROM)

    // Cadence joins the model as a drive pillar (turnover IS propulsion
    // evidence), so it enters the score exactly once — the old multiplicative
    // cadence band is gone. Outside 100-200 spm it is a slow-mo clip or a
    // broken count and reads unmeasurable inside the model.
    let cad = metrics.cadence
    let base = RunPowerModel.power(
        contactTimes: tcs,
        flightTimes: tfs,
        hipExtensionRangeDeg: hip,
        ankleRangeDeg: ankle,
        kneeDriveRangeDeg: knee,
        cadenceSpm: cad > 0 ? cad : nil,
        frameRate: series.frameRate
    )

    // Bounded evidence corrections refine the model without dominating it.
    // (The foot-under-COM penalty is deliberately NOT applied here until that
    // metric is calibrated — see computeEfficiencyBreakdown. A shank-angle
    // penalty was evaluated and rejected: heel-striking elites carry the
    // LARGEST shank angles at contact, so it demoted exactly the wrong
    // runners.)
    var factor = 1.0
    // Persistent toes-only running (the heel never drops in stance) is calf
    // bounce, not propulsion — the user-flagged red flag. Same signal, tiers,
    // and sprint-turnover gate as the footPlacement cue cap.
    if series.noHeelRatio.isFinite, cad < cfg.driveNoHeelCadenceMax,
       series.noHeelRatio >= cfg.driveNoHeelOnset {
        let span = max(cfg.driveNoHeelFull - cfg.driveNoHeelOnset, 0.01)
        let severity = min(1.0, (series.noHeelRatio - cfg.driveNoHeelOnset) / span)
        factor *= 1.0 - cfg.driveNoHeelMaxDiscount * severity
    }
    debugLog("[Drive] hipSel=\(Int(hipRaw)) ankleSel=\(Int(ankleRaw)) kneeSel=\(Int(kneeRaw)) plausible(hip=\(hip.map { Int($0) } ?? -1) ankle=\(ankle.map { Int($0) } ?? -1) knee=\(knee.map { Int($0) } ?? -1)) cad=\(Int(cad)) noHeel=\(series.noHeelRatio.isFinite ? String(format: "%.2f", series.noHeelRatio) : "nil") factor=\(String(format: "%.2f", factor))")
    guard factor < 0.999 else { return base }
    let adjusted = max(0, min(100, Int((Double(base.score) * factor).rounded())))
    // Re-derive the user-facing band from the DISCOUNTED score: a drive cut
    // for toes-only running must not keep the "Powerful, springy stride" copy.
    let label: String
    let detail: String
    switch adjusted {
    case 80...100:
        label = "Powerful, springy stride"
        detail = "You apply force quickly and return it elastically — strong drive off the ground with good air time."
    case 62..<80:
        label = "Solid drive"
        detail = "Reasonable force and leg spring. Strides, hills, and plyometrics will build more push-off power and elastic return."
    default:
        label = "Build power"
        detail = "Your heels never settle, so each step bounces off the calves instead of driving through the ground. Letting the heel kiss down after a midfoot landing restores real push-off."
    }
    let estimateNote = base.confidence == .high ? "" : " (estimate — record in slo-mo for a precise reading)"
    return PowerResult(
        score: adjusted,
        confidence: base.confidence,
        peakForceBW: base.peakForceBW,
        dutyFactor: base.dutyFactor,
        naturalFreqHz: base.naturalFreqHz,
        label: label,
        detail: detail + estimateNote
    )
}

/// Impact (landing-cost) result for the new Impact dial.
func impactResult(series: MetricSeries, metrics: AnalysisMetrics, userBodyHeightMeters: Double) -> ImpactResult {
    let shank = series.shankAngleAtContactSignedDeg.isFinite ? series.shankAngleAtContactSignedDeg : nil
    // verticalOscillation is stored as % of body height → convert to cm.
    let voCm: Double? = {
        guard metrics.verticalOscillation > 0, userBodyHeightMeters > 0.5 else { return nil }
        return metrics.verticalOscillation / 100.0 * userBodyHeightMeters * 100.0
    }()
    return RunImpactModel.impact(
        shankAngleAtContactDeg: shank,
        verticalOscillationCm: voCm,
        footStrike: metrics.footStrikePattern
    )
}

// MARK: - Efficiency composite (dial + export; matches form cue classifiers)

struct EfficiencyBreakdown {
    /// Same rounding as home-screen Efficiency dial.
    let composite: Int
    /// Average of the four pillar scores (for CSV one-decimal display).
    let averageDouble: Double
    let shin: ShinStrideClassification
    let torso: TorsoAngleClassification
    let gaze: HeadAngleClassification
    let elbow: ElbowAngleClassification
}

/// Overstride classification from the SIGNED shank angle at initial contact.
/// + = forward of vertical (foot ahead of body → overstride); − = vertical or
/// leaning back (good). This replaces the old unsigned-magnitude classifier, which
/// could not distinguish a good (backward) shank from an overstriding (forward) one.
func classifyShinStrideSigned(angle: Double?) -> ShinStrideClassification {
    guard let a = angle, a.isFinite else {
        return ShinStrideClassification(band: .unknown, label: "Unknown", score: 50)
    }
    func clampScore(_ x: Double, _ lo: Int, _ hi: Int) -> Int { max(lo, min(hi, Int(x.rounded()))) }
    // Shank inclination at contact. SOME forward lean is normal even for elite
    // runners; overstride only becomes a fault once the foot lands well ahead of
    // the body (~15°+). Bands widened so good technique is not mislabelled.
    if a < -10 {
        // Well behind vertical: understride, still low-risk.
        return ShinStrideClassification(band: .understride, label: "Understride", score: clampScore(88 + (a + 10), 78, 88))
    } else if a < 8 {
        // Foot lands under the body (slightly back to slightly forward) — ideal.
        return ShinStrideClassification(band: .goodStride, label: "Good Stride", score: clampScore(100 - abs(a + 2), 88, 100))
    } else if a < 15 {
        let t = (a - 8) / 7.0
        return ShinStrideClassification(band: .mildOverstride, label: "Mild Overstride", score: clampScore(88 - t * 14, 74, 88))
    } else if a < 22 {
        let t = (a - 15) / 7.0
        return ShinStrideClassification(band: .moderateOverstride, label: "Moderate Overstride", score: clampScore(73 - t * 15, 58, 73))
    } else {
        return ShinStrideClassification(band: .severeOverstride, label: "Severe Overstride", score: clampScore(56 - (a - 22), 42, 56))
    }
}

/// Blend the plain mean with the mean of the WORST third of dimensions. A flat
/// average lets one serious fault hide behind many fine cues (which is why poor
/// form scored ~80). This weights the faults: elite form (all dimensions high)
/// is barely affected, but real faults pull the score down the way they should.
/// The one overall used by every surface. The time-based dials (drive/impact)
/// report their own reliability — at phone frame rates contact/flight times are
/// estimates at best — so a low-confidence dial defers toward the cue-based
/// smooth score instead of swinging the verdict with noise. On the labeled
/// reference clips the raw physics dials scored perfect form 39-40 and flawed
/// form 83; letting them vote at full weight made the overall meaningless.
func overallFormScore(
    smooth: Int, drive: Int, impact: Int,
    driveConfidence: MetricConfidence, impactConfidence: MetricConfidence
) -> Int {
    func weighted(_ dial: Int, _ conf: MetricConfidence) -> Double {
        let w: Double
        switch conf {
        case .high: w = 1.0
        case .estimate: w = 0.45
        case .low: w = 0.2
        }
        return w * Double(dial) + (1 - w) * Double(smooth)
    }
    let dims = [
        Double(smooth),
        weighted(drive, driveConfidence),
        weighted(impact, impactConfidence),
    ]
    return Int(faultSensitiveScore(dims).rounded())
}

func faultSensitiveScore(_ dims: [Double]) -> Double {
    guard !dims.isEmpty else { return 0 }
    let mean = dims.reduce(0, +) / Double(dims.count)
    let sorted = dims.sorted()
    let k = max(1, dims.count / 3)
    let worst = sorted.prefix(k).reduce(0, +) / Double(k)
    let w = scoringConfig.faultBlendMeanWeight
    return max(0, min(100, w * mean + (1 - w) * worst))
}

/// Subtract a centered moving mean so only motion faster than `window` frames
/// survives — strips slow drift/pan before measuring stride bounce amplitude.
func detrendMovingMean(_ v: [Double], window w: Int) -> [Double] {
    guard v.count > 2, w >= 2 else { return v.map { _ in 0 } }
    let half = max(1, w / 2)
    return v.indices.map { i in
        let lo = max(0, i - half), hi = min(v.count - 1, i + half)
        var s = 0.0
        for j in lo...hi { s += v[j] }
        return v[i] - s / Double(hi - lo + 1)
    }
}

/// Strength (0–1) of the dominant stride periodicity in a single-foot signal, via
/// normalized autocorrelation over the physiological cadence band. A cleanly
/// tracked run peaks strongly (~0.4+); a jittery / mistracked clip stays flat
/// (~0.15). Returns -1 when it can't be assessed. Mirrors AnalyzeMath's cadence
/// autocorrelation but reports the confidence rather than the period.
func gaitPeriodicityStrength(_ series: [Double], frameRate: Double) -> Double {
    let x = series.filter { $0.isFinite }
    guard x.count >= 12, frameRate > 0 else { return -1 }
    let mean = x.reduce(0, +) / Double(x.count)
    let d = x.map { $0 - mean }
    let energy = d.reduce(0) { $0 + $1 * $1 }
    guard energy > 1e-9 else { return -1 }
    let minLag = max(2, Int((frameRate * 120.0 / 230.0).rounded()))
    let maxLag = min(d.count - 1, Int((frameRate * 120.0 / 120.0).rounded()))
    guard maxLag > minLag else { return -1 }
    var best = -Double.greatestFiniteMagnitude
    for lag in minLag...maxLag {
        var s = 0.0
        for i in 0..<(d.count - lag) { s += d[i] * d[i + lag] }
        best = max(best, s / energy)
    }
    return best
}

/// Post-metrics data-quality gate. Even when framing / window / jitter pass, the
/// MEASURED data can be physiologically impossible or non-periodic — a sign the
/// pose tracking was too unstable on this clip to sample honestly. Deliberately
/// sensitive: a false "retake" costs less than confidently scoring bad footage.
/// Returns a warning cause, or nil. Thresholds are Remote-Config tunable.
func dataPlausibilityWarning(metrics: AnalysisMetrics, series: MetricSeries) -> String? {
    let hipROM = max(metrics.hipExtensionRangeLeft, metrics.hipExtensionRangeRight)
    let kneeROM = max(metrics.kneeFlexionRangeLeft, metrics.kneeFlexionRangeRight)
    if hipROM > scoringConfig.scanMaxPlausibleHipROM || kneeROM > scoringConfig.scanMaxPlausibleKneeROM {
        debugLog("[Plausibility] implausible ROM hip=\(Int(hipROM)) knee=\(Int(kneeROM)) -> FLAG")
        return "The tracking looked unstable on this clip, so the numbers may be off. Retake side on with the runner well lit and clear of the background."
    }
    let footHip = !series.rightFootHipDistanceSeries.isEmpty
        ? series.rightFootHipDistanceSeries : series.leftFootHipDistanceSeries
    let dur = series.durationSeconds > 0.1 ? series.durationSeconds : 0
    let fps = dur > 0 && !footHip.isEmpty ? Double(footHip.count) / dur : 30
    let clarity = gaitPeriodicityStrength(footHip, frameRate: fps)
    if clarity >= 0, clarity < scoringConfig.scanMinGaitClarity {
        debugLog("[Plausibility] weak gait clarity=\(String(format: "%.2f", clarity)) -> FLAG")
        return "The tracking looked jumpy on this clip, so the numbers may be off. Retake side on with the runner well lit and clear of the background."
    }
    debugLog("[Plausibility] ok hip=\(Int(hipROM)) knee=\(Int(kneeROM)) clarity=\(String(format: "%.2f", clarity))")
    return nil
}

/// Efficiency (SMOOTH) composite. `armSwingRangeDeg`, when supplied, folds
/// arm-swing amplitude into the cue set: a tight, economical carriage (elite
/// clips measure ~15–25° of elbow-angle range) is efficient, while arms
/// flailing wide open and shut (~100°+) waste energy and are a real smoothness
/// fault the joint-angle cues alone miss. Passing nil preserves the old
/// cue-only behaviour for callers without metrics.
func computeEfficiencyBreakdown(series: MetricSeries, armSwingRangeDeg: Double? = nil) -> EfficiencyBreakdown? {
    guard !series.formCueScores.isEmpty else { return nil }
    let shinCls = classifyShinStrideSigned(
        angle: series.shankAngleAtContactSignedDeg.isFinite ? series.shankAngleAtContactSignedDeg : nil
    )
    let torsoCls = classifyTorsoAngle(angle: {
        let m = series.torsoAngleMean
        return m >= 0.1 ? m : nil
    }())
    let gazeCls = classifyHeadAngle(angle: {
        let m = series.headAngleMean
        return m >= 0.1 ? m : nil
    }())
    let elbowCls = classifyElbowAngle(angle: {
        let m = series.elbowAngleMean
        return m > 0 ? m : nil
    }())
    // Composite over the FULL measured cue set (cadence, foot placement, hip
    // stability, quiet feet, posture, shin, elbows, gaze) — not just the four
    // arm/posture pillars — with a fault-sensitive blend so a serious fault is
    // not averaged away behind fine cues. Averaging only 4 lenient cues flat is
    // what let poor form score ~80. The shin/torso/gaze/elbow sub-objects are
    // still returned for the detail view.
    // footUnderCOM is measured and displayed but NOT blended yet: ankle-ahead-
    // of-hip has no speed-fair absolute banding (fast runners legitimately land
    // further ahead), so until it is calibrated against labeled clips it would
    // punish good runners or excuse reachers. The shin angle carries the
    // overstride signal in the blend meanwhile.
    var dims = series.formCueScores
        .filter { $0.cue != .footUnderCOM }
        .map { Double($0.score) }
    guard !dims.isEmpty else { return nil }
    // Arm-swing amplitude as an efficiency cue. Elite carriage holds the elbow
    // near-fixed (~15–25° of range); arms pumping wide open and shut waste energy.
    // Tight is 100; it ramps down past a generous ceiling so only genuine flailing
    // is penalised and a normal swing is untouched.
    var armEff: Double? = nil
    if let arm = armSwingRangeDeg, arm > 0.5 {
        let cfg = scoringConfig
        let e = arm <= cfg.armEffCeiling ? 100 : max(cfg.armEffFloor, 100 - (arm - cfg.armEffCeiling) * cfg.armEffSlope)
        armEff = e
        dims.append(e)
    }
    let composite = Int(faultSensitiveScore(dims).rounded())
#if DEBUG
    let dump = series.formCueScores
        .map { "\($0.cue.rawValue)=\(Int($0.score))" }
        .joined(separator: " | ")
    debugLog("[FormScore] composite=\(composite) armROM=\(armSwingRangeDeg.map { Int($0) } ?? -1) armEff=\(armEff.map { Int($0) } ?? -1) cues: \(dump)")
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let f = dir.appendingPathComponent("form_cue_scores.csv")
    let header = "date," + FormCue.allCases.map { $0.rawValue }.joined(separator: ",") + ",composite\n"
    var byCue: [FormCue: Int] = [:]
    for s in series.formCueScores { byCue[s.cue] = Int(s.score) }
    let row = "\(Date().timeIntervalSince1970)," + FormCue.allCases.map { byCue[$0].map(String.init) ?? "" }.joined(separator: ",") + ",\(composite)\n"
    if !FileManager.default.fileExists(atPath: f.path) {
        try? (header + row).write(to: f, atomically: true, encoding: .utf8)
    } else if let h = try? FileHandle(forWritingTo: f) {
        h.seekToEndOfFile(); h.write(Data(row.utf8)); try? h.close()
    }
#endif
    return EfficiencyBreakdown(
        composite: composite,
        averageDouble: faultSensitiveScore(dims),
        shin: shinCls,
        torso: torsoCls,
        gaze: gazeCls,
        elbow: elbowCls
    )
}

struct PoseFrame {
    let time: Double
    let points: [PoseJoint: CGPoint]
    let points3D: [PoseJoint: SIMD3<Double>]
    let facingRight: Bool
}

struct AnalysisMetrics {
    let cadence: Double
    let strideLength: Double
    let groundContactLeft: Double
    let groundContactRight: Double
    let verticalOscillation: Double
    let symmetryScore: Double
    let trunkLean: Double
    let headStability: Double
    let hipDrop: Double
    let kneeValgus: Double
    let kneeFlexionRangeLeft: Double
    let kneeFlexionRangeRight: Double
    let hipExtensionRangeLeft: Double
    let hipExtensionRangeRight: Double
    let ankleDorsiRangeLeft: Double
    let ankleDorsiRangeRight: Double
    let elbowRangeLeft: Double
    let elbowRangeRight: Double
    let footStrikePattern: String
    let armSwingSymmetry: Double

    // MARK: Measurement confidence / uncertainty (honesty layer)
    // These describe how much to trust the headline numbers given the capture.
    // Defaulted so existing initializer call sites stay valid.
    /// 0–1. Trust in `footStrikePattern`. Low at <120fps because foot strike is
    /// read from a single contact frame; collapses further when heel/forefoot
    /// counts are close or few strikes were detected.
    var footStrikeConfidence: Double = 0
    /// ± milliseconds on each ground-contact-time figure, driven purely by the
    /// frame interval (one frame of ambiguity at each of strike and toe-off).
    var groundContactUncertaintyMs: Double = 0
    /// The fps the analysis actually ran at — the hard ceiling on timing precision.
    var captureFrameRate: Double = 0

    // Camera-facing-side ROMs for the DRIVE model. The far side inflates
    // under occlusion (see powerResult); 0 = not measured.
    var kneeFlexionRangeSelected: Double = 0
    var hipExtensionRangeSelected: Double = 0
    var ankleDorsiRangeSelected: Double = 0
}

struct GaitCycleInterval {
    let startTime: Double
    let endTime: Double
    let toeOffTime: Double
    /// True stance duration (ms) from vertical foot motion, plausibility-gated.
    /// NaN when it couldn't be measured. Prefer this over toeOffTime-startTime,
    /// which is anchored to the forward-reach peak and over-counts contact.
    var contactMs: Double = .nan
}

struct GaitCycleSeries {
    let bins: Int
    let leftKneeAngle: [Double]
    let rightKneeAngle: [Double]
    let leftKneeAngleStd: [Double]
    let rightKneeAngleStd: [Double]
    let leftKneeCycles: [[Double]]
    let rightKneeCycles: [[Double]]
    let leftHipAngle: [Double]
    let rightHipAngle: [Double]
    let leftHipAngleStd: [Double]
    let rightHipAngleStd: [Double]
    let leftHipCycles: [[Double]]
    let rightHipCycles: [[Double]]
    let leftAnkleAngle: [Double]
    let rightAnkleAngle: [Double]
    let leftAnkleAngleStd: [Double]
    let rightAnkleAngleStd: [Double]
    let leftAnkleCycles: [[Double]]
    let rightAnkleCycles: [[Double]]
    let leftFootY: [Double]
    let rightFootY: [Double]
    let leftFootYStd: [Double]
    let rightFootYStd: [Double]
    let leftFootYCycles: [[Double]]
    let rightFootYCycles: [[Double]]
    let leftFootVelocity: [Double]
    let rightFootVelocity: [Double]
    let leftFootVelocityStd: [Double]
    let rightFootVelocityStd: [Double]
    let leftFootVelocityCycles: [[Double]]
    let rightFootVelocityCycles: [[Double]]
    let leftStancePercent: Double
    let rightStancePercent: Double
    let leftCycles: [GaitCycleInterval]
    let rightCycles: [GaitCycleInterval]
}

struct MetricSeries {
    let durationSeconds: Double
    let analysisStartTime: Double
    let cadenceSeries: [Double]
    let strideLengthSeries: [Double]
    let groundContactLeftSeries: [Double]
    let groundContactRightSeries: [Double]
    let verticalOscillationSeries: [Double]
    let kneeAngleSeries: [Double]
    let hipDropSeries: [Double]
    let gaitCycleSeries: GaitCycleSeries?
    
    // Per-frame joint angle time series (for video-synced graphs)
    let leftKneeAngleTimeSeries: [Double]
    let rightKneeAngleTimeSeries: [Double]
    let leftHipAngleTimeSeries: [Double]
    let rightHipAngleTimeSeries: [Double]
    let leftAnkleAngleTimeSeries: [Double]
    let rightAnkleAngleTimeSeries: [Double]
    let leftFootYTimeSeries: [Double]
    let rightFootYTimeSeries: [Double]
    let leftFootVelTimeSeries: [Double]
    let rightFootVelTimeSeries: [Double]
    
    // Angular velocity series for phase plots
    let leftKneeAngularVelocitySeries: [Double]
    let rightKneeAngularVelocitySeries: [Double]
    let leftHipAngularVelocitySeries: [Double]
    let rightHipAngularVelocitySeries: [Double]
    
    // Symmetry index series
    let kneeSymmetrySeries: [Double]
    let gctSymmetrySeries: [Double]
    
    // Additional movement graphs
    let footVelocityXSeries: [Double]  // Combined left/right foot X velocity
    let hipMovementYSeries: [Double]  // Closest hip Y position over time
    let headBobbingYSeries: [Double]   // Nose Y position over time (head bobbing)
    let armMovementXSeries: [Double]   // Wrist X position over time (arm swing)
    let torsoAngleMean: Double         // Mean torso lean from vertical over full video (selected side)
    let headAngleMean: Double          // Mean head forward tilt from vertical (nose-to-neck) over full video
    let elbowAngleMean: Double         // Mean elbow interior angle (shoulder-elbow-wrist) for selected side
    let kneeAngleMean: Double          // Mean interior knee angle (hip-knee-ankle) for selected side
    let hipAngleMean: Double           // Mean interior hip angle (shoulder-hip-knee) for selected side
    
    let perFrameTorsoAngles: [Double]  // Frame-indexed torso angles (NaN if missing)
    let perFrameGazeAngles: [Double]   // Frame-indexed baseline-corrected gaze angles (NaN if missing)
    let perFrameElbowAngles: [Double]  // Frame-indexed elbow interior angles (NaN if missing)
    
    // Scale factor: estimated body height in pixels (shoulder-to-ankle median)
    // Used to convert pixel measurements to real-world units via: realCm = px * (userHeightM / bodyHeightPx) * 100
    let bodyHeightPixels: Double
    
    // Foot-to-hip distance signals (filtered, in pixels)
    let leftFootHipDistanceSeries: [Double]  // Left foot-to-hip horizontal distance
    let rightFootHipDistanceSeries: [Double]  // Right foot-to-hip horizontal distance
    
    // Heel strike frame indices (for snapshot feature)
    let heelStrikeFrameIndices: [Int]  // Frame indices where heel strikes occur (peaks in foot-to-hip distance)

    // Form cue scores (0-100) and raw values
    let formCueScores: [FormCueScore]

    // Clip frame rate (fps) — gates the spring-mass Power model's confidence.
    var frameRate: Double = 30
    // SIGNED shank inclination at initial contact (degrees). + = shank leans forward
    // of vertical (foot ahead of body → overstride); − = vertical/behind (good).
    // NaN when not measurable. Used by the Impact model and Efficiency overstride cue.
    var shankAngleAtContactSignedDeg: Double = .nan
    // Fraction of stances where the heel never dropped to the ground (0-1).
    // NaN when too few stances were readable. Feeds the footPlacement cue cap
    // and the DRIVE calf-bounce discount.
    var noHeelRatio: Double = .nan
}

struct FormCueScore: Identifiable {
    let id = UUID()
    let cue: FormCue
    let score: Double
    let rawValue: Double
    let mean: Double
    let std: Double
}

enum FormCue: String, CaseIterable {
    case shinVertical = "Shin vertical at contact"
    case quietFeet = "Quiet feet (low braking)"
    case tallPosture = "Tall posture"
    case shortQuickSteps = "Short, quick steps"
    case footUnderCOM = "Foot under COM"
    case elbows = "Elbows ~90°, swing back"
    case hipsStable = "Hips stable"
    case eyesForward = "Eyes forward"
    case footPlacement = "Midfoot landing"
}

enum CueDirection {
    case higherBetter
    case lowerBetter
    case targetRange
}

struct FormCueRange {
    let targetMin: Double
    let targetMax: Double
    let warnMin: Double
    let warnMax: Double
    let direction: CueDirection
}

private enum FormCueRanges {
    static let ranges: [FormCue: FormCueRange] = [
        .shinVertical: FormCueRange(targetMin: 6, targetMax: 13, warnMin: 3, warnMax: 17, direction: .targetRange),
        .quietFeet: FormCueRange(targetMin: 0, targetMax: 0.08, warnMin: 0, warnMax: 0.15, direction: .lowerBetter),
        .tallPosture: FormCueRange(targetMin: 4, targetMax: 10, warnMin: 2, warnMax: 14, direction: .targetRange),
        // 165+ covers healthy easy-run turnover; 175-195 as target-only punished
        // legitimately relaxed elite form (154-172 spm reads in the field).
        .shortQuickSteps: FormCueRange(targetMin: 162, targetMax: 195, warnMin: 148, warnMax: 205, direction: .targetRange),
        // Fraction of stride length the ankle lands ahead of the hip. ~a quarter
        // stride is normal mechanics at any speed; past ~40% the foot is reaching.
        .footUnderCOM: FormCueRange(targetMin: 0, targetMax: 0.27, warnMin: 0, warnMax: 0.42, direction: .lowerBetter),
        .elbows: FormCueRange(targetMin: 80, targetMax: 100, warnMin: 70, warnMax: 110, direction: .targetRange),
        .hipsStable: FormCueRange(targetMin: 0, targetMax: 4, warnMin: 0, warnMax: 7, direction: .lowerBetter),
        .eyesForward: FormCueRange(targetMin: -5, targetMax: 5, warnMin: -12, warnMax: 12, direction: .targetRange),
        .footPlacement: FormCueRange(targetMin: -8, targetMax: 8, warnMin: -18, warnMax: 18, direction: .targetRange)
    ]
}

class VideoProcessor: ObservableObject {
    /// One instance for the whole app: the pose model load is heavy, and a
    /// per-view instance meant every Analyze tab visit reloaded it — and a
    /// tab switch mid-analysis destroyed the run entirely.
    static let shared = VideoProcessor()

    @Published var progress: Double = 0
    @Published var isProcessing = false
    @Published var processedVideoURL: URL?
    @Published var error: String?
    @Published var poseEngineName: String = ""
    @Published var usingBlazePose: Bool = false
    /// Set when the finished scan's tracking-quality signals say the clip was
    /// hard to read (bad framing/lighting/occlusion). Distinct from `error`:
    /// processing SUCCEEDED, but the result shouldn't be fully trusted. The UI
    /// shows a non-blocking banner pointing at the filming instructions.
    @Published var scanQualityWarning: String?

    init() {
        // Read engine info off the single stored detector — creating a second
        // detector here doubled the model load time.
        poseEngineName = poseDetector.engineName
        usingBlazePose = poseDetector.isBlazePose
    }
    @Published var analysisMetrics: AnalysisMetrics?
    @Published var metricSeries: MetricSeries?
    
    var videoMode: VideoMode = .side
    /// Auto-detected during processing: which side faces the camera in side view.
    var selectedSide: BodySide? = nil
    
    // Pose detector (initialized lazily to avoid heavy model load on app launch)
    // Initialize with BlazePose if available, otherwise Vision
    private var poseDetector: PoseDetector = PoseDetectorFactory.make(preferBlazePose: true)
    private let requireBlazePose: Bool = false  // Set to true to require MediaPipe, false to allow Vision fallback
    
    // Skeleton orientation fix: Set to true to mirror horizontally, false to use coordinates directly
    // Try toggling this if skeleton appears backwards
    // Currently set to false - if skeleton is backwards, change to true
    private let mirrorSkeletonX: Bool = false
    
    // Fallback smoothing for edge cases
    private var previousPoints: [PoseJoint: CGPoint] = [:]
    private var missingFrameCount: [PoseJoint: Int] = [:]
    private let maxMissingFrames: Int = 5

    // Corrects BlazePose's left/right label flips (side-view legs scissoring)
    // by temporal continuity, BEFORE any downstream logic trusts the labels.
    private let identityStabilizer = PoseIdentityStabilizer()
    
    // Blip detection - permanently hide joints that teleport too often
    private var blipCount: [PoseJoint: Int] = [:]
    private var permanentlyHidden: Set<PoseJoint> = []
    private let maxBlipsBeforeHide: Int = 12
    private let blipThreshold: CGFloat = 0.25
    
    // Throttled progress reporting for UI updates during long frame loops
    private var lastReportedProgress: Double = -1
    private var lastProgressReportTime: CFAbsoluteTime = 0
    /// One shared Core Image context. Building CIContext per frame compiles a
    /// full GPU pipeline hundreds of times per clip and dominated export time.
    private let skeletonCIContext = CIContext()
    
    private static let progressFramesStart: Double = 0.05
    private static let progressFramesEnd: Double = 0.90
    
    private func resetProgressTracking() {
        lastReportedProgress = -1
        lastProgressReportTime = 0
    }
    
    private func publishProgress(_ value: Double, force: Bool = false) async {
        let clamped = min(max(value, 0), 1)
        let now = CFAbsoluteTimeGetCurrent()
        if !force {
            let delta = clamped - lastReportedProgress
            let elapsed = now - lastProgressReportTime
            guard delta >= 0.01 || elapsed >= 0.1 else { return }
        }
        lastReportedProgress = clamped
        lastProgressReportTime = now
        await MainActor.run {
            self.progress = clamped
        }
    }
    
    private static let fastMovingJoints: Set<PoseJoint> = [
        .leftAnkle, .rightAnkle, .leftHeel, .rightHeel,
        .leftFootIndex, .rightFootIndex, .leftKnee, .rightKnee
    ]
    private let fastBlipThreshold: CGFloat = 0.45
    private let fastJitterThreshold: CGFloat = 0.35
    
    private var poseFrames: [PoseFrame] = []
    
    // Skeleton connections (extended with BlazePose feet)
    private let connections: [(PoseJoint, PoseJoint)] = [
        (.nose, .neck),
        (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
        (.leftHip, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
        (.leftAnkle, .leftHeel), (.leftHeel, .leftFootIndex), (.leftAnkle, .leftFootIndex),
        (.rightAnkle, .rightHeel), (.rightHeel, .rightFootIndex), (.rightAnkle, .rightFootIndex)
    ]
    
    func processVideo(url: URL) async {
        await MainActor.run {
            isProcessing = true
            progress = 0
            error = nil
            scanQualityWarning = nil
            processedVideoURL = nil
            analysisMetrics = nil
            metricSeries = nil
        }
        resetProgressTracking()
        await publishProgress(0.01, force: true)
        
        poseDetector = PoseDetectorFactory.make(preferBlazePose: true)
        let isBlaze = poseDetector.isBlazePose
        let engineName = poseDetector.engineName
        debugLog("Pose engine: \(engineName) | BlazePose: \(isBlaze)")
        await MainActor.run {
            usingBlazePose = isBlaze
            poseEngineName = engineName
        }
        await publishProgress(0.03, force: true)
        
        if requireBlazePose && !usingBlazePose {
            await MainActor.run {
                var details = "BlazePose not available."
#if canImport(MediaPipeTasksVision)
                if BlazePoseDetector.modelPath() == nil {
                    details += " Model file not found in app bundle."
                } else {
                    details += " MediaPipeTasksVision is present, but PoseLandmarker failed to initialize."
                }
#else
                details += " MediaPipeTasksVision is not linked. Please build from RunRightApp.xcworkspace."
#endif
                self.error = details
                self.isProcessing = false
            }
            return
        }

        poseDetector.reset()
        identityStabilizer.reset()
        previousPoints = [:]
        missingFrameCount = [:]
        blipCount = [:]
        permanentlyHidden = []
        poseFrames = []
        selectedSide = nil
        
        do {
            let outputURL = try await processVideoFrames(inputURL: url)
            await publishProgress(1.0, force: true)
            // Temp hygiene: the imported copy is done with, and the previous
            // processed clip would otherwise sit in tmp/ forever (one per analysis).
            try? FileManager.default.removeItem(at: url)
            await MainActor.run {
                if let old = processedVideoURL, old != outputURL {
                    try? FileManager.default.removeItem(at: old)
                }
                processedVideoURL = outputURL
                isProcessing = false
                progress = 1.0
            }
        } catch {
            // Raw AVFoundation errors ("The operation couldn't be completed…")
            // read as a bug to a reviewer. Log the detail, show something actionable.
            debugLog("[VideoProcessor] processing failed: \(error.localizedDescription)")
            await MainActor.run {
                self.error = "We couldn't read that video. Film a fresh clip in the Camera app (screen recordings and downloaded or protected videos may not work)."
                isProcessing = false
            }
        }
    }

    // Public method to access PoseFrame at a specific index (for snapshot feature)
    func getPoseFrame(at index: Int) -> PoseFrame? {
        guard index >= 0 && index < poseFrames.count else {
            return nil
        }
        return poseFrames[index]
    }

    /// Drop per-clip buffers once the analysis is discarded — poseFrames alone
    /// holds every landmark of every frame and otherwise lives until the next run.
    func releaseAnalysisBuffers() {
        poseFrames = []
        previousPoints = [:]
        missingFrameCount = [:]
        blipCount = [:]
        permanentlyHidden = []
    }

    /// The longest contiguous run of frames where the near-side lower-limb chain
    /// (hip/knee/ankle) AND the nose are all present — i.e. the runner is fully,
    /// accurately framed. Brief dropouts (<= ~0.15s) are bridged. Only measure
    /// from THIS window so entry/exit garbage and the tracking-lost tail (which
    /// flatlined the graphs and threw outlier angles) never enter the analysis.
    /// Falls back to the whole clip when no window reaches ~2s so short clips
    /// still analyse — `foundWindow: false` marks that fallback explicitly,
    /// because the fallback range covers everything and would otherwise read as
    /// a "perfect" clip to any quality check built on the ratio alone.
    static func cleanWindowRange(_ frames: [PoseFrame], frameRate: Double) -> (range: Range<Int>, foundWindow: Bool) {
        let n = frames.count
        guard n > 10 else { return (0..<n, false) }
        func wellFramed(_ f: PoseFrame) -> Bool {
            let right = f.facingRight
            let hip: PoseJoint = right ? .rightHip : .leftHip
            let knee: PoseJoint = right ? .rightKnee : .leftKnee
            let ankle: PoseJoint = right ? .rightAnkle : .leftAnkle
            return f.points[.nose] != nil && f.points[hip] != nil
                && f.points[knee] != nil && f.points[ankle] != nil
        }
        let flags = frames.map(wellFramed)
        let maxGap = max(2, Int((frameRate * 0.15).rounded()))
        var bestStart = 0, bestEnd = -1   // inclusive
        var i = 0
        while i < n {
            if !flags[i] { i += 1; continue }
            var j = i, gap = 0, lastGood = i
            while j < n {
                if flags[j] { lastGood = j; gap = 0 }
                else { gap += 1; if gap > maxGap { break } }
                j += 1
            }
            if lastGood - i > bestEnd - bestStart { bestStart = i; bestEnd = lastGood }
            i = max(lastGood + 1, i + 1)
        }
        let minFrames = Int((frameRate * 2.0).rounded())
        if bestEnd >= bestStart, (bestEnd - bestStart + 1) >= minFrames {
            return (bestStart..<(bestEnd + 1), true)
        }
        return (0..<n, false)
    }

    /// The sub-range where the runner is actively RUNNING. When they stop (walk
    /// off, stand), the foot's vertical motion flatlines — a standing runner is
    /// still "well framed", so cleanWindowRange keeps those frames, and they'd
    /// otherwise drag down the averages, cadence and cycle detection. This keeps
    /// the longest contiguous span whose rolling foot-motion amplitude clears a
    /// fraction of the running level. Returns the FULL range when it can't
    /// distinguish (uniform motion) so an all-running clip is never over-trimmed.
    static func activeRunningRange(_ frames: [PoseFrame], frameRate: Double) -> Range<Int> {
        let n = frames.count
        guard n > 10 else { return 0..<n }
        // Near-side foot vertical position per frame (ankle, fallback foot index).
        let footY: [Double] = frames.map { f in
            let ankle: PoseJoint = f.facingRight ? .rightAnkle : .leftAnkle
            let toe: PoseJoint = f.facingRight ? .rightFootIndex : .leftFootIndex
            if let p = f.points[ankle] { return Double(p.y) }
            if let p = f.points[toe] { return Double(p.y) }
            return .nan
        }
        // Frame-to-frame vertical speed.
        var speed = [Double](repeating: .nan, count: n)
        for i in 1..<n where footY[i].isFinite && footY[i - 1].isFinite {
            speed[i] = abs(footY[i] - footY[i - 1])
        }
        // Rolling peak motion over ~0.5s (a stride phase): high while running,
        // near zero while standing.
        let w = max(3, Int((frameRate * 0.5).rounded()))
        var amp = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - w / 2), hi = min(n - 1, i + w / 2)
            var m = 0.0
            for j in lo...hi where speed[j].isFinite { m = max(m, speed[j]) }
            amp[i] = m
        }
        let sortedActive = amp.filter { $0 > 0 }.sorted()
        guard sortedActive.count > 5 else { return 0..<n }
        let p75 = sortedActive[Int(Double(sortedActive.count - 1) * 0.75)]
        guard p75 > 0 else { return 0..<n }
        let thresh = p75 * 0.30   // "moving" if rolling peak motion >= 30% of the running level
        let moving = amp.map { $0 >= thresh }
        // Longest contiguous moving span, bridging brief gaps (~0.2s).
        let maxGap = max(2, Int((frameRate * 0.2).rounded()))
        var bestStart = 0, bestEnd = -1, i = 0
        while i < n {
            if !moving[i] { i += 1; continue }
            var j = i, gap = 0, lastGood = i
            while j < n {
                if moving[j] { lastGood = j; gap = 0 }
                else { gap += 1; if gap > maxGap { break } }
                j += 1
            }
            if lastGood - i > bestEnd - bestStart { bestStart = i; bestEnd = lastGood }
            i = max(lastGood + 1, i + 1)
        }
        return bestEnd >= bestStart ? bestStart..<(bestEnd + 1) : 0..<n
    }

    // MARK: - Scan quality (v1 gate)

    /// Whole-clip quality verdict from the tracking signals the pipeline already
    /// produces. v1 deliberately uses ONE OR'd signal family and a single generic
    /// message; per-cause attribution (dark/off-angle/left-frame) is a later
    /// stage once these thresholds are calibrated against real clips.
    struct ScanQualitySignals {
        let totalFrames: Int
        let cleanFrames: Int
        let cleanRatio: Double
        let cleanSeconds: Double
        let foundWindow: Bool
        let hiddenCoreJointCount: Int
        let jitterRatio: Double
        let flagged: Bool

        /// v2 named cause: turns the generic "hard to read" into an actionable
        /// reason, so the user knows WHAT to fix. Priority cascade, most specific
        /// first. Only uses signals validated on real clips (occlusion, window,
        /// duration, clean ratio) — off-angle / motion-blur / dark are left to a
        /// later pass that needs a luma signal + single-cause test footage.
        /// nil when the clip is not flagged.
        var cause: String? {
            guard flagged else { return nil }
            if hiddenCoreJointCount >= 1 {
                return "Keep your whole body in the shot, with no one else in frame."
            }
            if !foundWindow {
                return "Film side on with your whole body in frame."
            }
            if jitterRatio > scanQualityMaxJitterRatio {
                return "Tracking was jumpy — retake with the runner well lit and clear of the background."
            }
            if cleanSeconds < scanQualityMinCleanSeconds {
                return "Film a longer clip, about 10 to 15 seconds."
            }
            // cleanRatio below floor: tracked, but most of the clip was noisy.
            return "Film in steadier light with the camera held still."
        }
    }

    static func scanQualitySignals(
        totalFrames: Int,
        cleanFrames: Int,
        foundWindow: Bool,
        fps: Double,
        permanentlyHidden: Set<PoseJoint>,
        jitterRatio: Double
    ) -> ScanQualitySignals {
        let ratio = totalFrames > 0 ? Double(cleanFrames) / Double(totalFrames) : 0
        let seconds = fps > 0 ? Double(cleanFrames) / fps : 0
        let core: Set<PoseJoint> = [.leftHip, .rightHip, .leftKnee, .rightKnee,
                                    .leftAnkle, .rightAnkle, .nose]
        let hiddenCore = permanentlyHidden.intersection(core).count
        // Provisional thresholds, biased to UNDER-trigger (a false "retake" on a
        // good clip costs more trust than a missed disclosure). The calibration
        // log below exists to tune these against real clips before trusting them.
        let flagged = !foundWindow
            || ratio < scanQualityMinCleanRatio
            || seconds < scanQualityMinCleanSeconds
            || hiddenCore >= 1
            || jitterRatio > scanQualityMaxJitterRatio
        return ScanQualitySignals(
            totalFrames: totalFrames,
            cleanFrames: cleanFrames,
            cleanRatio: ratio,
            cleanSeconds: seconds,
            foundWindow: foundWindow,
            hiddenCoreJointCount: hiddenCore,
            jitterRatio: jitterRatio,
            flagged: flagged
        )
    }

    /// Choppy-tracking signal: the fraction of clean-window frames where the
    /// near-side HIP jumps implausibly far between consecutive frames, normalised
    /// by leg length (hip→ankle) so it is scale-invariant. The hip barely moves
    /// frame-to-frame in real running, so a large jump means the skeleton snapped
    /// to a wrong position — i.e. unstable tracking. Measured on the hip (NOT the
    /// fast-swinging legs) so smooth fast running never registers as jitter.
    static func skeletonJitterRatio(_ frames: [PoseFrame]) -> Double {
        guard frames.count > 5 else { return 0 }
        var jumps = 0, counted = 0
        for i in 1..<frames.count {
            let a = frames[i - 1], b = frames[i]
            let hipA: PoseJoint = a.facingRight ? .rightHip : .leftHip
            let ankleA: PoseJoint = a.facingRight ? .rightAnkle : .leftAnkle
            let hipB: PoseJoint = b.facingRight ? .rightHip : .leftHip
            guard let h0 = a.points[hipA], let h1 = b.points[hipB],
                  let k0 = a.points[ankleA] else { continue }
            let legLen = hypot(Double(h0.x - k0.x), Double(h0.y - k0.y))
            guard legLen > 1e-6 else { continue }
            let hipStep = hypot(Double(h1.x - h0.x), Double(h1.y - h0.y)) / legLen
            counted += 1
            if hipStep > 0.18 { jumps += 1 }   // >18% of leg length in one frame = a snap
        }
        return counted > 0 ? Double(jumps) / Double(counted) : 0
    }

    /// DEBUG-only calibration log: one CSV row per analysis in Documents, so
    /// thresholds can be derived from real clips instead of guessed.
    private func logScanQuality(_ q: ScanQualitySignals, clip: String) {
#if DEBUG
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = dir.appendingPathComponent("scan_quality_log.csv")
        let header = "date,clip,totalFrames,cleanFrames,cleanRatio,cleanSeconds,foundWindow,hiddenCore,jitterRatio,flagged\n"
        let row = "\(Date().timeIntervalSince1970),\(clip),\(q.totalFrames),\(q.cleanFrames),"
            + String(format: "%.3f", q.cleanRatio) + ","
            + String(format: "%.2f", q.cleanSeconds) + ","
            + "\(q.foundWindow),\(q.hiddenCoreJointCount),"
            + String(format: "%.3f", q.jitterRatio) + ","
            + "\(q.flagged)\n"
        if !FileManager.default.fileExists(atPath: file.path) {
            try? (header + row).write(to: file, atomically: true, encoding: .utf8)
        } else if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(Data(row.utf8))
            try? handle.close()
        }
        debugLog("[ScanQuality] \(clip) ratio=\(q.cleanRatio) secs=\(q.cleanSeconds) found=\(q.foundWindow) hiddenCore=\(q.hiddenCoreJointCount) jitter=\(q.jitterRatio) flagged=\(q.flagged)")
#endif
    }

    private func processVideoFrames(inputURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)
        
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.noVideoTrack
        }
        
        let duration = try await asset.load(.duration)
        let durationSeconds = max(duration.seconds, 0.001)
        await publishProgress(0.035, force: true)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        
        // Get the actual display size for the oriented output
        let (renderWidth, renderHeight) = getRenderSize(naturalSize: naturalSize, transform: transform)
        let visionOrientation: CGImagePropertyOrientation = .up
        
        // Determine if we need to mirror based on transform matrix
        // Transform matrix: [a b; c d; tx ty]
        // Horizontal flip indicated by: a < 0 (flip + scale) or b != 0 (rotation that includes flip)
        // For most video orientations, we need to mirror to match the final rendered frame
        let needsHorizontalMirror = transform.a < 0 || (transform.b != 0 && abs(transform.b) > abs(transform.a))
        
        // Setup output
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        
        // Output video at the correct display dimensions
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: renderWidth,
            AVVideoHeightKey: renderHeight
        ]
        
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        writerInput.expectsMediaDataInRealTime = false
        // Don't apply transform - we're rendering at correct dimensions already
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: renderWidth,
                kCVPixelBufferHeightKey as String: renderHeight
            ]
        )
        
        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        
        // Setup reader (use video composition to apply orientation)
        let reader = try AVAssetReader(asset: asset)
        
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: renderWidth, height: renderHeight)
        let fallbackFPS: Float64 = frameRate > 0 ? Float64(frameRate) : 30
        let timeScale = CMTimeScale(max(Int32(1), Int32(round(fallbackFPS))))
        videoComposition.frameDuration = CMTime(value: 1, timescale: timeScale)
        
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction]
        
        let readerOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        readerOutput.videoComposition = videoComposition
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)
        reader.startReading()
        
        await publishProgress(0.04, force: true)
        await publishProgress(Self.progressFramesStart, force: true)
        
        var sideVotes: [BodySide] = []
        var lastActiveSide: BodySide? = nil
        var framesSinceYield = 0

        // Process frames
        while reader.status == .reading {
            if !writerInput.isReadyForMoreMediaData {
                // If the writer fails mid-stream (disk full, malformed buffer),
                // `isReadyForMoreMediaData` latches false while the reader stays
                // `.reading` — without this check the loop would sleep-spin
                // forever and the analysis would hang at a frozen progress bar.
                if writer.status == .failed {
                    throw writer.error ?? ProcessingError.writeFailed
                }
                try await Task.sleep(nanoseconds: 2_000_000)
                continue
            }
            guard let sampleBuffer = readerOutput.copyNextSampleBuffer(),
                  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                break
            }
            
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            var frameProgress = Self.progressFramesStart
            
            autoreleasepool {
                    // Detect pose (BlazePose if available, Vision fallback)
                    let timestampMs = Int(presentationTime.seconds * 1000)
                    let observation = self.identityStabilizer.stabilize(
                        self.poseDetector.detectPose(
                            pixelBuffer: pixelBuffer,
                            orientation: visionOrientation,
                            timestampMs: timestampMs
                        )
                    )

                    // Convert normalized coordinates to pixels and apply filtering/smoothing
                    var bodyPoints: [PoseJoint: CGPoint] = [:]
                    var bodyPoints3D: [PoseJoint: SIMD3<Double>] = observation.points3D
                    let jointNames: [PoseJoint] = PoseJoint.allCases
                    
                        for jointName in jointNames {
                            // Skip permanently hidden joints
                            if self.permanentlyHidden.contains(jointName) { continue }
                            
                        if let point = observation.points2D[jointName] {
                            // Coordinates are normalized 0-1
                            // Convert to pixel coordinates
                            let xCoord = point.x * CGFloat(renderWidth)
                            let yCoord = point.y * CGFloat(renderHeight)
                            // Mirror horizontally if needed - toggle mirrorSkeletonX flag to test
                                let newPoint = CGPoint(
                                x: mirrorSkeletonX ? (CGFloat(renderWidth) - xCoord) : xCoord,
                                y: yCoord
                                )
                                
                                // Check for teleportation/blip
                                if let prevPoint = self.previousPoints[jointName] {
                                    let dx = abs(newPoint.x - prevPoint.x) / CGFloat(renderWidth)
                                    let dy = abs(newPoint.y - prevPoint.y) / CGFloat(renderHeight)
                                    let thresh = Self.fastMovingJoints.contains(jointName)
                                        ? self.fastBlipThreshold
                                        : self.blipThreshold
                                    if dx > thresh || dy > thresh {
                                        // Teleport detected
                                        let count = (self.blipCount[jointName] ?? 0) + 1
                                        self.blipCount[jointName] = count
                                        
                                        if count >= self.maxBlipsBeforeHide {
                                            // Too many blips - hide permanently
                                            self.permanentlyHidden.insert(jointName)
                                            continue
                                        }
                                        
                                        // Use previous point instead of blipped one
                                        bodyPoints[jointName] = prevPoint
                                        continue
                                    }
                                }
                                
                                bodyPoints[jointName] = newPoint
                                self.missingFrameCount[jointName] = 0
                            } else {
                                let missCount = (self.missingFrameCount[jointName] ?? 0) + 1
                                self.missingFrameCount[jointName] = missCount
                                if let prevPoint = self.previousPoints[jointName], missCount <= self.maxMissingFrames {
                                    bodyPoints[jointName] = prevPoint
                                }
                            }
                        }
                    
                    if videoMode == .side, selectedSide == nil,
                       let vote = detectFacingSide(from: bodyPoints, minMarginFraction: 0.06) {
                        sideVotes.append(vote)
                        if sideVotes.count >= sideDetectionVoteThreshold {
                            selectedSide = majoritySide(sideVotes) ?? .right
                        }
                    }

                    // The side that governs which leg we keep + draw. Before the
                    // lock, use the RUNNING MAJORITY (not this frame's noisy nose
                    // vote) so the skeleton never flickers between legs, and hold
                    // the last decision if a frame is momentarily ambiguous.
                    let activeSide = selectedSide ?? majoritySide(sideVotes) ?? lastActiveSide ?? .right
                    lastActiveSide = activeSide
                    
                    // Hide far-side forearm (visible side faces camera).
                    let forearmToHide: BodySide = activeSide == .right ? .left : .right
                    
                    if forearmToHide == .left {
                        bodyPoints.removeValue(forKey: .leftElbow)
                        bodyPoints.removeValue(forKey: .leftWrist)
                    } else {
                        bodyPoints.removeValue(forKey: .rightElbow)
                        bodyPoints.removeValue(forKey: .rightWrist)
                    }
                    
                    self.previousPoints = bodyPoints
                    
                    if forearmToHide == .left {
                        self.previousPoints.removeValue(forKey: .leftElbow)
                        self.previousPoints.removeValue(forKey: .leftWrist)
                        self.missingFrameCount[.leftElbow] = 0
                        self.missingFrameCount[.leftWrist] = 0
                    } else {
                        self.previousPoints.removeValue(forKey: .rightElbow)
                        self.previousPoints.removeValue(forKey: .rightWrist)
                        self.missingFrameCount[.rightElbow] = 0
                        self.missingFrameCount[.rightWrist] = 0
                    }
                    
                    if videoMode == .side {
                        let keepRight = activeSide == .right
                        
                        // Remove ALL joints from the far (occluded) side
                        let jointsToRemove: [PoseJoint] = keepRight
                            ? [.leftShoulder, .leftElbow, .leftWrist, .leftHip, .leftKnee, .leftAnkle, .leftHeel, .leftFootIndex]
                            : [.rightShoulder, .rightElbow, .rightWrist, .rightHip, .rightKnee, .rightAnkle, .rightHeel, .rightFootIndex]
                        for joint in jointsToRemove {
                            bodyPoints.removeValue(forKey: joint)
                            bodyPoints3D.removeValue(forKey: joint)
                        }
                        
                        // Remove low-confidence joints on the visible side if they're too noisy
                        let visibleSideJoints: [PoseJoint] = keepRight
                            ? [.rightShoulder, .rightElbow, .rightWrist, .rightHip, .rightKnee, .rightAnkle, .rightHeel, .rightFootIndex]
                            : [.leftShoulder, .leftElbow, .leftWrist, .leftHip, .leftKnee, .leftAnkle, .leftHeel, .leftFootIndex]
                        
                        for joint in visibleSideJoints {
                            if let point = bodyPoints[joint] {
                                if let prev = self.previousPoints[joint] {
                                    let distance = hypot(point.x - prev.x, point.y - prev.y)
                                    let frameSize = CGFloat(max(renderWidth, renderHeight))
                                    let jitterLimit = Self.fastMovingJoints.contains(joint)
                                        ? frameSize * self.fastJitterThreshold
                                        : frameSize * 0.15
                                    if distance > jitterLimit {
                                        bodyPoints.removeValue(forKey: joint)
                                        bodyPoints3D.removeValue(forKey: joint)
                                    }
                                }
                            }
                        }
                    }
                    
                    if !bodyPoints.isEmpty {
                        let facingRight = activeSide == .right
                        self.poseFrames.append(
                            PoseFrame(
                                time: presentationTime.seconds,
                                points: bodyPoints,
                                points3D: bodyPoints3D,
                                facingRight: facingRight
                            )
                        )
                    }
                    
                    // Draw skeleton on properly oriented frame
                    let renderSize = CGSize(width: renderWidth, height: renderHeight)
                    if let processedBuffer = self.drawSkeletonOnFrame(
                        pixelBuffer: pixelBuffer,
                        renderSize: renderSize,
                        points: bodyPoints,
                        pool: adaptor.pixelBufferPool
                    ) {
                        adaptor.append(processedBuffer, withPresentationTime: presentationTime)
                    }
                    
                    let videoFraction = min(presentationTime.seconds / durationSeconds, 1.0)
                    let frameSpan = Self.progressFramesEnd - Self.progressFramesStart
                    frameProgress = Self.progressFramesStart + videoFraction * frameSpan
            }
            
            // Only hop actors when the throttle would actually publish.
            if frameProgress - lastReportedProgress >= 0.01
                || CFAbsoluteTimeGetCurrent() - lastProgressReportTime >= 0.1 {
                await publishProgress(frameProgress)
            }
            framesSinceYield += 1
            if framesSinceYield >= 5 {
                framesSinceYield = 0
                await Task.yield()
            }
        }
        
        writerInput.markAsFinished()
        await writer.finishWriting()
        await publishProgress(0.93, force: true)
        
        if writer.status == .failed {
            throw writer.error ?? ProcessingError.writeFailed
        }
        
        if videoMode == .side {
            if selectedSide == nil {
                if let majority = majoritySide(sideVotes) {
                    selectedSide = majority
                } else {
                    debugLog("[SIDE DETECT] No valid votes; defaulting to right")
                    selectedSide = .right
                }
            }
            debugLog("[SIDE DETECT] Locked facing side: \(selectedSide == .right ? "right" : "left") (\(sideVotes.count) votes)")
        }
        
        let fps = frameRate > 0 ? Double(frameRate) : 30
        // Restrict analysis to the longest contiguous window of accurate framing
        // (runner fully tracked). This drops the entry/exit garbage and the
        // tracking-lost tail that produced flatlined graphs and outlier angles.
        // Slice self.poseFrames itself so getPoseFrame (snapshot) and the metric
        // series share ONE index space.
        let (cleanRange, foundWindow) = Self.cleanWindowRange(poseFrames, frameRate: fps)
        // Choppiness measured on the clean window (where hip/ankle are present).
        let jitter = Self.skeletonJitterRatio(Array(poseFrames[cleanRange]))
        // Scan-quality signals — read BEFORE the slice destroys the denominator.
        let quality = Self.scanQualitySignals(
            totalFrames: poseFrames.count,
            cleanFrames: cleanRange.count,
            foundWindow: foundWindow,
            fps: fps,
            permanentlyHidden: permanentlyHidden,
            jitterRatio: jitter
        )
        logScanQuality(quality, clip: inputURL.lastPathComponent)
        poseFrames = Array(poseFrames[cleanRange])
        // Then trim to the ACTIVELY RUNNING span so a stopped/standing tail (flat
        // signal) doesn't skew the averages, cadence or cycle detection — and,
        // since the metric series is built from these frames, the trend graphs
        // stop flatlining too. Only applied when it finds a real running sub-span
        // (>= 1.5s) shorter than the whole clip; otherwise the clip is kept intact.
        let activeRange = Self.activeRunningRange(poseFrames, frameRate: fps)
        if activeRange.count >= Int((fps * 1.5).rounded()), activeRange.count < poseFrames.count {
            debugLog("[ActiveRun] trimmed stopped frames: kept \(activeRange) of \(poseFrames.count) (\(Int(Double(activeRange.count)/Double(poseFrames.count)*100))%)")
            poseFrames = Array(poseFrames[activeRange])
        }
        let computed = computeMetrics(frames: poseFrames, renderSize: CGSize(width: renderWidth, height: renderHeight), frameRate: fps)
        await publishProgress(0.98, force: true)
        // The framing/window/jitter gate runs before metrics, so it can't see the
        // measured data. Catch what it misses: physiologically impossible ROMs or
        // a non-periodic (jittery) gait mean the numbers can't be trusted even when
        // framing looked fine. Framing cause wins when both fire (it's more
        // actionable); otherwise fall through to the plausibility warning.
        let plausibility = dataPlausibilityWarning(metrics: computed.0, series: computed.1)
        await MainActor.run {
            self.analysisMetrics = computed.0
            self.metricSeries = computed.1
            self.scanQualityWarning = quality.cause ?? plausibility
        }

        // Encrypt the processed running video at rest (it depicts the user — health
        // data). completeUntilFirstUserAuthentication keeps it readable for playback
        // after the first unlock while encrypting it when the device is at rest.
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: outputURL.path
        )

        return outputURL
    }
    
    private func drawSkeletonOnFrame(pixelBuffer: CVPixelBuffer, renderSize: CGSize, points: [PoseJoint: CGPoint], pool: CVPixelBufferPool? = nil) -> CVPixelBuffer? {
        // Recycle buffers from the writer's pool when available; falling back to
        // a fresh allocation only when the pool is absent or exhausted.
        var outputBuffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &outputBuffer)
        }
        if outputBuffer == nil { CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(renderSize.width),
            Int(renderSize.height),
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &outputBuffer
        ) }

        guard let buffer = outputBuffer else { return nil }
        
        // Render the oriented video frame into the output buffer
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let ciContext = skeletonCIContext
        ciContext.render(ciImage, to: buffer, bounds: CGRect(origin: .zero, size: renderSize), colorSpace: CGColorSpaceCreateDeviceRGB())
        
        // Draw skeleton on top of the output buffer
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let pixelData = CVPixelBufferGetBaseAddress(buffer) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return nil
        }
        
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: pixelData,
            width: Int(renderSize.width),
            height: Int(renderSize.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: rgbColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            CVPixelBufferUnlockBaseAddress(buffer, [])
            return nil
        }
        
        // Flip context so coordinates match top-left origin (only vertical flip needed)
        ctx.translateBy(x: 0, y: renderSize.height)
        ctx.scaleBy(x: 1, y: -1)
        
        // No horizontal flip needed - pose coordinates already match transformed video frame
        
        // Draw skeleton if we have points
        if !points.isEmpty {
            // Draw connections
            ctx.setLineWidth(7.0)
            ctx.setLineCap(.round)
            
            for connection in connections {
                guard let start = points[connection.0], let end = points[connection.1] else { continue }
                let color = connectionColor(for: connection)
                ctx.setStrokeColor(color.cgColor)
                ctx.move(to: start)
                ctx.addLine(to: end)
                ctx.strokePath()
            }
            
            // Draw joints
            for (jointName, point) in points {
                let color = jointColor(for: jointName)
                ctx.setFillColor(color.cgColor)
                
                let radius: CGFloat = 8.0
                ctx.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                
                ctx.setStrokeColor(UIColor.white.cgColor)
                ctx.setLineWidth(2.0)
                ctx.strokeEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            }
        }
        
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }
    
    private func computeMetrics(
        frames: [PoseFrame],
        renderSize: CGSize,
        frameRate: Double
    ) -> (AnalysisMetrics, MetricSeries) {
        guard frames.count > 5 else {
            let emptyMetrics = AnalysisMetrics(
                cadence: 0,
                strideLength: 0,
                groundContactLeft: 0,
                groundContactRight: 0,
                verticalOscillation: 0,
                symmetryScore: 0,
                trunkLean: 0,
                headStability: 0,
                hipDrop: 0,
                kneeValgus: 0,
                kneeFlexionRangeLeft: 0,
                kneeFlexionRangeRight: 0,
                hipExtensionRangeLeft: 0,
                hipExtensionRangeRight: 0,
                ankleDorsiRangeLeft: 0,
                ankleDorsiRangeRight: 0,
                elbowRangeLeft: 0,
                elbowRangeRight: 0,
                footStrikePattern: "Unknown",
                armSwingSymmetry: 0
            )
            let emptySeries = MetricSeries(
                durationSeconds: 0,
                analysisStartTime: 0,
                cadenceSeries: [],
                strideLengthSeries: [],
                groundContactLeftSeries: [],
                groundContactRightSeries: [],
                verticalOscillationSeries: [],
                kneeAngleSeries: [],
                hipDropSeries: [],
                gaitCycleSeries: nil,
                leftKneeAngleTimeSeries: [],
                rightKneeAngleTimeSeries: [],
                leftHipAngleTimeSeries: [],
                rightHipAngleTimeSeries: [],
                leftAnkleAngleTimeSeries: [],
                rightAnkleAngleTimeSeries: [],
                leftFootYTimeSeries: [],
                rightFootYTimeSeries: [],
                leftFootVelTimeSeries: [],
                rightFootVelTimeSeries: [],
                leftKneeAngularVelocitySeries: [],
                rightKneeAngularVelocitySeries: [],
                leftHipAngularVelocitySeries: [],
                rightHipAngularVelocitySeries: [],
                kneeSymmetrySeries: [],
                gctSymmetrySeries: [],
                footVelocityXSeries: [],
                hipMovementYSeries: [],
                headBobbingYSeries: [],
                armMovementXSeries: [],
                torsoAngleMean: -1.0,
                headAngleMean: -1.0,
                elbowAngleMean: -1.0,
                kneeAngleMean: -1.0,
                hipAngleMean: -1.0,
                perFrameTorsoAngles: [],
                perFrameGazeAngles: [],
                perFrameElbowAngles: [],
                bodyHeightPixels: 0,
                leftFootHipDistanceSeries: [],
                rightFootHipDistanceSeries: [],
                heelStrikeFrameIndices: [],
                formCueScores: []
            )
            return (emptyMetrics, emptySeries)
        }
        
        let times = frames.map { $0.time }
        let duration = max(times.last ?? 0, 0.001)
        
        func point(_ frame: PoseFrame, _ joint: PoseJoint) -> CGPoint? {
            frame.points[joint]
        }
        
        func point3D(_ frame: PoseFrame, _ joint: PoseJoint) -> SIMD3<Double>? {
            frame.points3D[joint]
        }
        
        func midPoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        
        func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
            hypot(Double(a.x - b.x), Double(a.y - b.y))
        }
        
        func distance3D(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
            simd_distance(a, b)
        }
        
        func angleDegrees(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
            let ba = CGVector(dx: a.x - b.x, dy: a.y - b.y)
            let bc = CGVector(dx: c.x - b.x, dy: c.y - b.y)
            let dot = ba.dx * bc.dx + ba.dy * bc.dy
            let mag = hypot(ba.dx, ba.dy) * hypot(bc.dx, bc.dy)
            guard mag > 0 else { return 0 }
            let cosVal = max(-1.0, min(1.0, Double(dot) / Double(mag)))
            return acos(cosVal) * 180 / .pi
        }
        
        func angleDegrees3D(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> Double {
            let ba = a - b
            let bc = c - b
            let dot = simd_dot(ba, bc)
            let mag = simd_length(ba) * simd_length(bc)
            guard mag > 0 else { return 0 }
            let cosVal = max(-1.0, min(1.0, dot / mag))
            return acos(cosVal) * 180 / .pi
        }
        
        func shinVerticalAngleDeg(knee: CGPoint, ankle: CGPoint) -> Double {
            // Calculate shin vector (knee to ankle) - matches RunningFormMetrics
            let shinVec = CGPoint(x: knee.x - ankle.x, y: knee.y - ankle.y)
            let shinLength = hypot(Double(shinVec.x), Double(shinVec.y))
            guard shinLength > 0 else { return 0 }
            
            // Normalize the vector
            let normalized = CGPoint(x: shinVec.x / CGFloat(shinLength), y: shinVec.y / CGFloat(shinLength))
            
            // Use vertical reference vector pointing UP (0, -1)
            // In screen coordinates, Y increases downward, so UP is negative Y
            let vertical = CGPoint(x: 0, y: -1)
            
            // Calculate dot product: normalized · vertical
            let dot = Double(normalized.x * vertical.x + normalized.y * vertical.y)
            
            // Clamp dot product to [-1, 1] for acos
            let clampedDot = max(-1.0, min(1.0, dot))
            
            // Calculate angle from vertical using acos
            // 0° = perfectly vertical, increases for forward/backward lean
            let angleRad = acos(clampedDot)
            let angleDeg = angleRad * 180 / .pi
            
            // Return absolute value (we only care about magnitude of deviation from vertical)
            // This matches the proven verticalAngleDeg approach in RunningFormMetrics.swift
            return abs(angleDeg)
        }
        
        func shinVerticalAngleDeg3D(knee: SIMD3<Double>, ankle: SIMD3<Double>) -> Double {
            // Calculate shin vector in 3D (knee to ankle)
            let shinVec = knee - ankle
            let shinLength = simd_length(shinVec)
            guard shinLength > 0 else { return 0 }
            
            // In 3D pose coordinates (MediaPipe/BlazePose typical convention):
            // X = left/right (lateral)
            // Y = up/down (vertical, positive = up typically)
            // Z = forward/backward (depth)
            //
            // For sagittal plane (side view), project to the plane containing
            // forward/backward motion and vertical
            
            // Use the horizontal component with largest magnitude as forward/backward
            let horizontalX = shinVec.x
            let horizontalZ = shinVec.z
            let horizontalComponent = abs(horizontalX) > abs(horizontalZ) ? horizontalX : horizontalZ
            let verticalY = shinVec.y
            
            // Create 2D vector in sagittal plane: (horizontal, vertical)
            // In sagittal plane, vertical points up (positive Y), so we use verticalY directly
            let sagittalVec = SIMD2<Double>(horizontalComponent, verticalY)
            let sagittalLength = simd_length(sagittalVec)
            guard sagittalLength > 0 else { return 0 }
            
            // Normalize the sagittal plane vector
            let normalized = sagittalVec / sagittalLength
            
            // Use vertical reference pointing UP (0, 1) in sagittal plane
            // (since Y is positive up in 3D coordinates)
            let verticalRef = SIMD2<Double>(0, 1)
            
            // Calculate dot product
            let dot = simd_dot(normalized, verticalRef)
            
            // Clamp dot product to [-1, 1] for acos
            let clampedDot = max(-1.0, min(1.0, dot))
            
            // Calculate angle from vertical using acos
            // 0° = perfectly vertical, increases for forward/backward lean
            let angleRad = acos(clampedDot)
            let angleDeg = angleRad * 180 / .pi
            
            // Return absolute value (magnitude of deviation from vertical)
            return abs(angleDeg)
        }
        
        func pelvisAxes(for frame: PoseFrame) -> (origin: SIMD3<Double>, xAxis: SIMD3<Double>, yAxis: SIMD3<Double>, zAxis: SIMD3<Double>)? {
            // For side view, we might only have one hip visible - use fallback
            if videoMode == .side {
                // Try to use visible hip, or fallback to single hip estimate
                if let visibleHip = point3D(frame, .rightHip) ?? point3D(frame, .leftHip) {
                    let origin = visibleHip
                    // For side view, x-axis is along the direction of movement (forward)
                    // Use shoulder-hip vector to estimate orientation
                    if let shoulder = point3D(frame, .rightShoulder) ?? point3D(frame, .leftShoulder) {
                        let shoulderHip = shoulder - visibleHip
                        let shLength = simd_length(shoulderHip)
                        guard shLength > 0 else { return nil }
                        var xAxis = SIMD3<Double>(1, 0, 0) // Default forward
                        if let knee = point3D(frame, .rightKnee) ?? point3D(frame, .leftKnee) {
                            let hipKnee = knee - visibleHip
                            let hkLength = simd_length(hipKnee)
                            if hkLength > 0 {
                                // Use hip-knee direction for x-axis (forward direction)
                                xAxis = hipKnee / hkLength
                            }
                        }
                        var yAxis = shoulderHip / shLength
                        let zAxis = simd_cross(xAxis, yAxis)
                        return (origin: origin, xAxis: xAxis, yAxis: yAxis, zAxis: zAxis)
                    }
                }
                return nil
            }
            
            // For angled view, use both hips
            guard let lh = point3D(frame, .leftHip),
                  let rh = point3D(frame, .rightHip) else { return nil }
            
            let origin = (lh + rh) / 2
            let hipVector = rh - lh
            let hipLength = simd_length(hipVector)
            guard hipLength > 0 else { return nil }
            var xAxis = hipVector / hipLength
            
            var yAxis: SIMD3<Double> = SIMD3<Double>(0, 1, 0)
            if let ls = point3D(frame, .leftShoulder),
               let rs = point3D(frame, .rightShoulder) {
                let shoulderMid = (ls + rs) / 2
                let yRaw = shoulderMid - origin
                let yLen = simd_length(yRaw)
                if yLen > 0 {
                    yAxis = yRaw / yLen
                }
            }
            
            var zAxis = simd_cross(xAxis, yAxis)
            let zLen = simd_length(zAxis)
            if zLen > 0 {
                zAxis = zAxis / zLen
            }
            yAxis = simd_normalize(simd_cross(zAxis, xAxis))
            xAxis = simd_normalize(xAxis)
            
            return (origin, xAxis, yAxis, zAxis)
        }
        
        func pelvisRelative(_ frame: PoseFrame, _ joint: PoseJoint, axes: (origin: SIMD3<Double>, xAxis: SIMD3<Double>, yAxis: SIMD3<Double>, zAxis: SIMD3<Double>)) -> SIMD3<Double>? {
            guard let p = point3D(frame, joint) else { return nil }
            let rel = p - axes.origin
            return SIMD3<Double>(
                simd_dot(rel, axes.xAxis),
                simd_dot(rel, axes.yAxis),
                simd_dot(rel, axes.zAxis)
            )
        }
        
        func percentile(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let idx = Int(Double(sorted.count - 1) * p)
            return sorted[max(0, min(sorted.count - 1, idx))]
        }
        
        // Body height estimate - optimized for side view
        var heightSamples: [Double] = []
        for frame in frames {
            if videoMode == .side {
                // For side view, use single-side measurements (more accurate)
                // Try visible side first
                if let shoulder = point(frame, .rightShoulder) ?? point(frame, .leftShoulder),
                   let ankle = point(frame, .rightAnkle) ?? point(frame, .leftAnkle) {
                    heightSamples.append(distance(shoulder, ankle))
                } else if let nose = point(frame, .nose),
                          let ankle = point(frame, .rightAnkle) ?? point(frame, .leftAnkle) {
                    heightSamples.append(distance(nose, ankle))
                }
            } else {
                // For angled view, use both sides
            if let ls = point(frame, .leftShoulder),
               let rs = point(frame, .rightShoulder),
               let la = point(frame, .leftAnkle),
               let ra = point(frame, .rightAnkle) {
                let shoulder = midPoint(ls, rs)
                let ankle = midPoint(la, ra)
                heightSamples.append(distance(shoulder, ankle))
            } else if let nose = point(frame, .nose),
                      let la = point(frame, .leftAnkle),
                      let ra = point(frame, .rightAnkle) {
                let ankle = midPoint(la, ra)
                heightSamples.append(distance(nose, ankle))
                }
            }
        }
        let bodyHeight = max(percentile(heightSamples, 0.5), 1.0)
        
        // MARK: - Foot-to-Hip Distance Signal (per methodology)
        // Compute horizontal distance d(t) = (x_foot(t) - x_hip(t)) * W for each leg
        // This is the core signal for heel strike/toe-off detection
        
        // Helper: Gap filling with linear interpolation (for short gaps only)
        func gapFillLinear(_ values: [Double], maxGap: Int = 5) -> [Double] {
            var filled = values
            var i = 0
            while i < filled.count {
                if filled[i].isNaN {
                    var gapStart = i
                    var gapEnd = i
                    while gapEnd < filled.count && filled[gapEnd].isNaN {
                        gapEnd += 1
                    }
                    let gapLength = gapEnd - gapStart
                    
                    if gapLength <= maxGap && gapStart > 0 && gapEnd < filled.count {
                        var beforeIdx = gapStart - 1
                        while beforeIdx >= 0 && filled[beforeIdx].isNaN {
                            beforeIdx -= 1
                        }
                        var afterIdx = gapEnd
                        while afterIdx < filled.count && filled[afterIdx].isNaN {
                            afterIdx += 1
                        }
                        
                        if beforeIdx >= 0 && afterIdx < filled.count {
                            let y0 = filled[beforeIdx]
                            let y1 = filled[afterIdx]
                            for j in gapStart..<gapEnd {
                                let t = Double(j - gapStart) / Double(gapLength + 1)
                                filled[j] = y0 + t * (y1 - y0)
                            }
                        }
                    }
                    i = gapEnd
                } else {
                    i += 1
                }
            }
            return filled
        }
        
        // Helper: Low-pass filter approximation (10th-order Butterworth equivalent)
        func butterworthLowPass(_ values: [Double], sampleRate: Double, cutoff: Double) -> [Double] {
            let nyquist = sampleRate / 2.0
            let actualCutoff = cutoff * nyquist
            let windowSize = max(1, Int(round(sampleRate / actualCutoff)))
            var filtered: [Double] = []
            
            for i in 0..<values.count {
                if values[i].isNaN {
                    filtered.append(.nan)
                } else {
                    var sum = 0.0
                    var count = 0
                    let start = max(0, i - windowSize / 2)
                    let end = min(values.count, i + windowSize / 2)
                    for j in start..<end {
                        if !values[j].isNaN {
                            sum += values[j]
                            count += 1
                        }
                    }
                    filtered.append(count > 0 ? sum / Double(count) : values[i])
                }
            }
            return filtered
        }
        
        // Extract foot index and hip x-coordinates
        // Note: Points from observation are normalized (0-1), but they're converted to pixels in processVideoFrames
        // So frame.points[joint] are already in pixel coordinates
        var leftFootX: [Double] = []
        var leftHipX: [Double] = []
        var rightFootX: [Double] = []
        var rightHipX: [Double] = []
        
        // Check if foot index is available (BlazePose has it, Vision doesn't)
        let hasFootIndex = frames.contains { point($0, .leftFootIndex) != nil || point($0, .rightFootIndex) != nil }
        
        for frame in frames {
            // Left leg: prefer FOOT_INDEX, fallback to ankle if not available
            let leftFootPoint: CGPoint?
            if hasFootIndex, let foot = point(frame, .leftFootIndex) {
                leftFootPoint = foot
            } else if let ankle = point(frame, .leftAnkle) {
                leftFootPoint = ankle
            } else {
                leftFootPoint = nil
            }
            
            if let foot = leftFootPoint, let hip = point(frame, .leftHip) {
                leftFootX.append(Double(foot.x))
                leftHipX.append(Double(hip.x))
            } else {
                leftFootX.append(.nan)
                leftHipX.append(.nan)
            }
            
            // Right leg: prefer FOOT_INDEX, fallback to ankle if not available
            let rightFootPoint: CGPoint?
            if hasFootIndex, let foot = point(frame, .rightFootIndex) {
                rightFootPoint = foot
            } else if let ankle = point(frame, .rightAnkle) {
                rightFootPoint = ankle
            } else {
                rightFootPoint = nil
            }
            
            if let foot = rightFootPoint, let hip = point(frame, .rightHip) {
                rightFootX.append(Double(foot.x))
                rightHipX.append(Double(hip.x))
            } else {
                rightFootX.append(.nan)
                rightHipX.append(.nan)
            }
        }
        
        // CRITICAL: Determine which side to use BEFORE processing
        // If user selected a side, ONLY process that side - ignore the other completely
        let useLeftSide: Bool
        let useRightSide: Bool
        if let selected = selectedSide {
            useLeftSide = (selected == .left)
            useRightSide = (selected == .right)
        } else {
            // Fallback to auto-detection if not specified
            useLeftSide = true
            useRightSide = true
        }
        
        // Compute d(t) = (x_foot(t) - x_hip(t)) in pixels
        // Points from processVideoFrames are already in pixel coordinates
        // But if they're normalized (0-1), we need to multiply by image width
        // Check coordinate system by looking at a sample point
        let imageWidth = Double(renderSize.width)
        let sampleHipX = frames.compactMap { point($0, .leftHip)?.x }.first ?? 0
        // If x coordinate is very small (< 10), it's likely normalized (0-1)
        // Otherwise it's already in pixels
        let isNormalized = sampleHipX > 0 && sampleHipX < 10.0
        
        var leftFootHipDistance: [Double] = []
        var rightFootHipDistance: [Double] = []
        
        // Determine majority facing direction so we can ensure heel-strike = positive peak.
        // When facing left, footX < hipX at heel strike → signed distance is negative.
        let rightCount = frames.filter { $0.facingRight }.count
        let runnerFacesRight = rightCount >= (frames.count - rightCount)
        let signFix: Double = runnerFacesRight ? 1.0 : -1.0
        
        for i in 0..<frames.count {
            if useLeftSide && !leftFootX[i].isNaN && !leftHipX[i].isNaN {
                let footX = leftFootX[i]
                let hipX = leftHipX[i]
                let raw = isNormalized
                    ? (footX - hipX) * imageWidth
                    : (footX - hipX)
                leftFootHipDistance.append(raw * signFix)
            } else {
                leftFootHipDistance.append(.nan)
            }
            
            if useRightSide && !rightFootX[i].isNaN && !rightHipX[i].isNaN {
                let footX = rightFootX[i]
                let hipX = rightHipX[i]
                let raw = isNormalized
                    ? (footX - hipX) * imageWidth
                    : (footX - hipX)
                rightFootHipDistance.append(raw * signFix)
            } else {
                rightFootHipDistance.append(.nan)
            }
        }
        
        // Apply preprocessing: gap filling then low-pass filter
        // ONLY process the selected side(s)
        let leftFilled = useLeftSide ? gapFillLinear(leftFootHipDistance, maxGap: 5) : Array(repeating: Double.nan, count: leftFootHipDistance.count)
        let rightFilled = useRightSide ? gapFillLinear(rightFootHipDistance, maxGap: 5) : Array(repeating: Double.nan, count: rightFootHipDistance.count)
        
        // Apply Butterworth filter (normalized cutoff 0.1752)
        let normalizedCutoff = 0.1752
        let leftFiltered = useLeftSide ? butterworthLowPass(leftFilled, sampleRate: frameRate, cutoff: normalizedCutoff) : []
        let rightFiltered = useRightSide ? butterworthLowPass(rightFilled, sampleRate: frameRate, cutoff: normalizedCutoff) : []
        
        // Detect peaks (heel strike) and troughs (toe-off)
        func detectPeaksAndTroughs(_ signal: [Double], minSpacing: Double, peakThreshold: Double, troughThreshold: Double) -> (peaks: [Int], troughs: [Int]) {
            var peaks: [Int] = []
            var troughs: [Int] = []
            
            let validValues = signal.filter { !$0.isNaN && $0.isFinite }
            guard !validValues.isEmpty else { return ([], []) }
            let minVal = validValues.min() ?? 0
            let maxVal = validValues.max() ?? 0
            let range = maxVal - minVal
            guard range > 0 else { return ([], []) }
            
            let normalized = signal.map { range > 0 ? ($0 - minVal) / range : 0.0 }
            let minSpacingFrames = Int(minSpacing * frameRate)
            
            for i in 1..<(signal.count - 1) {
                if signal[i].isNaN { continue }
                
                if signal[i] > signal[i-1] && signal[i] > signal[i+1] {
                    if normalized[i] >= peakThreshold {
                        if peaks.isEmpty || (i - peaks.last!) >= minSpacingFrames {
                            peaks.append(i)
                        }
                    }
                }
                
                if signal[i] < signal[i-1] && signal[i] < signal[i+1] {
                    if normalized[i] <= troughThreshold {
                        if troughs.isEmpty || (i - troughs.last!) >= minSpacingFrames {
                            troughs.append(i)
                        }
                    }
                }
            }
            
            return (peaks, troughs)
        }
        
        let minSpacing = 0.25
        let peakThreshold = 0.70
        let troughThreshold = 0.25
        
        // ONLY detect peaks for the selected side(s)
        let leftEvents = useLeftSide && !leftFiltered.isEmpty 
            ? detectPeaksAndTroughs(leftFiltered, minSpacing: minSpacing, peakThreshold: peakThreshold, troughThreshold: troughThreshold)
            : (peaks: [], troughs: [])
        let rightEvents = useRightSide && !rightFiltered.isEmpty
            ? detectPeaksAndTroughs(rightFiltered, minSpacing: minSpacing, peakThreshold: peakThreshold, troughThreshold: troughThreshold)
            : (peaks: [], troughs: [])
        
        // Results: leftEvents.peaks = heel strikes, leftEvents.troughs = toe-offs
        // These can be used for gait cycle detection
        
        // Collect selected side's heel strike frame indices for snapshot feature
        let selectedPeaks: [Int] = {
            if useLeftSide && !useRightSide {
                return leftEvents.peaks
            } else if useRightSide && !useLeftSide {
                return rightEvents.peaks
            } else {
                // Both sides active - combine and sort
                return (leftEvents.peaks + rightEvents.peaks).sorted()
            }
        }()
        
        // Pelvis-relative foot series (normalized by body height)
        func footPoint(_ frame: PoseFrame, isLeft: Bool) -> CGPoint? {
            if isLeft {
                return frame.points[.leftHeel] ?? frame.points[.leftAnkle]
            }
            return frame.points[.rightHeel] ?? frame.points[.rightAnkle]
        }
        
        func footPoint3D(_ frame: PoseFrame, isLeft: Bool) -> SIMD3<Double>? {
            if isLeft {
                return frame.points3D[.leftHeel] ?? frame.points3D[.leftAnkle]
            }
            return frame.points3D[.rightHeel] ?? frame.points3D[.rightAnkle]
        }
        
        var leftFootY: [Double] = []
        var rightFootY: [Double] = []
        var leftXRel: [Double] = []
        var rightXRel: [Double] = []
        
        for frame in frames {
            if let axes = pelvisAxes(for: frame) {
                if let lf = footPoint3D(frame, isLeft: true) {
                    let lfRel = lf - axes.origin
                    let yVal = simd_dot(lfRel, axes.yAxis)
                    let zVal = simd_dot(lfRel, axes.zAxis)
                    leftFootY.append(yVal / bodyHeight)
                    leftXRel.append(zVal / bodyHeight)
                } else {
                    leftFootY.append(.nan)
                    leftXRel.append(.nan)
                }
                if let rf = footPoint3D(frame, isLeft: false) {
                    let rfRel = rf - axes.origin
                    let yVal = simd_dot(rfRel, axes.yAxis)
                    let zVal = simd_dot(rfRel, axes.zAxis)
                    rightFootY.append(yVal / bodyHeight)
                    rightXRel.append(zVal / bodyHeight)
                } else {
                    rightFootY.append(.nan)
                    rightXRel.append(.nan)
                }
            } else if let lh = point(frame, .leftHip),
                      let rh = point(frame, .rightHip) {
                let pelvis = midPoint(lh, rh)
                if let lf = footPoint(frame, isLeft: true) {
                    leftFootY.append(Double(lf.y) / bodyHeight)
                    leftXRel.append(Double(lf.x - pelvis.x) / bodyHeight)
                } else {
                    leftFootY.append(.nan)
                    leftXRel.append(.nan)
                }
                if let rf = footPoint(frame, isLeft: false) {
                    rightFootY.append(Double(rf.y) / bodyHeight)
                    rightXRel.append(Double(rf.x - pelvis.x) / bodyHeight)
                } else {
                    rightFootY.append(.nan)
                    rightXRel.append(.nan)
                }
            } else if videoMode == .side,
                      let hip2d = point(frame, .rightHip) ?? point(frame, .leftHip) {
                // Side view with only one hip visible (far side is stripped).
                // Use the single available hip as the pelvis reference.
                if let lf = footPoint(frame, isLeft: true) {
                    leftFootY.append(Double(lf.y) / bodyHeight)
                    leftXRel.append(Double(lf.x - hip2d.x) / bodyHeight)
                } else {
                    leftFootY.append(.nan)
                    leftXRel.append(.nan)
                }
                if let rf = footPoint(frame, isLeft: false) {
                    rightFootY.append(Double(rf.y) / bodyHeight)
                    rightXRel.append(Double(rf.x - hip2d.x) / bodyHeight)
                } else {
                    rightFootY.append(.nan)
                    rightXRel.append(.nan)
                }
            } else {
                leftFootY.append(.nan)
                rightFootY.append(.nan)
                leftXRel.append(.nan)
                rightXRel.append(.nan)
            }
        }

        // In side view the 3D zAxis from pelvisAxes is unreliable: the hip→knee
        // vector is nearly collinear with the shoulder→hip (yAxis), so their cross
        // product is near-zero.  Override leftXRel/rightXRel with the 2D screen-X
        // foot-hip offset, which directly captures the running direction.
        if videoMode == .side {
            for i in 0..<frames.count {
                if i < leftFootX.count, i < leftHipX.count,
                   !leftFootX[i].isNaN, !leftHipX[i].isNaN, bodyHeight > 0 {
                    leftXRel[i] = (leftFootX[i] - leftHipX[i]) / bodyHeight
                }
                if i < rightFootX.count, i < rightHipX.count,
                   !rightFootX[i].isNaN, !rightHipX[i].isNaN, bodyHeight > 0 {
                    rightXRel[i] = (rightFootX[i] - rightHipX[i]) / bodyHeight
                }
            }
        }

        // In side view the 3D yVal (BlazePose world units) divided by a pixel bodyHeight
        // gives values of ~-0.001, while the 2D fallback path gives rf.y/bodyHeight ~ +0.67.
        // Mixing these two incompatible scales corrupts groundSign detection.
        // Override to always use consistent 2D screen Y in side view.
        if videoMode == .side {
            for i in 0..<frames.count {
                let frame = frames[i]
                if let lf = footPoint(frame, isLeft: true), bodyHeight > 0 {
                    leftFootY[i] = Double(lf.y) / bodyHeight
                } else {
                    leftFootY[i] = Double.nan
                }
                if let rf = footPoint(frame, isLeft: false), bodyHeight > 0 {
                    rightFootY[i] = Double(rf.y) / bodyHeight
                } else {
                    rightFootY[i] = Double.nan
                }
            }
        }
        
        func fillMissing(_ values: [Double]) -> [Double] {
            guard values.contains(where: { !$0.isNaN }) else {
                return Array(repeating: 0, count: values.count)
            }
            var filled = values
            var last: Double?
            for i in 0..<filled.count {
                if filled[i].isNaN {
                    if let last = last { filled[i] = last }
                } else {
                    last = filled[i]
                }
            }
            var next: Double?
            for i in stride(from: filled.count - 1, through: 0, by: -1) {
                if filled[i].isNaN {
                    if let next = next { filled[i] = next }
                } else {
                    next = filled[i]
                }
            }
            return filled.map { $0.isNaN ? 0 : $0 }
        }
        
        func derivative(_ values: [Double], times: [Double]) -> [Double] {
            var output = Array(repeating: Double.nan, count: values.count)
            for i in 1..<values.count {
                let v0 = values[i - 1]
                let v1 = values[i]
                guard !v0.isNaN, !v1.isNaN else { continue }
                let dt = max(times[i] - times[i - 1], 1.0 / frameRate)
                output[i] = (v1 - v0) / dt
            }
            return output
        }
        
        func absArray(_ values: [Double]) -> [Double] {
            values.map { abs($0) }
        }
        
        func robustStats(_ values: [Double]) -> (mean: Double, std: Double) {
            let cleaned = removeOutliers(values)
            let valid = cleaned.filter { !$0.isNaN && $0.isFinite }
            guard !valid.isEmpty else { return (0, 1) }
            let mean = valid.reduce(0, +) / Double(valid.count)
            let variance = valid.reduce(0) { $0 + pow($1 - mean, 2) } / Double(max(valid.count - 1, 1))
            return (mean, max(sqrt(variance), 1e-6))
        }
        
        func rangeBasedScore(value: Double, range: FormCueRange) -> Double {
            switch range.direction {
            case .lowerBetter:
                if value <= range.targetMax {
                    return 90
                }
                if value <= range.warnMax {
                    let t = (value - range.targetMax) / max(range.warnMax - range.targetMax, 1e-6)
                    return 90 - t * 30
                }
                let t = min((value - range.warnMax) / max(range.warnMax, 1e-6), 1.0)
                return 60 - t * 40
            case .higherBetter:
                if value >= range.targetMin {
                    return 90
                }
                if value >= range.warnMin {
                    let t = (range.targetMin - value) / max(range.targetMin - range.warnMin, 1e-6)
                    return 90 - t * 30
                }
                let t = min((range.warnMin - value) / max(range.warnMin, 1e-6), 1.0)
                return 60 - t * 40
            case .targetRange:
                if value >= range.targetMin && value <= range.targetMax {
                    return 90
                }
                if value >= range.warnMin && value <= range.warnMax {
                    let dist = min(abs(value - range.targetMin), abs(value - range.targetMax))
                    let span = max(range.warnMax - range.targetMax, range.targetMin - range.warnMin)
                    let t = min(dist / max(span, 1e-6), 1.0)
                    return 90 - t * 30
                }
                return 50
            }
        }
        
        let filledLeftXRel = fillMissing(leftXRel)
        let filledRightXRel = fillMissing(rightXRel)
        let filledLeftFootYForEvents = fillMissing(leftFootY)
        let filledRightFootYForEvents = fillMissing(rightFootY)
        
        let leftVRelRaw = derivative(filledLeftXRel, times: times)
        let rightVRelRaw = derivative(filledRightXRel, times: times)
        let leftYVelRaw = derivative(filledLeftFootYForEvents, times: times)
        let rightYVelRaw = derivative(filledRightFootYForEvents, times: times)
        
        // Smooth signals for more stable HS detection (lenient)
        let leftFootYSmooth = emaSmoothSeries(removeOutliers(filledLeftFootYForEvents), alpha: 0.2)
        let rightFootYSmooth = emaSmoothSeries(removeOutliers(filledRightFootYForEvents), alpha: 0.2)
        let leftVRel = emaSmoothSeries(removeOutliers(leftVRelRaw), alpha: 0.2)
        let rightVRel = emaSmoothSeries(removeOutliers(rightVRelRaw), alpha: 0.2)
        let leftYVel = emaSmoothSeries(removeOutliers(leftYVelRaw), alpha: 0.2)
        let rightYVel = emaSmoothSeries(removeOutliers(rightYVelRaw), alpha: 0.2)
        
        func detectHeelStrikes(ySeries: [Double], vRelSeries: [Double], yVelSeries: [Double]) -> [Int] {
            // The scan loop needs i in 4..<(count-4); anything shorter builds an
            // invalid Range and traps (seen with 6-7 pose frames from a sub-second clip).
            guard ySeries.count >= 9 else { return [] }
            let yValid = ySeries.filter { !$0.isNaN }
            guard yValid.count > 4 else { return [] }

            // Determine coordinate convention: 3D world-space has foot BELOW pelvis (negative Y),
            // 2D screen-space has foot near bottom of frame (positive, large Y).
            // Foot at ground contact is the extreme in whichever direction convention dictates.
            let yMedian = percentile(yValid, 0.5)
            // groundSign: -1 → ground = local minimum (3D world, Y-up), +1 → ground = local maximum (2D screen, Y-down)
            let groundSign: Double = yMedian < 0 ? -1.0 : 1.0

            // Threshold for "near ground" — 35th percentile in 3D (low = near ground),
            // 65th percentile in 2D (high = near ground).
            let yThreshPct = groundSign < 0 ? 0.35 : 0.65
            let yThresh = percentile(yValid, yThreshPct)

            let vAbs = vRelSeries.compactMap { $0.isNaN ? nil : abs($0) }
            let vScale = max(percentile(vAbs, 0.6), 0.03)
            let vGate = max(0.04, vScale * 0.5)
            let yVelAbs = yVelSeries.compactMap { $0.isNaN ? nil : abs($0) }
            let yVelGate = max(percentile(yVelAbs, 0.3), 0.02)

            let minGap = max(1, Int((frameRate * SprintTimingGates.heelStrikeMinGapSeconds).rounded()))
            var indices: [Int] = []
            var last = -minGap

            for i in 4..<(ySeries.count - 4) {
                guard !ySeries[i - 3].isNaN,
                      !ySeries[i - 2].isNaN,
                      !ySeries[i - 1].isNaN,
                      !ySeries[i].isNaN,
                      !ySeries[i + 1].isNaN,
                      !ySeries[i + 2].isNaN,
                      !ySeries[i + 3].isNaN,
                      !vRelSeries[i].isNaN,
                      !yVelSeries[i].isNaN else { continue }

                // Local extreme in the ground direction (min for 3D, max for 2D)
                let y = ySeries[i]
                let isLocalExtreme: Bool
                if groundSign < 0 {
                    isLocalExtreme = y <= ySeries[i - 1] && y <= ySeries[i + 1] &&
                                     y <= ySeries[i - 2] && y <= ySeries[i + 2] &&
                                     y <= ySeries[i - 3] && y <= ySeries[i + 3]
                } else {
                    isLocalExtreme = y >= ySeries[i - 1] && y >= ySeries[i + 1] &&
                                     y >= ySeries[i - 2] && y >= ySeries[i + 2] &&
                                     y >= ySeries[i - 3] && y >= ySeries[i + 3]
                }
                // "Near ground" check — direction-aware
                let atGround = groundSign < 0 ? (y <= yThresh) : (y >= yThresh)
                let nearZeroVel = abs(vRelSeries[i]) <= vGate
                let yVelFlat = abs(yVelSeries[i]) <= yVelGate

                // Velocity peak condition: recent peak then decline
                let prevV = vRelSeries[i - 1]
                let nextV = vRelSeries[i + 1]
                let passedPeak = abs(prevV) > abs(vRelSeries[i]) &&
                                 abs(nextV) < abs(prevV) &&
                                 abs(vRelSeries[i]) < abs(prevV) * 0.7

                let allCues = isLocalExtreme && atGround && (nearZeroVel || passedPeak || yVelFlat)

                if allCues {
                    if i - last >= minGap {
                        indices.append(i)
                        last = i
                    }
                }
            }

            // Post-process: filter out strikes that are too close together
            var filtered: [Int] = []
            for i in 0..<indices.count {
                if i == 0 || indices[i] - filtered.last! >= minGap {
                    filtered.append(indices[i])
                }
            }
            return filtered
        }
        
        struct CycleIndex {
            let start: Int
            let end: Int
            let toeOff: Int
        }
        
        func detectCycles(
            strikes: [Int],
            vRel: [Double],
            yVel: [Double],
            ySeries: [Double],
            times: [Double]
        ) -> [CycleIndex] {
            guard strikes.count > 1 else { return [] }
            let directionWindow = max(1, Int((frameRate * 0.12).rounded()))
            let minStride = SprintTimingGates.minStrideSeconds
            let maxStride = SprintTimingGates.maxStrideSeconds

            var cycles: [CycleIndex] = []
            for i in 0..<(strikes.count - 1) {
                let start = strikes[i]
                let end = strikes[i + 1]
                if start >= end { continue }
                let strideDuration = max(times[end] - times[start], 0)
                if strideDuration < minStride || strideDuration > maxStride { continue }

                var stanceSum = 0.0
                var stanceCount = 0
                let stanceEnd = min(end, start + directionWindow)
                if stanceEnd > start {
                    for j in (start + 1)...stanceEnd {
                        if !vRel[j].isNaN {
                            stanceSum += vRel[j]
                            stanceCount += 1
                        }
                    }
                }
                let stanceDir = stanceCount > 0 ? stanceSum / Double(stanceCount) : -0.1

                var toeOffIndex: Int?
                for j in (start + 1)..<end {
                    guard !vRel[j].isNaN else { continue }
                    if stanceDir < 0 {
                        if vRel[j] > 0 && (vRel[j - 1].isNaN || vRel[j - 1] <= 0) {
                            toeOffIndex = j
                            break
                        }
                    } else {
                        if vRel[j] < 0 && (vRel[j - 1].isNaN || vRel[j - 1] >= 0) {
                            toeOffIndex = j
                            break
                        }
                    }
                }

                if toeOffIndex == nil {
                    let fallbackFrame = start + max(1, Int(Double(end - start) * SprintTimingGates.toeOffFallbackDutyFactor))
                    toeOffIndex = min(fallbackFrame, end - 1)
                }

                if let toeOff = toeOffIndex {
                    let stanceDuration = max(times[toeOff] - times[start], 0)
                    if stanceDuration >= SprintTimingGates.detectMinSeconds
                        && stanceDuration <= SprintTimingGates.detectMaxSeconds {
                        cycles.append(CycleIndex(start: start, end: end, toeOff: toeOff))
                    }
                }
            }
            return cycles
        }
        
        // ONLY detect strikes and cycles for the selected side(s)
        // Anchor the gait cycle to INITIAL CONTACT via the foot-hip forward-reach
        // peaks (leftEvents.peaks): the foot is furthest ahead of the hip at
        // contact, a signal that is belt-invariant so it works on a treadmill
        // (unlike the old detectHeelStrikes, which latched onto the foot's lowest
        // screen-Y = mid/late stance, shifting every joint curve ~40% early and
        // over-counting cadence). These carry a 0.25s min-spacing so they also
        // stop the intra-stride double counting. detectHeelStrikes is retained
        // only for reference; it is no longer the cycle/cadence source.
        let leftStrikes = useLeftSide ? leftEvents.peaks : []
        let rightStrikes = useRightSide ? rightEvents.peaks : []
        let leftCycles = useLeftSide ? detectCycles(strikes: leftStrikes, vRel: leftVRel, yVel: leftYVel, ySeries: leftFootYSmooth, times: times) : []
        let rightCycles = useRightSide ? detectCycles(strikes: rightStrikes, vRel: rightVRel, yVel: rightYVel, ySeries: rightFootYSmooth, times: times) : []
        
        func frontSideIsRight() -> Bool {
            // If user selected a side, use that instead of auto-detection
            if let selected = selectedSide {
                return selected == .right
            }
            let rightFrames = frames.filter { $0.facingRight }
            return rightFrames.count >= (frames.count - rightFrames.count)
        }
        
        let frontIsRight = frontSideIsRight()
        
        // Calculate cadence: steps per minute
        // ALWAYS use cycles for cadence calculation - it's the most reliable method
        // Each cycle represents one full stride (left or right), so 2 cycles = 2 steps
        var cadence: Double = 0
        let totalCycles = leftCycles.count + rightCycles.count
        
        if totalCycles > 0 && duration > 0 {
            // Cadence from cycles (most reliable)
            let cyclesPerMinute = (Double(totalCycles) / duration) * 60
            // A cycle is one full stride of ONE foot (same-foot strike to strike),
            // which spans two steps. When only one leg is tracked (the normal
            // side-view case) we double to recover both feet. When BOTH legs are
            // tracked (any front/treadmill mode) the two strides already cover all
            // steps, so doubling would report 2× the true cadence — guard against it.
            let sidesTracked = (useLeftSide ? 1 : 0) + (useRightSide ? 1 : 0)
            let cycleMultiplier: Double = sidesTracked >= 2 ? 1.0 : 2.0
            let rawCadence = cyclesPerMinute * cycleMultiplier
            
            // Additional validation: if cadence seems too high, check if we have too many cycles
            // For a typical 10-second video at 180 spm, we'd expect ~30 cycles total (15 per foot)
            // If we have way more than that, something is wrong
            let expectedMaxCycles = duration * 3.0  // Max 3 cycles per second = 180 spm
            if Double(totalCycles) > expectedMaxCycles {
                // Too many cycles detected - use a more conservative estimate
                // Cap at reasonable maximum
                cadence = min(rawCadence, 250.0)  // Cap at 250 spm as safety
            } else {
                cadence = rawCadence
            }
        } else {
            // If no cycles detected, estimate from filtered strikes with very conservative approach
            // Filter strikes to only those that form reasonable stride pairs
            func filterStrikesForCadence(_ strikes: [Int], times: [Double]) -> [Int] {
                guard strikes.count > 1 else { return strikes }
                var filtered: [Int] = [strikes[0]]
                let minStrideTime = 0.3  // Minimum 0.3s between strikes (max 200 spm per foot)
                
                for i in 1..<strikes.count {
                    let timeSinceLast = times[strikes[i]] - times[filtered.last!]
                    if timeSinceLast >= minStrideTime {
                        filtered.append(strikes[i])
                    }
                }
                return filtered
            }
            
            let filteredLeft = filterStrikesForCadence(leftStrikes, times: times)
            let filteredRight = filterStrikesForCadence(rightStrikes, times: times)
            let stepCount = filteredLeft.count + filteredRight.count
            cadence = duration > 0 ? (Double(stepCount) / duration) * 60 : 0
        }
        
        cadence = max(80, min(320, cadence))
        
        func strideLengths(from strikes: [Int], xSeries: [Double]) -> [Double] {
            guard strikes.count > 1 else { return [] }
            var lengths: [Double] = []
            for i in 1..<strikes.count {
                let prev = xSeries[strikes[i - 1]]
                let curr = xSeries[strikes[i]]
                if !prev.isNaN, !curr.isNaN {
                    lengths.append(abs(curr - prev))
                }
            }
            return lengths
        }
        
        let leftStride = strideLengths(from: leftStrikes, xSeries: leftXRel)
        let rightStride = strideLengths(from: rightStrikes, xSeries: rightXRel)
        let leftStrideSum = leftStride.reduce(0, +)
        let rightStrideSum = rightStride.reduce(0, +)
        let totalStrideCount = leftStride.count + rightStride.count
        let avgStride = (leftStrideSum + rightStrideSum) / Double(max(totalStrideCount, 1))
        let strideLength = avgStride
        
        // Contact time from VERTICAL foot motion within each stride. The cycle is
        // anchored to the foot-hip forward-reach PEAK (the foot's most-forward
        // instant), which is right for phase alignment but precedes touchdown for
        // a runner who lands under the body — so measuring stance from it inflates
        // contact, worst for elites. Vertical motion is belt-invariant: the foot
        // sits in a low band while planted and rises at toe-off. We take the first
        // contiguous in-band run as stance, sub-frame interpolate both crossings to
        // beat 30 fps quantization, and reject values outside a running-plausible
        // window (120-350 ms) rather than display a wrong number.
        func verticalContactMs(_ c: CycleIndex, footY: [Double], bandFraction: Double = 0.36) -> Double? {
            let lo = c.start
            let hi = min(c.end, footY.count - 1)
            guard hi > lo + 2 else { return nil }
            let win = (lo...hi).compactMap { footY[$0].isNaN ? nil : footY[$0] }
            guard win.count > 3, let minY = win.min(), let maxY = win.max(),
                  maxY - minY > 1e-6 else { return nil }
            let band = minY + (maxY - minY) * bandFraction   // "planted" zone just above the stride low
            var strike: Int? = nil
            var idx = lo
            while idx <= hi {
                if !footY[idx].isNaN && footY[idx] <= band { strike = idx; break }
                idx += 1
            }
            guard let s = strike else { return nil }
            var toe = s
            var j = s
            while j <= hi {
                if !footY[j].isNaN && footY[j] > band { break }
                if !footY[j].isNaN { toe = j }
                j += 1
            }
            guard toe > s else { return nil }
            // Linear sub-frame interpolation of the band crossing between k-1 and k.
            func crossTime(_ k: Int) -> Double {
                let a = k - 1
                guard a >= lo, !footY[a].isNaN, !footY[k].isNaN, footY[k] != footY[a] else { return times[k] }
                let f = min(max((band - footY[a]) / (footY[k] - footY[a]), 0), 1)
                return times[a] + (times[k] - times[a]) * f
            }
            let tStrike = crossTime(s)
            let tToe = (toe + 1 <= hi) ? crossTime(toe + 1) : times[toe]
            let ms = (tToe - tStrike) * 1000
            // Plausible running stance: ~120 ms (elite/fast) up to ~400 ms (slow,
            // heavy recreational). Above that is walking, not running, and below is
            // a detection glitch — either way reject rather than show a wrong value.
            return (ms >= 120 && ms <= 400) ? ms : nil
        }
        func groundContactTimes(from cycles: [CycleIndex], footY: [Double]) -> [Double] {
            cycles.compactMap { verticalContactMs($0, footY: footY) }
        }

        // Band fraction 0.36 was calibrated on an elite treadmill clip (cadence
        // 182): a sweep gave band 0.20->155ms, 0.30->202, 0.40->245, 0.50->288,
        // so 0.36 lands ~228ms (duty ~0.35), squarely in the trained-distance
        // range — versus the old forward-reach method's inflated 321ms.
        let gctLeft = groundContactTimes(from: leftCycles, footY: leftFootYSmooth)
        let gctRight = groundContactTimes(from: rightCycles, footY: rightFootYSmooth)
        let avgGctLeft = gctLeft.isEmpty ? 0 : gctLeft.reduce(0, +) / Double(gctLeft.count)
        let avgGctRight = gctRight.isEmpty ? 0 : gctRight.reduce(0, +) / Double(gctRight.count)
        
        func groundContactSeries(_ ySeries: [Double]) -> [Double] {
            let valid = ySeries.filter { !$0.isNaN }
            guard !valid.isEmpty else { return Array(repeating: Double.nan, count: ySeries.count) }
            // For side view, foot Y is normalized by bodyHeight. Lower Y = foot closer to ground
            // Use a threshold that captures when foot is near the ground (low Y values)
            // For normalized Y, values near 0 or negative mean foot is on/near ground
            let threshold = percentile(valid, videoMode == .side ? 0.3 : 0.4)  // Lower percentile = lower Y values
            var raw = Array(repeating: Double.nan, count: ySeries.count)
            var contactStart: Int?
            
            for i in 0..<ySeries.count {
                if !ySeries[i].isNaN {
                    // Foot is in contact when Y is at or below threshold (foot is low/on ground)
                    let isInContact = ySeries[i] <= threshold
                    if isInContact {
                        if contactStart == nil {
                            contactStart = i
                        }
                        // Calculate contact duration from start of contact
                        if let start = contactStart {
                            let contactFrames = i - start + 1
                            raw[i] = Double(contactFrames) / frameRate * 1000  // Convert to milliseconds
                        }
                } else {
                        contactStart = nil
                        raw[i] = 0  // Not in contact
                    }
                }
            }
            // Apply EMA smoothing to prevent sharp jumps
            return emaSmoothSeries(raw, alpha: 0.15)
        }
        
        // EMA smoother with delta clamping. NaN samples stay NaN in the output
        // (a gap is a gap) but must not poison the running state — before this,
        // one missing foot sample turned the whole rest of the series NaN.
        func emaSmoothSeries(_ values: [Double], alpha: Double) -> [Double] {
            guard values.count > 1 else { return values }
            var smoothed = Array(repeating: Double.nan, count: values.count)
            var state = Double.nan
            for i in 0..<values.count {
                let raw = values[i]
                if raw.isNaN { continue }
                if state.isNaN {
                    smoothed[i] = raw
                    state = raw
                    continue
                }
                // EMA: new = alpha * current + (1 - alpha) * previous
                var newVal = alpha * raw + (1 - alpha) * state
                // Clamp delta to prevent extreme jumps (max 10 units per frame)
                let maxDelta = 10.0
                let delta = newVal - state
                if abs(delta) > maxDelta {
                    newVal = state + (delta > 0 ? maxDelta : -maxDelta)
                }
                smoothed[i] = newVal
                state = newVal
            }
            return smoothed
        }
        
        let frameCount = frames.count
        var hipY: [Double] = []
        var hipDropSeries: [Double] = []
        var kneeAngles: [Double] = []
        var trunkAngles: [Double] = []
        var selectedTorsoAngles: [Double] = []
        var selectedHeadAnglesRaw: [Double] = []  // Raw angles before baseline correction
        var selectedHeadAngles: [Double] = []  // Baseline-corrected angles
        var perFrameTorso = Array(repeating: Double.nan, count: frameCount)
        var perFrameGazeRaw = Array(repeating: Double.nan, count: frameCount)
        var perFrameElbow = Array(repeating: Double.nan, count: frameCount)
        var headOffsets: [Double] = []
        var hipDiffs: [Double] = []
        var kneeValgusVals: [Double] = []
        var leftKneeFlex: [Double] = []
        var rightKneeFlex: [Double] = []
        var leftHipFlex: [Double] = []
        var rightHipFlex: [Double] = []
        var leftAnkleFlex: [Double] = []
        var rightAnkleFlex: [Double] = []
        var leftElbowFlex: [Double] = []
        var rightElbowFlex: [Double] = []
        var leftWristX: [Double] = []
        var rightWristX: [Double] = []
        
        // Additional movement tracking for graphs - initialize to frame count
        var hipMovementY = Array(repeating: Double.nan, count: frameCount)  // Closest hip Y position
        var headBobbingY = Array(repeating: Double.nan, count: frameCount)  // Nose Y position
        var armMovementX = Array(repeating: Double.nan, count: frameCount)  // Wrist X position (combined)
        
        var leftKneeFlexSeries = Array(repeating: Double.nan, count: frameCount)
        var rightKneeFlexSeries = Array(repeating: Double.nan, count: frameCount)
        var leftHipFlexSeries = Array(repeating: Double.nan, count: frameCount)
        var rightHipFlexSeries = Array(repeating: Double.nan, count: frameCount)
        var leftAnkleFlexSeries = Array(repeating: Double.nan, count: frameCount)
        var rightAnkleFlexSeries = Array(repeating: Double.nan, count: frameCount)
        
        for (index, frame) in frames.enumerated() {
            let axes = pelvisAxes(for: frame)
            
            // Calculate hip movement for EVERY frame
            if let lh = point(frame, .leftHip),
               let rh = point(frame, .rightHip) {
                let hipMid = midPoint(lh, rh)
                hipY.append(Double(hipMid.y))
                hipDiffs.append(abs(Double(lh.y - rh.y)))
                
                // For side view, use closest hip; for angled, use midpoint
                if videoMode == .side {
                    // Use the hip that's closer to camera (lower Y = closer in side view typically)
                    let closestHipY = min(Double(lh.y), Double(rh.y))
                    hipMovementY[index] = closestHipY
                } else {
                    hipMovementY[index] = Double(hipMid.y)
                }
            } else if let hip = point(frame, .leftHip) ?? point(frame, .rightHip) {
                // Fallback: single hip (the common side-view case — the far hip is
                // occluded, so both-hips almost never both resolve in 2D). Vertical
                // bounce is the same for either hip, so feed the near hip's Y into
                // hipY so vertical oscillation is still measured. Without this,
                // hipY stayed empty on every side-view clip → VO=0 → the Impact
                // dial had no bounce input and read a constant ~88 for everyone.
                // (hipDiffs / pelvic drop needs both hips, so it is skipped here.)
                hipY.append(Double(hip.y))
                hipMovementY[index] = Double(hip.y)
            }
            // else: already NaN
            
            // Calculate head bobbing for EVERY frame
            if let nose = point(frame, .nose) {
                headBobbingY[index] = Double(nose.y)
            }
            // else: already NaN
            
            // Calculate selected-side torso angle for every frame.
            // Angle is computed from shoulder->hip segment relative to vertical.
            let selectedTorsoAngle: Double? = {
                func angleFromVertical(shoulder: CGPoint, hip: CGPoint) -> Double {
                    let vec = CGPoint(x: shoulder.x - hip.x, y: shoulder.y - hip.y)
                    return abs(atan2(Double(vec.x), Double(-vec.y)) * 180 / .pi)
                }
                
                if useLeftSide && !useRightSide,
                   let shoulder = point(frame, .leftShoulder),
                   let hip = point(frame, .leftHip) {
                    return angleFromVertical(shoulder: shoulder, hip: hip)
                }
                
                if useRightSide && !useLeftSide,
                   let shoulder = point(frame, .rightShoulder),
                   let hip = point(frame, .rightHip) {
                    return angleFromVertical(shoulder: shoulder, hip: hip)
                }
                
                // Fallback when both sides are active: use the side facing camera for this frame.
                let preferRight = frame.facingRight
                if preferRight,
                   let shoulder = point(frame, .rightShoulder),
                   let hip = point(frame, .rightHip) {
                    return angleFromVertical(shoulder: shoulder, hip: hip)
                }
                if let shoulder = point(frame, .leftShoulder),
                   let hip = point(frame, .leftHip) {
                    return angleFromVertical(shoulder: shoulder, hip: hip)
                }
                return nil
            }()
            if let angle = selectedTorsoAngle, angle.isFinite, !angle.isNaN {
                selectedTorsoAngles.append(angle)
                perFrameTorso[index] = angle
            }
            
            // Calculate gaze angle for every frame.
            // Measures ear-to-nose angle from horizontal: 0° = looking ahead, positive = looking down.
            // ONLY uses ear landmarks — neck/shoulder fallbacks give wrong results (they're below the nose).
            let selectedHeadAngle: Double? = {
                func gazeAngleFromHorizontal(ear: CGPoint, nose: CGPoint) -> Double {
                    // In screen coords Y increases downward
                    // For gaze direction, we want to measure how much the nose is tilted down from the ear's level
                    // This is the vertical component of the head tilt, not the full vector angle
                    
                    let dx = Double(nose.x - ear.x)  // Horizontal distance (nose forward = positive)
                    let dy = Double(nose.y - ear.y)   // Vertical offset (nose below ear = positive, looking down)
                    
                    // Only measure vertical tilt if there's meaningful horizontal separation
                    // If dx is very small, the head might be rotated, so use a minimum threshold
                    let minHorizontalSep = 0.01  // Minimum 1% of frame width for valid measurement

                    guard abs(dx) > minHorizontalSep else {
                        // Can't measure — the nose has swung into the ear's column.
                        // This happens MOST when the chin is tucked (severe head
                        // down), so the old `return 0` scored the worst head-down
                        // clips as perfect gaze. Unmeasurable must stay unmeasured;
                        // the caller drops NaN frames.
                        return Double.nan
                    }

                    // Calculate the angle of vertical tilt: atan2(vertical_offset, horizontal_distance)
                    // This gives us the downward tilt angle
                    let angle = atan2(dy, abs(dx)) * 180 / .pi

                    // Positive = looking down (the fault we score). Looking up is
                    // not the head-down fault — clamp to neutral instead of folding
                    // it into "down" via abs().
                    return angle.isFinite ? max(0.0, angle) : Double.nan
                }
                
                // Primary: use selected-side ear with nose
                if useLeftSide && !useRightSide,
                   let ear = point(frame, .leftEar),
                   let nose = point(frame, .nose) {
                    return gazeAngleFromHorizontal(ear: ear, nose: nose)
                }
                if useRightSide && !useLeftSide,
                   let ear = point(frame, .rightEar),
                   let nose = point(frame, .nose) {
                    return gazeAngleFromHorizontal(ear: ear, nose: nose)
                }
                // Fallback when both sides active: prefer the camera-facing side
                let preferRight = frame.facingRight
                if preferRight,
                   let ear = point(frame, .rightEar),
                   let nose = point(frame, .nose) {
                    return gazeAngleFromHorizontal(ear: ear, nose: nose)
                }
                if let ear = point(frame, .leftEar),
                   let nose = point(frame, .nose) {
                    return gazeAngleFromHorizontal(ear: ear, nose: nose)
                }
                // No ear data available — cannot reliably compute gaze angle
                return nil
            }()
            if let angle = selectedHeadAngle, angle.isFinite, !angle.isNaN {
                selectedHeadAnglesRaw.append(angle)
                perFrameGazeRaw[index] = angle
            }
            
            // Calculate other metrics if both hips available
            if let lh = point(frame, .leftHip),
               let rh = point(frame, .rightHip) {
                let hipMid = midPoint(lh, rh)
                
                if let ls = point(frame, .leftShoulder),
                   let rs = point(frame, .rightShoulder) {
                    let shoulderMid = midPoint(ls, rs)
                    let vec = CGPoint(x: shoulderMid.x - hipMid.x, y: shoulderMid.y - hipMid.y)
                    let angle = abs(atan2(Double(vec.x), Double(-vec.y)) * 180 / .pi)
                    trunkAngles.append(angle)
                }
                
                if let nose = point(frame, .nose) {
                    let dx = Double(nose.x - hipMid.x)
                    let dy = Double(nose.y - hipMid.y)
                    headOffsets.append(hypot(dx, dy))
                }
            }
            
            if let axes = axes,
               let lHip3 = pelvisRelative(frame, .leftHip, axes: axes),
               let lKnee3 = pelvisRelative(frame, .leftKnee, axes: axes),
               let lAnkle3 = pelvisRelative(frame, .leftAnkle, axes: axes) {
                let kneeAngle = angleDegrees3D(lHip3, lKnee3, lAnkle3)
                kneeAngles.append(kneeAngle)
                leftKneeFlex.append(180 - kneeAngle)
                leftKneeFlexSeries[index] = 180 - kneeAngle
                
                if let lShoulder3 = pelvisRelative(frame, .leftShoulder, axes: axes) {
                    let hipAngle = 180 - angleDegrees3D(lShoulder3, lHip3, lKnee3)
                    leftHipFlex.append(hipAngle)
                    leftHipFlexSeries[index] = hipAngle
                }
                
                if let lFoot3 = pelvisRelative(frame, .leftFootIndex, axes: axes) ?? pelvisRelative(frame, .leftHeel, axes: axes) {
                    // Neutral-referenced dorsiflexion (0 = foot square to shank,
                    // + dorsiflex, - plantarflex) so it matches the reference axis
                    // (-40..35). Was 180-interior (~90 at neutral), which pinned
                    // the ankle curve to the top of the chart. ROM is unchanged.
                    let ankleAngle = 90 - angleDegrees3D(lKnee3, lAnkle3, lFoot3)
                    leftAnkleFlex.append(ankleAngle)
                    leftAnkleFlexSeries[index] = ankleAngle
                }
            } else if let lHip = point(frame, .leftHip),
                      let lKnee = point(frame, .leftKnee),
                      let lAnkle = point(frame, .leftAnkle) {
                let kneeAngle = angleDegrees(lHip, lKnee, lAnkle)
                kneeAngles.append(kneeAngle)
                leftKneeFlex.append(180 - kneeAngle)
                leftKneeFlexSeries[index] = 180 - kneeAngle
                
                if let lShoulder = point(frame, .leftShoulder) {
                    let hipAngle = 180 - angleDegrees(lShoulder, lHip, lKnee)
                    leftHipFlex.append(hipAngle)
                    leftHipFlexSeries[index] = hipAngle
                }
                
                if let lFoot = point(frame, .leftFootIndex) ?? point(frame, .leftHeel) {
                    let ankleAngle = 90 - angleDegrees(lKnee, lAnkle, lFoot)
                    leftAnkleFlex.append(ankleAngle)
                    leftAnkleFlexSeries[index] = ankleAngle
                }
            }
            
            if let axes = axes,
               let rHip3 = pelvisRelative(frame, .rightHip, axes: axes),
               let rKnee3 = pelvisRelative(frame, .rightKnee, axes: axes),
               let rAnkle3 = pelvisRelative(frame, .rightAnkle, axes: axes) {
                let kneeAngle = angleDegrees3D(rHip3, rKnee3, rAnkle3)
                kneeAngles.append(kneeAngle)
                rightKneeFlex.append(180 - kneeAngle)
                rightKneeFlexSeries[index] = 180 - kneeAngle
                
                if let rShoulder3 = pelvisRelative(frame, .rightShoulder, axes: axes) {
                    let hipAngle = 180 - angleDegrees3D(rShoulder3, rHip3, rKnee3)
                    rightHipFlex.append(hipAngle)
                    rightHipFlexSeries[index] = hipAngle
                }
                
                if let rFoot3 = pelvisRelative(frame, .rightFootIndex, axes: axes) ?? pelvisRelative(frame, .rightHeel, axes: axes) {
                    let ankleAngle = 90 - angleDegrees3D(rKnee3, rAnkle3, rFoot3)
                    rightAnkleFlex.append(ankleAngle)
                    rightAnkleFlexSeries[index] = ankleAngle
                }
            } else if let rHip = point(frame, .rightHip),
                      let rKnee = point(frame, .rightKnee),
                      let rAnkle = point(frame, .rightAnkle) {
                let kneeAngle = angleDegrees(rHip, rKnee, rAnkle)
                kneeAngles.append(kneeAngle)
                rightKneeFlex.append(180 - kneeAngle)
                rightKneeFlexSeries[index] = 180 - kneeAngle
                
                if let rShoulder = point(frame, .rightShoulder) {
                    let hipAngle = 180 - angleDegrees(rShoulder, rHip, rKnee)
                    rightHipFlex.append(hipAngle)
                    rightHipFlexSeries[index] = hipAngle
                }
                
                if let rFoot = point(frame, .rightFootIndex) ?? point(frame, .rightHeel) {
                    let ankleAngle = 90 - angleDegrees(rKnee, rAnkle, rFoot)
                    rightAnkleFlex.append(ankleAngle)
                    rightAnkleFlexSeries[index] = ankleAngle
                }
            }
            
            if let lShoulder = point(frame, .leftShoulder),
               let lElbow = point(frame, .leftElbow),
               let lWrist = point(frame, .leftWrist) {
                leftElbowFlex.append(180 - angleDegrees(lShoulder, lElbow, lWrist))
                leftWristX.append(Double(lWrist.x))
            } else {
                leftWristX.append(Double.nan)
            }
            
            if let rShoulder = point(frame, .rightShoulder),
               let rElbow = point(frame, .rightElbow),
               let rWrist = point(frame, .rightWrist) {
                rightElbowFlex.append(180 - angleDegrees(rShoulder, rElbow, rWrist))
                rightWristX.append(Double(rWrist.x))
            } else {
                rightWristX.append(Double.nan)
            }
            
            // Per-frame elbow interior angle for snapshot (selected side)
            if useLeftSide && !useRightSide {
                if let s = point(frame, .leftShoulder), let e = point(frame, .leftElbow), let w = point(frame, .leftWrist) {
                    perFrameElbow[index] = angleDegrees(s, e, w)
                }
            } else if useRightSide && !useLeftSide {
                if let s = point(frame, .rightShoulder), let e = point(frame, .rightElbow), let w = point(frame, .rightWrist) {
                    perFrameElbow[index] = angleDegrees(s, e, w)
                }
            } else {
                let preferRight = frame.facingRight
                if preferRight, let s = point(frame, .rightShoulder), let e = point(frame, .rightElbow), let w = point(frame, .rightWrist) {
                    perFrameElbow[index] = angleDegrees(s, e, w)
                } else if let s = point(frame, .leftShoulder), let e = point(frame, .leftElbow), let w = point(frame, .leftWrist) {
                    perFrameElbow[index] = angleDegrees(s, e, w)
                }
            }
            
            // Combine wrist X positions for arm movement (use visible side or average)
            if videoMode == .side {
                // For side view, use the visible side's wrist
                if let visibleWrist = point(frame, .rightWrist) ?? point(frame, .leftWrist) {
                    armMovementX[index] = Double(visibleWrist.x)
                }
                // else: already NaN
            } else {
                // For angled view, use average of both wrists
                if let lWrist = point(frame, .leftWrist), let rWrist = point(frame, .rightWrist) {
                    armMovementX[index] = (Double(lWrist.x) + Double(rWrist.x)) / 2.0
                } else if let wrist = point(frame, .leftWrist) ?? point(frame, .rightWrist) {
                    armMovementX[index] = Double(wrist.x)
                }
                // else: already NaN
            }
            
            
            if let lh = point(frame, .leftHip),
               let rh = point(frame, .rightHip) {
                let hipDiff = abs(Double(lh.y - rh.y))
                hipDropSeries.append(hipDiff / bodyHeight * 100)
            }
            
            if let lh = point(frame, .leftHip),
               let lk = point(frame, .leftKnee),
               let la = point(frame, .leftAnkle) {
                kneeValgusVals.append(180 - angleDegrees(lh, lk, la))
            }
            if let rh = point(frame, .rightHip),
               let rk = point(frame, .rightKnee),
               let ra = point(frame, .rightAnkle) {
                kneeValgusVals.append(180 - angleDegrees(rh, rk, ra))
            }
        }
        
        // Calculate baseline gaze angle from first portion of video (assumed to be "looking forward")
        // Use first 20% of frames or first 2 seconds, whichever gives more samples
        let baselineFrames = max(10, min(frameCount / 5, Int(frameRate * 2.0)))
        let headAngleBaseline: Double = {
            guard baselineFrames > 0, selectedHeadAnglesRaw.count >= baselineFrames else {
                // Not enough data for baseline - use median of all raw angles as fallback
                let valid = selectedHeadAnglesRaw.filter { !$0.isNaN && $0.isFinite && $0 >= 0 && $0 <= 45.0 }
                guard valid.count >= 3 else { return 0.0 }  // No baseline if too few samples
                let sorted = valid.sorted()
                return sorted[sorted.count / 2]  // Median of all angles
            }
            // Use first N frames for baseline
            let baselineSamples = Array(selectedHeadAnglesRaw.prefix(baselineFrames))
                .filter { !$0.isNaN && $0.isFinite && $0 >= 0 && $0 <= 45.0 }
            guard baselineSamples.count >= 3 else { return 0.0 }
            // Use median of baseline samples for robustness
            let sorted = baselineSamples.sorted()
            return sorted[sorted.count / 2]
        }()
        
        // Apply baseline correction to all head angles
        selectedHeadAngles = selectedHeadAnglesRaw.map { rawAngle in
            guard rawAngle.isFinite, !rawAngle.isNaN else { return rawAngle }
            let corrected = rawAngle - headAngleBaseline
            // Clamp to reasonable range after correction
            return max(0.0, min(45.0, abs(corrected)))
        }
        
        debugLog("[GAZE BASELINE] Baseline: \(String(format: "%.1f°", headAngleBaseline)) | Raw angles: \(selectedHeadAnglesRaw.count) | Corrected angles: \(selectedHeadAngles.count)")
        
        // Apply same baseline correction to per-frame gaze array
        let perFrameGaze: [Double] = perFrameGazeRaw.map { raw in
            guard !raw.isNaN, raw.isFinite else { return Double.nan }
            let corrected = raw - headAngleBaseline
            return max(0.0, min(45.0, abs(corrected)))
        }
        
        // Vertical oscillation = STRIDE BOUNCE, not total vertical travel. Taking
        // the raw p10–p90 of hip-Y conflates the bounce with slow drift (the runner
        // creeping up/down the frame over the clip), which inflated it to ~24% of
        // body height (an impossible ~40 cm). Detrend first — subtract a ~0.5 s
        // moving average — so only the genuine per-stride bounce remains.
        let detrendWindow = max(5, Int((frameRate * 0.5).rounded()))
        let verticalOscillation: Double = {
            guard !hipY.isEmpty else { return 0 }
            let detrended = detrendMovingMean(hipY, window: detrendWindow)
            return (percentile(detrended, 0.9) - percentile(detrended, 0.1)) / bodyHeight * 100
        }()
        debugLog("[VO] hipY.count=\(hipY.count) window=\(detrendWindow) -> VO=\(String(format: "%.2f", verticalOscillation))%")
        let trunkLean = trunkAngles.isEmpty ? 0 : trunkAngles.reduce(0, +) / Double(trunkAngles.count)
        // Honesty gate: a joint's mean must reflect a meaningful slice of the
        // analysis window, not a handful of stray frames, or it reads "--".
        // ~1/12 of the clean window (min 6 frames) ≈ enough to trust the median.
        let minAngleSamples = max(6, frameCount / 12)
        let torsoAngleMean: Double = {
            let valid = selectedTorsoAngles
                .filter { !$0.isNaN && $0.isFinite && $0 <= 45.0 }
            guard valid.count >= minAngleSamples else { return -1.0 }
            let sorted = valid.sorted()
            if sorted.count % 2 == 0 {
                return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
            }
            return sorted[sorted.count / 2]
        }()
        let headAngleMean: Double = {
            let valid = selectedHeadAngles
                .filter { !$0.isNaN && $0.isFinite && $0 >= 0 && $0 <= 45.0 }
            guard valid.count >= minAngleSamples else { return -1.0 }
            let sorted = valid.sorted()
            if sorted.count % 2 == 0 {
                return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
            }
            return sorted[sorted.count / 2]
        }()
        let torsoAngleValidForStd = selectedTorsoAngles.filter { !$0.isNaN && $0.isFinite && $0 <= 45.0 }
        let torsoAngleStd = torsoAngleValidForStd.count >= 2 ? max(robustStats(torsoAngleValidForStd).std, 0.1) : 1.0
        let gazeAnglesValid = selectedHeadAngles.filter { !$0.isNaN && $0.isFinite && $0 >= 0 && $0 <= 45.0 }
        let headAngleStd = gazeAnglesValid.count >= 2 ? max(robustStats(gazeAnglesValid).std, 0.1) : 1.0
        debugLog("[GAZE DEBUG] selectedHeadAngles count: \(selectedHeadAngles.count) / \(frameCount) frames | headAngleMean: \(headAngleMean)")
        
        // Compute selected-side elbow interior angles (same series as dial / Efficiency breakdown)
        // leftElbowFlex / rightElbowFlex store 180 - angleDegrees(...), so interior = 180 - flex
        let validInteriorElbowAngles: [Double] = {
            let selectedElbowAngles: [Double]
            if useLeftSide && !useRightSide {
                selectedElbowAngles = leftElbowFlex.map { 180.0 - $0 }
            } else if useRightSide && !useLeftSide {
                selectedElbowAngles = rightElbowFlex.map { 180.0 - $0 }
            } else {
                let combined = zip(frames, zip(leftElbowFlex, rightElbowFlex)).compactMap { frame, vals -> Double? in
                    let useRight = frame.facingRight
                    let flex = useRight ? vals.1 : vals.0
                    return 180.0 - flex
                }
                selectedElbowAngles = combined
            }
            return selectedElbowAngles.filter { !$0.isNaN && $0.isFinite && $0 > 0 && $0 < 180.0 }
        }()
        let elbowAngleMean: Double = {
            guard validInteriorElbowAngles.count >= minAngleSamples else { return -1.0 }
            let sorted = validInteriorElbowAngles.sorted()
            if sorted.count % 2 == 0 {
                return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
            }
            return sorted[sorted.count / 2]
        }()
        let elbowAngleStd = validInteriorElbowAngles.isEmpty ? 10.0 : max(robustStats(validInteriorElbowAngles).std, 0.5)

        // Selected-side interior knee + hip angles. Stored arrays hold flexion
        // (180 - interior), same convention as elbow, so interior = 180 - flex.
        func selectedInteriorAngleMean(left: [Double], right: [Double]) -> Double {
            let selected: [Double]
            if useLeftSide && !useRightSide {
                selected = left.map { 180.0 - $0 }
            } else if useRightSide && !useLeftSide {
                selected = right.map { 180.0 - $0 }
            } else {
                selected = zip(frames, zip(left, right)).map { frame, vals in
                    180.0 - (frame.facingRight ? vals.1 : vals.0)
                }
            }
            let valid = selected.filter { !$0.isNaN && $0.isFinite && $0 > 0 && $0 < 180.0 }
            guard valid.count >= minAngleSamples else { return -1.0 }
            let sorted = valid.sorted()
            if sorted.count % 2 == 0 {
                return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
            }
            return sorted[sorted.count / 2]
        }
        let kneeAngleMean = selectedInteriorAngleMean(left: leftKneeFlex, right: rightKneeFlex)
        let hipAngleMean = selectedInteriorAngleMean(left: leftHipFlex, right: rightHipFlex)

        let headStability = headOffsets.isEmpty ? 0 : (headOffsets.reduce(0, +) / Double(headOffsets.count)) / bodyHeight * 100
        let hipDrop = hipDiffs.isEmpty ? 0 : (hipDiffs.reduce(0, +) / Double(hipDiffs.count)) / bodyHeight * 100
        let kneeValgus = kneeValgusVals.isEmpty ? 0 : kneeValgusVals.reduce(0, +) / Double(kneeValgusVals.count)
        
        // Robust range: the 5th–95th percentile spread, NOT raw max−min. A single
        // mistracked frame (a joint-angle spike from a jittery skeleton) otherwise
        // blows up the range — hip/ankle/knee/elbow ROMs reading 130–150° when the
        // real sagittal sweep is a fraction of that, which then saturates the drive
        // dial so noisy footage reads as elite power. Trimming the extreme tails
        // recovers the true physiologic range; a cleanly tracked clip is barely
        // affected (its tails are already tight), while spike-inflated footage is
        // brought back to reality.
        func range(_ values: [Double]) -> Double {
            let clean = values.filter { $0.isFinite }
            guard clean.count >= 5 else {
                guard let minVal = clean.min(), let maxVal = clean.max() else { return 0 }
                return maxVal - minVal
            }
            let sorted = clean.sorted()
            let loIdx = Int((Double(sorted.count - 1) * 0.05).rounded())
            let hiIdx = Int((Double(sorted.count - 1) * 0.95).rounded())
            return max(0, sorted[hiIdx] - sorted[loIdx])
        }
        
        let kneeFlexLeftRange = range(leftKneeFlex)
        let kneeFlexRightRange = range(rightKneeFlex)
        let hipExtLeftRange = range(leftHipFlex)
        let hipExtRightRange = range(rightHipFlex)
        let ankleLeftRange = range(leftAnkleFlex)
        let ankleRightRange = range(rightAnkleFlex)
        let elbowLeftRange = range(leftElbowFlex)
        let elbowRightRange = range(rightElbowFlex)

        // Camera-facing-side ROMs for the DRIVE model. On a side view the far
        // leg is part-occluded and its angle series carries identity-swap
        // jitter that inflates range() far past physiology (hip "sweeps" of
        // 130-150° on clean elite footage) — so max(left, right) always
        // preferred the corrupted side. Select per frame, the same convention
        // the interior-angle means use. Built from the frame-indexed *Series
        // arrays (NaN-gapped), which stay aligned when a joint drops out.
        func selectedRange(_ left: [Double], _ right: [Double]) -> Double {
            if useLeftSide && !useRightSide { return range(left) }
            if useRightSide && !useLeftSide { return range(right) }
            let picked = frames.indices.map { i -> Double in
                let l = i < left.count ? left[i] : Double.nan
                let r = i < right.count ? right[i] : Double.nan
                return frames[i].facingRight ? r : l
            }
            return range(picked)
        }
        let kneeFlexSelectedRange = selectedRange(leftKneeFlexSeries, rightKneeFlexSeries)
        let hipExtSelectedRange = selectedRange(leftHipFlexSeries, rightHipFlexSeries)
        let ankleSelectedRange = selectedRange(leftAnkleFlexSeries, rightAnkleFlexSeries)
        
        let leftWristRange = range(leftWristX)
        let rightWristRange = range(rightWristX)
        let armSwingSymmetry = (leftWristRange + rightWristRange) > 0
            ? 100 - (abs(leftWristRange - rightWristRange) / max((leftWristRange + rightWristRange) / 2, 1)) * 100
            : 0
        
        let strideSym: Double
        if leftStride.count > 0 && rightStride.count > 0 {
            let leftAvg = leftStride.reduce(0, +) / Double(leftStride.count)
            let rightAvg = rightStride.reduce(0, +) / Double(rightStride.count)
            let avgBoth = (leftAvg + rightAvg) / 2.0
            let diff = abs(leftAvg - rightAvg)
            strideSym = 100 - (diff / max(avgBoth, 1)) * 100
        } else {
            strideSym = 0
        }
        let gctSym = (avgGctLeft > 0 && avgGctRight > 0)
            ? 100 - (abs(avgGctLeft - avgGctRight) / max((avgGctLeft + avgGctRight) / 2, 1)) * 100
            : 0
        let symmetryScore = (strideSym + gctSym) > 0 ? (strideSym + gctSym) / 2 : max(strideSym, gctSym)
        
        // Foot strike pattern
        var heelCount = 0
        var foreCount = 0
        let strikeIndices = leftStrikes + rightStrikes
        for idx in strikeIndices {
            guard idx < frames.count else { continue }
            let frame = frames[idx]
            if let lh = point(frame, .leftHeel),
               let lf = point(frame, .leftFootIndex) {
                if lh.y > lf.y { heelCount += 1 } else { foreCount += 1 }
            }
            if let rh = point(frame, .rightHeel),
               let rf = point(frame, .rightFootIndex) {
                if rh.y > rf.y { heelCount += 1 } else { foreCount += 1 }
            }
        }
        let footStrikePattern: String
        if heelCount == 0 && foreCount == 0 {
            footStrikePattern = "Unknown"
        } else if Double(heelCount) > Double(foreCount) * 1.3 {
            footStrikePattern = "Heel Strike"
        } else if Double(foreCount) > Double(heelCount) * 1.3 {
            footStrikePattern = "Forefoot Strike"
        } else {
            footStrikePattern = "Mixed"
        }

        // MARK: Honesty layer — how much should this verdict be trusted?
        // Foot strike is classified from a single contact frame, so it is only
        // as good as (a) the frame rate, (b) how decisive the heel/forefoot
        // split was, and (c) how many strikes we actually measured.
        let footStrikeSamples = heelCount + foreCount
        let dominantShare = footStrikeSamples > 0
            ? Double(max(heelCount, foreCount)) / Double(footStrikeSamples)
            : 0.0                                   // 0.5 = coin-flip, 1.0 = unanimous
        let decisiveness = max(0.0, (dominantShare - 0.5) / 0.5)   // remap 0.5–1.0 → 0–1
        let fpsFactor = min(1.0, frameRate / 120.0)                // 30fps caps trust at 0.25
        let sampleFactor = min(1.0, Double(footStrikeSamples) / 8.0)
        let footStrikeConfidence = max(0.0, min(1.0, decisiveness * fpsFactor * sampleFactor))

        // Ground-contact time is measured between two frame-quantised events
        // (strike and toe-off), so each figure carries ~one frame of slack at
        // each end. sqrt(2)·frameInterval is the honest 1σ on that difference.
        let groundContactUncertaintyMs = frameRate > 0 ? (1000.0 / frameRate) * 2.0.squareRoot() : 0.0

        // Foot placement angle at contact (midfoot = near 0°)
        // Only measure the foot that is actually striking (the other foot is in swing and would give a bogus angle)
        // Positive angle → heel lower than toe → heel strike
        // Negative angle → toe lower than heel → forefoot strike
        // Near 0° → midfoot landing (ideal)
        var footPlacementAngles: [Double] = []
        
        func footAngleDeg(heel: CGPoint, toe: CGPoint) -> Double? {
            let dx = abs(toe.x - heel.x)
            let dy = heel.y - toe.y  // positive when heel is lower (heel strike in screen coords)
            guard dx > 1e-3 else { return nil }
            let angleDeg = atan2(dy, dx) * 180.0 / .pi
            return angleDeg.isFinite ? angleDeg : nil
        }
        
        // Left foot strikes — only measure left foot
        for idx in leftStrikes {
            guard idx < frames.count else { continue }
            let frame = frames[idx]
            if let lh = point(frame, .leftHeel),
               let lf = point(frame, .leftFootIndex),
               let angle = footAngleDeg(heel: lh, toe: lf) {
                footPlacementAngles.append(angle)
            }
        }
        // Right foot strikes — only measure right foot
        for idx in rightStrikes {
            guard idx < frames.count else { continue }
            let frame = frames[idx]
            if let rh = point(frame, .rightHeel),
               let rf = point(frame, .rightFootIndex),
               let angle = footAngleDeg(heel: rh, toe: rf) {
                footPlacementAngles.append(angle)
            }
        }
        
        // Signed shank inclination at initial contact (overstride metric).
        // + = shank tilts forward of vertical (ankle ahead of knee in the travel
        // direction → foot lands ahead of the body); − = vertical or leaning back.
        // Screen y increases downward, so the shank vector (knee→ankle) has vy > 0.
        func shankSignedDeg(knee: CGPoint, ankle: CGPoint, facingRight: Bool) -> Double? {
            let vy = Double(ankle.y - knee.y)
            guard vy > 1e-3 else { return nil }
            let forwardX = Double(ankle.x - knee.x) * (facingRight ? 1.0 : -1.0)
            let deg = atan2(forwardX, vy) * 180.0 / .pi
            return deg.isFinite ? deg : nil
        }
        // Strike detection rides a SMOOTHED foot-ahead-of-hip signal, so the
        // detected index can lag true touchdown by a few frames — and by early
        // stance the shank has already rotated to vertical, which read a clear
        // overstride as ~3° "good stride". Measure the MOST FORWARD shank in a
        // small window around each strike instead: that is the angle the foot
        // actually landed with.
        func windowedShank(_ idx: Int, knee: PoseJoint, ankle: PoseJoint) -> Double? {
            var best: Double?
            for j in max(0, idx - 3)...min(frames.count - 1, idx + 1) {
                let f = frames[j]
                if let k = point(f, knee), let a = point(f, ankle),
                   let d = shankSignedDeg(knee: k, ankle: a, facingRight: f.facingRight) {
                    if best == nil || d > best! { best = d }
                }
            }
            return best
        }
        // Real foot-under-COM measurement: how far ahead of the hip the ankle
        // lands (raw x units; normalized against stride length at scoring time —
        // EVERY runner lands ahead of the hip, and faster runners land further
        // ahead in absolute terms, so only the fraction of the stride is a fair
        // overstride measure). The old cue just COPIED the shin score.
        func underCOMOffset(_ idx: Int, hip: PoseJoint, ankle: PoseJoint) -> Double? {
            guard idx < frames.count else { return nil }
            var best: Double?
            for j in max(0, idx - 3)...min(frames.count - 1, idx + 1) {
                let f = frames[j]
                if let h = point(f, hip), let a = point(f, ankle) {
                    let fwd = Double(a.x - h.x) * (f.facingRight ? 1.0 : -1.0)
                    if best == nil || fwd > best! { best = fwd }
                }
            }
            return best.map { max(0, $0) }
        }

        // Heel contact during stance — the "heel never touches" red flag. A
        // rolling contact ("peeling") brings the heel down to toe level at some
        // point in stance; running purely on the toes never does. Measured per
        // strike over the stance window; nil when the joints weren't tracked.
        func heelTouches(_ idx: Int, heel: PoseJoint, toe: PoseJoint) -> Bool? {
            guard idx < frames.count else { return nil }
            // Stance window in TIME (~200 ms), not frames: 6 frames is a full
            // stance at 30fps but only ~25 ms at 240fps slo-mo — which read
            // every rolling midfoot landing as "heel never touches". The
            // max(6, …) floor keeps ≤30fps behavior (and its calibration)
            // identical.
            let stanceWindow = max(6, Int((frameRate * 0.2).rounded()))
            var measured = false
            for j in idx...min(frames.count - 1, idx + stanceWindow) {
                let f = frames[j]
                if let h = point(f, heel), let t = point(f, toe) {
                    measured = true
                    if Double(h.y) >= Double(t.y) - 0.005 { return true }   // y grows downward
                }
            }
            return measured ? false : nil
        }

        var shankSignedSamples: [Double] = []
        var underCOMSamples: [Double] = []
        var heelTouchSamples: [Bool] = []
        for idx in leftStrikes where idx < frames.count {
            if let d = windowedShank(idx, knee: .leftKnee, ankle: .leftAnkle) {
                shankSignedSamples.append(d)
            }
            if let o = underCOMOffset(idx, hip: .leftHip, ankle: .leftAnkle) {
                underCOMSamples.append(o)
            }
            if let t = heelTouches(idx, heel: .leftHeel, toe: .leftFootIndex) {
                heelTouchSamples.append(t)
            }
        }
        for idx in rightStrikes where idx < frames.count {
            if let d = windowedShank(idx, knee: .rightKnee, ankle: .rightAnkle) {
                shankSignedSamples.append(d)
            }
            if let o = underCOMOffset(idx, hip: .rightHip, ankle: .rightAnkle) {
                underCOMSamples.append(o)
            }
            if let t = heelTouches(idx, heel: .rightHeel, toe: .rightFootIndex) {
                heelTouchSamples.append(t)
            }
        }
        // Reject physiologically-impossible samples before taking the median: a
        // real shank at contact sits within ~±35° of vertical. Anything beyond
        // is a tracking artifact (occluded/mis-tracked leg) — averaging it in
        // produced the −52° "overstride" garbage. If too few sane samples
        // survive, the value is unmeasurable (NaN → shows "--"), not a fake.
        let plausibleShank = shankSignedSamples.filter { $0.isFinite && abs($0) <= 35 }
        let shankAngleAtContactSigned = plausibleShank.count >= 2
            ? (RunPhysics.median(plausibleShank) ?? Double.nan)
            : Double.nan

        // Persistent toes-only ratio across readable stances (NaN = unmeasurable).
        let noHeelRatio: Double = heelTouchSamples.count >= 3
            ? Double(heelTouchSamples.filter { !$0 }.count) / Double(heelTouchSamples.count)
            : Double.nan

        // Build per-frame series (dense like hip drop)
        let strideSeries: [Double] = leftStride + rightStride
        let gctLeftSeries = groundContactSeries(leftFootY)
        let gctRightSeries = groundContactSeries(rightFootY)
        // Use 2.5-second rolling window for smoother cadence
        let windowSeconds = 2.5
        let windowFrames = max(1, Int((frameRate * windowSeconds).rounded()))
        
        // Use cycle start indices for more reliable cadence calculation
        let cycleStarts = (leftCycles.map { $0.start } + rightCycles.map { $0.start }).sorted()
        
        var rawCadenceSeries = Array(repeating: 0.0, count: frames.count)
        var verticalSeries = Array(repeating: 0.0, count: frames.count)
        var kneeSeries = Array(repeating: 0.0, count: frames.count)
        
        // Build hipY series for windows
        var hipYSeries = Array(repeating: 0.0, count: frames.count)
        var lastHipY = hipYSeries.first ?? 0
        for (i, frame) in frames.enumerated() {
            if let lh = point(frame, .leftHip), let rh = point(frame, .rightHip) {
                let hipMid = midPoint(lh, rh)
                lastHipY = Double(hipMid.y)
            }
            hipYSeries[i] = lastHipY
        }
        
        var startPtr = 0
        var endPtr = 0
        for i in 0..<frames.count {
            let windowStart = max(0, i - windowFrames + 1)
            while startPtr < cycleStarts.count && cycleStarts[startPtr] < windowStart {
                startPtr += 1
            }
            while endPtr < cycleStarts.count && cycleStarts[endPtr] <= i {
                endPtr += 1
            }
            // Count cycles in window, then multiply by 2 (each cycle = 1 step, 2 cycles = 2 steps)
            let cycleCount = max(0, endPtr - startPtr)
            let windowDuration = max(Double(i - windowStart + 1) / frameRate, 0.001)
            if cycleCount > 0 {
                // Only calculate cadence if we have cycles
                var cadenceValue = (Double(cycleCount) / windowDuration) * 60 * 2  // Multiply by 2 for steps
                cadenceValue = max(80, min(400, cadenceValue))
                rawCadenceSeries[i] = cadenceValue
            } else {
                // No cycles detected - use NaN instead of defaulting to 80
                rawCadenceSeries[i] = Double.nan
            }
            
            let hipWindow = Array(hipYSeries[windowStart...i])
            let osc = (percentile(hipWindow, 0.9) - percentile(hipWindow, 0.1)) / bodyHeight * 100
            verticalSeries[i] = osc
            
            if let lh = point(frames[i], .leftHip),
               let lk = point(frames[i], .leftKnee),
               let la = point(frames[i], .leftAnkle) {
                kneeSeries[i] = 180 - angleDegrees(lh, lk, la)
            } else if let rh = point(frames[i], .rightHip),
                      let rk = point(frames[i], .rightKnee),
                      let ra = point(frames[i], .rightAnkle) {
                kneeSeries[i] = 180 - angleDegrees(rh, rk, ra)
            } else if i > 0 {
                kneeSeries[i] = kneeSeries[i - 1]
            }
        }
        
        // Apply EMA smoothing to cadence with delta clamping (max 5 spm per frame at 30fps)
        func emaSmoothCadence(_ values: [Double], alpha: Double, maxDelta: Double) -> [Double] {
            guard values.count > 1 else { return values }
            var smoothed = Array(repeating: Double.nan, count: values.count)
            smoothed[0] = values[0]
            for i in 1..<values.count {
                let raw = values[i]
                let prev = smoothed[i - 1]
                if raw.isNaN {
                    // If raw is NaN, keep previous value (or NaN if prev is also NaN)
                    smoothed[i] = prev.isNaN ? Double.nan : prev
                } else if prev.isNaN {
                    // If previous is NaN but current is valid, use current value
                    smoothed[i] = raw
                } else {
                    // Both valid, apply EMA smoothing
                var newVal = alpha * raw + (1 - alpha) * prev
                let delta = newVal - prev
                if abs(delta) > maxDelta {
                    newVal = prev + (delta > 0 ? maxDelta : -maxDelta)
                }
                smoothed[i] = newVal
                }
            }
            return smoothed
        }
        
        // Max change of 5 spm per frame (at 30fps that's ~150 spm/second max change rate)
        let cadenceSeries = emaSmoothCadence(rawCadenceSeries, alpha: 0.1, maxDelta: 5.0)
        
        let bins = 101
        let filledLeftKnee = fillMissing(leftKneeFlexSeries)
        let filledRightKnee = fillMissing(rightKneeFlexSeries)
        let filledLeftHip = fillMissing(leftHipFlexSeries)
        let filledRightHip = fillMissing(rightHipFlexSeries)
        let filledLeftAnkle = fillMissing(leftAnkleFlexSeries)
        let filledRightAnkle = fillMissing(rightAnkleFlexSeries)
        let filledLeftFootY = fillMissing(leftFootY)
        let filledRightFootY = fillMissing(rightFootY)
        let filledLeftVRel = fillMissing(leftVRel)
        let filledRightVRel = fillMissing(rightVRel)
        
        func resampleCycle(values: [Double], cycles: [CycleIndex], bins: Int) -> [[Double]] {
            guard !cycles.isEmpty else { return [] }
            var output: [[Double]] = []
            for cycle in cycles {
                let start = cycle.start
                let end = cycle.end
                guard end > start, end < values.count else { continue }
                var series = Array(repeating: 0.0, count: bins)
                let span = Double(end - start)
                for b in 0..<bins {
                    let t = Double(b) / Double(bins - 1)
                    let idx = Double(start) + t * span
                    let low = Int(floor(idx))
                    let high = min(low + 1, values.count - 1)
                    let frac = idx - Double(low)
                    let v0 = values[low]
                    let v1 = values[high]
                    series[b] = v0 + (v1 - v0) * frac
                }
                output.append(series)
            }
            return output
        }
        
        func averageCycles(_ cycles: [[Double]], bins: Int) -> [Double] {
            guard !cycles.isEmpty else { return [] }
            var avg = Array(repeating: 0.0, count: bins)
            for cycle in cycles {
                for i in 0..<min(bins, cycle.count) {
                    avg[i] += cycle[i]
                }
            }
            return avg.map { $0 / Double(cycles.count) }
        }
        
        func stdCycles(_ cycles: [[Double]], mean: [Double], bins: Int) -> [Double] {
            guard !cycles.isEmpty, !mean.isEmpty else { return [] }
            var variance = Array(repeating: 0.0, count: bins)
            for cycle in cycles {
                for i in 0..<min(bins, cycle.count) {
                    let diff = cycle[i] - mean[i]
                    variance[i] += diff * diff
                }
            }
            let denom = Double(max(cycles.count - 1, 1))
            return variance.map { sqrt($0 / denom) }
        }
        
        func stancePercent(from cycles: [CycleIndex]) -> Double {
            guard !cycles.isEmpty else { return 0 }
            let values = cycles.map { cycle -> Double in
                let span = Double(cycle.end - cycle.start)
                guard span > 0 else { return 0 }
                return (Double(cycle.toeOff - cycle.start) / span) * 100
            }
            return values.reduce(0, +) / Double(values.count)
        }
        
        let leftKneeCycles = resampleCycle(values: filledLeftKnee, cycles: leftCycles, bins: bins)
        let rightKneeCycles = resampleCycle(values: filledRightKnee, cycles: rightCycles, bins: bins)
        let leftHipCycles = resampleCycle(values: filledLeftHip, cycles: leftCycles, bins: bins)
        let rightHipCycles = resampleCycle(values: filledRightHip, cycles: rightCycles, bins: bins)
        let leftAnkleCycles = resampleCycle(values: filledLeftAnkle, cycles: leftCycles, bins: bins)
        let rightAnkleCycles = resampleCycle(values: filledRightAnkle, cycles: rightCycles, bins: bins)
        let leftFootYCycles = resampleCycle(values: filledLeftFootY, cycles: leftCycles, bins: bins)
        let rightFootYCycles = resampleCycle(values: filledRightFootY, cycles: rightCycles, bins: bins)
        let leftFootVelCycles = resampleCycle(values: filledLeftVRel, cycles: leftCycles, bins: bins)
        let rightFootVelCycles = resampleCycle(values: filledRightVRel, cycles: rightCycles, bins: bins)
        
        let leftCyclesIntervals = leftCycles.map {
            GaitCycleInterval(startTime: times[$0.start], endTime: times[$0.end], toeOffTime: times[$0.toeOff],
                              contactMs: verticalContactMs($0, footY: leftFootYSmooth) ?? .nan)
        }
        let rightCyclesIntervals = rightCycles.map {
            GaitCycleInterval(startTime: times[$0.start], endTime: times[$0.end], toeOffTime: times[$0.toeOff],
                              contactMs: verticalContactMs($0, footY: rightFootYSmooth) ?? .nan)
        }
        
        let leftKneeAvg = averageCycles(leftKneeCycles, bins: bins)
        let rightKneeAvg = averageCycles(rightKneeCycles, bins: bins)
        let leftHipAvg = averageCycles(leftHipCycles, bins: bins)
        let rightHipAvg = averageCycles(rightHipCycles, bins: bins)
        let leftAnkleAvg = averageCycles(leftAnkleCycles, bins: bins)
        let rightAnkleAvg = averageCycles(rightAnkleCycles, bins: bins)
        let leftFootYAvg = averageCycles(leftFootYCycles, bins: bins)
        let rightFootYAvg = averageCycles(rightFootYCycles, bins: bins)
        let leftFootVelAvg = averageCycles(leftFootVelCycles, bins: bins)
        let rightFootVelAvg = averageCycles(rightFootVelCycles, bins: bins)
        
        let gaitSeries = GaitCycleSeries(
            bins: bins,
            leftKneeAngle: leftKneeAvg,
            rightKneeAngle: rightKneeAvg,
            leftKneeAngleStd: stdCycles(leftKneeCycles, mean: leftKneeAvg, bins: bins),
            rightKneeAngleStd: stdCycles(rightKneeCycles, mean: rightKneeAvg, bins: bins),
            leftKneeCycles: leftKneeCycles,
            rightKneeCycles: rightKneeCycles,
            leftHipAngle: leftHipAvg,
            rightHipAngle: rightHipAvg,
            leftHipAngleStd: stdCycles(leftHipCycles, mean: leftHipAvg, bins: bins),
            rightHipAngleStd: stdCycles(rightHipCycles, mean: rightHipAvg, bins: bins),
            leftHipCycles: leftHipCycles,
            rightHipCycles: rightHipCycles,
            leftAnkleAngle: leftAnkleAvg,
            rightAnkleAngle: rightAnkleAvg,
            leftAnkleAngleStd: stdCycles(leftAnkleCycles, mean: leftAnkleAvg, bins: bins),
            rightAnkleAngleStd: stdCycles(rightAnkleCycles, mean: rightAnkleAvg, bins: bins),
            leftAnkleCycles: leftAnkleCycles,
            rightAnkleCycles: rightAnkleCycles,
            leftFootY: leftFootYAvg,
            rightFootY: rightFootYAvg,
            leftFootYStd: stdCycles(leftFootYCycles, mean: leftFootYAvg, bins: bins),
            rightFootYStd: stdCycles(rightFootYCycles, mean: rightFootYAvg, bins: bins),
            leftFootYCycles: leftFootYCycles,
            rightFootYCycles: rightFootYCycles,
            leftFootVelocity: leftFootVelAvg,
            rightFootVelocity: rightFootVelAvg,
            leftFootVelocityStd: stdCycles(leftFootVelCycles, mean: leftFootVelAvg, bins: bins),
            rightFootVelocityStd: stdCycles(rightFootVelCycles, mean: rightFootVelAvg, bins: bins),
            leftFootVelocityCycles: leftFootVelCycles,
            rightFootVelocityCycles: rightFootVelCycles,
            leftStancePercent: stancePercent(from: leftCycles),
            rightStancePercent: stancePercent(from: rightCycles),
            leftCycles: leftCyclesIntervals,
            rightCycles: rightCyclesIntervals
        )
        
        let metrics = AnalysisMetrics(
            cadence: cadence,
            strideLength: strideLength,
            groundContactLeft: avgGctLeft,
            groundContactRight: avgGctRight,
            verticalOscillation: verticalOscillation,
            symmetryScore: symmetryScore,
            trunkLean: trunkLean,
            headStability: headStability,
            hipDrop: hipDrop,
            kneeValgus: kneeValgus,
            kneeFlexionRangeLeft: kneeFlexLeftRange,
            kneeFlexionRangeRight: kneeFlexRightRange,
            hipExtensionRangeLeft: hipExtLeftRange,
            hipExtensionRangeRight: hipExtRightRange,
            ankleDorsiRangeLeft: ankleLeftRange,
            ankleDorsiRangeRight: ankleRightRange,
            elbowRangeLeft: elbowLeftRange,
            elbowRangeRight: elbowRightRange,
            footStrikePattern: footStrikePattern,
            armSwingSymmetry: armSwingSymmetry,
            footStrikeConfidence: footStrikeConfidence,
            groundContactUncertaintyMs: groundContactUncertaintyMs,
            captureFrameRate: frameRate,
            kneeFlexionRangeSelected: kneeFlexSelectedRange,
            hipExtensionRangeSelected: hipExtSelectedRange,
            ankleDorsiRangeSelected: ankleSelectedRange
        )
        
        // Apply outlier removal to time series data
        let cleanedLeftKnee = removeOutliers(filledLeftKnee)
        let cleanedRightKnee = removeOutliers(filledRightKnee)
        let cleanedLeftHip = removeOutliers(filledLeftHip)
        let cleanedRightHip = removeOutliers(filledRightHip)
        let cleanedLeftAnkle = removeOutliers(filledLeftAnkle)
        let cleanedRightAnkle = removeOutliers(filledRightAnkle)
        let cleanedLeftFootY = removeOutliers(filledLeftFootY)
        let cleanedRightFootY = removeOutliers(filledRightFootY)
        let cleanedLeftFootVel = removeOutliers(filledLeftVRel)
        let cleanedRightFootVel = removeOutliers(filledRightVRel)
        let cleanedGctLeft = removeOutliers(gctLeftSeries)
        let cleanedGctRight = removeOutliers(gctRightSeries)
        let cleanedHipDrop = removeOutliers(hipDropSeries)
        let cleanedVertical = removeOutliers(verticalSeries)
        let cleanedCadence = removeOutliers(cadenceSeries)
        
        // Clean and prepare new movement graphs
        // Foot velocity X: combine left and right (use visible side or average)
        // Note: cleanedLeftFootVel and cleanedRightFootVel are derivatives of normalized X positions
        // They are in "body heights per second". To convert to m/s, multiply by bodyHeight in meters
        // bodyHeight is in pixels, estimate meters assuming typical person height of 1.7m
        // If bodyHeight is ~500-1000 pixels for a 1.7m person, then 1 pixel ≈ 0.0017-0.0034m
        // Use a reasonable estimate: if bodyHeight pixels represents 1.7m, then scale factor is 1.7 / bodyHeight
        // But actually, since X is normalized by bodyHeight, velocity is already in "body heights per second"
        // So we just need to multiply by 1.7m (typical body height) to get m/s
        let typicalBodyHeightMeters = 1.7
        let footVelXSeries: [Double]
        if videoMode == .side {
            // For side view, use visible side
            footVelXSeries = zip(cleanedLeftFootVel, cleanedRightFootVel).map { (l: Double, r: Double) -> Double in
                let vel = !r.isNaN ? r : (!l.isNaN ? l : Double.nan)
                // Convert from "body heights per second" to m/s
                return vel.isNaN ? Double.nan : vel * typicalBodyHeightMeters
            }
        } else {
            // For angled view, average both sides
            footVelXSeries = zip(cleanedLeftFootVel, cleanedRightFootVel).map { (l: Double, r: Double) -> Double in
                let vel: Double
                if !l.isNaN && !r.isNaN {
                    vel = (l + r) / 2.0
                } else if !l.isNaN {
                    vel = l
                } else if !r.isNaN {
                    vel = r
                } else {
                    return Double.nan
                }
                // Convert from "body heights per second" to m/s
                return vel * typicalBodyHeightMeters
            }
        }
        let cleanedFootVelX = removeOutliers(footVelXSeries)
        
        // Fill missing values for hip movement and head bobbing
        func fillMissingValues(_ values: [Double]) -> [Double] {
            guard !values.isEmpty else { return values }
            var filled = values
            var lastValid = values.first { !$0.isNaN }
            for i in filled.indices {
                if filled[i].isNaN, let last = lastValid {
                    filled[i] = last
                } else if !filled[i].isNaN {
                    lastValid = filled[i]
                }
            }
            return filled
        }
        
        let filledHipMovementY = fillMissingValues(hipMovementY)
        let filledHeadBobbingY = fillMissingValues(headBobbingY)
        let filledArmMovementX = fillMissingValues(armMovementX)
        
        let cleanedHipMovementY = removeOutliers(filledHipMovementY)
        let cleanedHeadBobbingY = removeOutliers(filledHeadBobbingY)
        let cleanedArmMovementX = removeOutliers(filledArmMovementX)
        
        // Normalize values to show variation (center around mean for better visualization)
        func normalizeToMean(_ values: [Double]) -> [Double] {
            let validValues = values.filter { !$0.isNaN }
            guard !validValues.isEmpty else { return values }
            let mean = validValues.reduce(0, +) / Double(validValues.count)
            return values.map { $0.isNaN ? Double.nan : $0 - mean }
        }
        
        // Normalize hip and head movement to show relative change from mean
        let normalizedHipMovementY = normalizeToMean(cleanedHipMovementY)
        let normalizedHeadBobbingY = normalizeToMean(cleanedHeadBobbingY)
        let normalizedArmMovementX = normalizeToMean(cleanedArmMovementX)
        
        func symmetryIndex(left: [Double], right: [Double]) -> [Double] {
            let count = min(left.count, right.count)
            guard count > 0 else { return [] }
            return (0..<count).map { i in
                let l = left[i]
                let r = right[i]
                let denom = (l + r) / 2
                guard denom != 0, !l.isNaN, !r.isNaN else { return 0 }
                return ((l - r) / denom) * 100
            }
        }
        
        let leftKneeVel = derivative(cleanedLeftKnee, times: times)
        let rightKneeVel = derivative(cleanedRightKnee, times: times)
        let leftHipVel = derivative(cleanedLeftHip, times: times)
        let rightHipVel = derivative(cleanedRightHip, times: times)
        let kneeSymmetry = symmetryIndex(left: cleanedLeftKnee, right: cleanedRightKnee)
        let gctSymmetry = symmetryIndex(left: cleanedGctLeft, right: cleanedGctRight)

        // Form cue metrics (robust + forgiving)
        func frontSideByDepth(_ frame: PoseFrame) -> Bool {
            // If user selected a side, use that instead of depth-based detection
            if let selected = selectedSide {
                return selected == .right
            }
            guard let lk = frame.points3D[.leftKnee], let rk = frame.points3D[.rightKnee] else {
                return frontIsRight
            }
            return rk.z < lk.z
        }
        
        // Calculate shin vertical angle at initial contact (heel strike).
        // Strategy: Measure at PEAKS in foot-to-hip distance, which occur at heel strike
        // when the foot is farthest ahead of the hip. This is when the shin has maximum
        // forward lean, which is what matters for overstriding assessment.
        // (Mid-stance measurements would give unrealistically low angles ~1-2°)
        
        var shinAnglesAtContact: [Double] = []
        
        // Helper: find maximum shin angle in a small window around a peak
        // This captures the peak forward lean at initial contact
        func findMaxShinAngleAroundPeak(peakIdx: Int, windowFrames: Int, isLeft: Bool) -> Double? {
            let kneeJoint: PoseJoint  = isLeft ? .leftKnee  : .rightKnee
            let ankleJoint: PoseJoint = isLeft ? .leftAnkle : .rightAnkle
            
            var maxAngle: Double = -1.0
            var foundAny = false
            
            // Search a small window around the peak (±windowFrames frames)
            let startIdx = max(0, peakIdx - windowFrames)
            let endIdx = min(frames.count - 1, peakIdx + windowFrames)
            
            for idx in startIdx...endIdx {
                guard idx >= 0, idx < frames.count else { continue }
                let frame = frames[idx]
                
                // Prefer 2D calculation (more reliable for side-view videos)
                if let knee = point(frame, kneeJoint),
                   let ankle = point(frame, ankleJoint) {
                    let angle = abs(shinVerticalAngleDeg(knee: knee, ankle: ankle))
                    if angle > maxAngle {
                        maxAngle = angle
                        foundAny = true
                    }
                }
                // Fallback to 3D if 2D not available
                else if let knee3D = point3D(frame, kneeJoint),
                        let ankle3D = point3D(frame, ankleJoint) {
                    let angle = abs(shinVerticalAngleDeg3D(knee: knee3D, ankle: ankle3D))
                    if angle > maxAngle {
                        maxAngle = angle
                        foundAny = true
                    }
                }
            }
            
            return foundAny && maxAngle >= 0 ? maxAngle : nil
        }
        
        // Process each side: measure at peaks (heel strike)
        func processSide(peaks: [Int], isLeft: Bool) {
            // Search ±3 frames around each peak to find maximum forward lean
            let windowFrames = 3
            
            for peakIdx in peaks {
                if let maxAngle = findMaxShinAngleAroundPeak(peakIdx: peakIdx, windowFrames: windowFrames, isLeft: isLeft) {
                    shinAnglesAtContact.append(maxAngle)
                }
            }
        }
        
        // Only process the selected side
        if useLeftSide {
            processSide(peaks: leftEvents.peaks, isLeft: true)
        }
        if useRightSide {
            processSide(peaks: rightEvents.peaks, isLeft: false)
        }
        
        // Filter out extreme outliers and invalid angles
        // Shin angles > 25° are physically unreasonable (severe overstriding is ~15-20°)
        // Also filter out NaN/infinite values
        // At heel strike, realistic angles are 5-15° for average runners
        let validAngles = shinAnglesAtContact
            .filter { !$0.isNaN && $0.isFinite }
            .filter { $0 <= 25.0 }  // Cap at 25° - anything higher is likely measurement error
        
        // Track perpendicularity: count how many contacts have shin angle within ±2° of 0° (perpendicular)
        // Perpendicular (0°) is actually too vertical - optimal is 8-12° forward lean
        let perpendicularThreshold = 2.0  // ±2° from 0° counts as perpendicular
        let perpendicularCount = validAngles.filter { abs($0) <= perpendicularThreshold }.count
        let totalContacts = validAngles.count
        let perpendicularityPercentage = totalContacts > 0 
            ? (Double(perpendicularCount) / Double(totalContacts)) * 100.0 
            : 0.0
        
        // Use median for more robustness against outliers, then compute mean/std from filtered set
        let finalShinMean: Double
        let finalShinStd: Double
        if !validAngles.isEmpty {
            // Use median as primary measure (more robust)
            let sorted = validAngles.sorted()
            let median = sorted.count % 2 == 0
                ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
                : sorted[sorted.count / 2]

            // Also compute mean/std for reporting, but use median as the primary value
            let stats = robustStats(validAngles)
            finalShinMean = median  // Use median for final value
            finalShinStd  = stats.1
        } else {
            finalShinMean = -1.0
            finalShinStd  = 0.0
        }

        // Score .shinVertical (and .footUnderCOM below) from the VALIDATED signed
        // shank angle at contact — the single source of truth also behind SHIN /
        // OVERSTRIDE and the dashboard/Coach. The old UNSIGNED classifier scored a
        // near-vertical shin as "understride" (its good band centred at 9.5°), so an
        // elite who lands under the body read ~50, and the foot-COM distance range
        // (0–0.06) was likewise miscalibrated to ~20. Both now read the real value.
        let shinScore = Double(classifyShinStrideSigned(
            angle: shankAngleAtContactSigned.isFinite ? shankAngleAtContactSigned : nil).score)
        
        // Store final values for FormCueScore
        let shinMeanForScore = finalShinMean
        let shinStdForScore = finalShinStd
        
        // Store perpendicularity + evidence-count data in std field for AnalyzeView.
        // Format: std = actualStd*1_000_000 + perpendicularityPercentage*10_000 + perpendicularCount*100 + sampleCount
        let sampleCount = min(99, totalContacts)
        let clampedPerpCount = min(99, perpendicularCount)
        let shinStdEncoded = finalShinStd * 1_000_000.0 + perpendicularityPercentage * 10_000.0 + Double(clampedPerpCount) * 100.0 + Double(sampleCount)

        // Only use selected side for quiet feet metric
        let footVelForQuiet = useLeftSide && useRightSide 
            ? cleanedLeftFootVel + cleanedRightFootVel  // Both if auto-detection
            : (useLeftSide ? cleanedLeftFootVel : cleanedRightFootVel)  // Only selected side
        let (quietMean, quietStd) = robustStats(footVelForQuiet)
        let quietScore = rangeBasedScore(value: quietMean, range: FormCueRanges.ranges[.quietFeet]!)

        let (postureMean, postureStd) = robustStats(trunkAngles)
        let postureScoreForCue: Double
        let postureMeanForCue: Double
        let postureStdForCue: Double
        if torsoAngleMean >= 0.1 {
            postureScoreForCue = Double(classifyTorsoAngle(angle: torsoAngleMean).score)
            postureMeanForCue = torsoAngleMean
            postureStdForCue = torsoAngleStd
        } else {
            postureScoreForCue = rangeBasedScore(value: postureMean, range: FormCueRanges.ranges[.tallPosture]!)
            postureMeanForCue = postureMean
            postureStdForCue = postureStd
        }

        let cadenceMean = robustStats(cleanedCadence).mean
        let cadenceStd = robustStats(cleanedCadence).std
        let cadenceScore = rangeBasedScore(value: cadenceMean, range: FormCueRanges.ranges[.shortQuickSteps]!)

        // Foot under COM: how far ahead of the hip the ankle lands, as a
        // FRACTION OF STRIDE LENGTH — self-normalizing across speed. An elite
        // runner with a long stride lands ~a quarter stride ahead (fine); a slow
        // jogger reaching the same absolute distance on a short stride is
        // overstriding. The old cue never measured this at all (it copied the
        // shin score), which is how a clear overstride passed as 98.
        let underCOMClean = underCOMSamples.filter { $0.isFinite }
        let strideMedian = RunPhysics.median(strideSeries.filter { $0.isFinite && $0 > 0.001 })
        let underCOMFraction: Double? = {
            guard underCOMClean.count >= 2, let m = RunPhysics.median(underCOMClean) else { return nil }
            if let s = strideMedian, s > 0.001 { return m / s }
            // No stride read: fall back to body height (a stride is roughly one
            // body height at running speeds).
            guard bodyHeight > 1 else { return nil }
            return m / bodyHeight
        }()
        let (comMean, comStd) = (underCOMFraction ?? 0, 0.0)
        let footUnderCOMScore: Double = underCOMFraction.map {
            rangeBasedScore(value: $0, range: FormCueRanges.ranges[.footUnderCOM]!)
        } ?? 50   // unmeasured
        let underCOMMedian: Double? = underCOMFraction

        let frontHipSeries: [Double] = zip(frames, zip(cleanedLeftHip, cleanedRightHip)).map { (frame: PoseFrame, vals: (Double, Double)) -> Double in
            let useRight = frontSideByDepth(frame)
            return useRight ? vals.1 : vals.0
        }
        // removed knee drive cue

        let frontElbowSeries = zip(frames, zip(leftElbowFlex, rightElbowFlex)).map { frame, vals -> Double in
            let useRight = frontSideByDepth(frame)
            return useRight ? vals.1 : vals.0
        }
        let elbowMean = frontElbowSeries.reduce(0, +) / Double(max(frontElbowSeries.count, 1))
        var elbowScoreForCue: Double
        let elbowMeanForCue: Double
        if elbowAngleMean > 0 {
            elbowScoreForCue = Double(classifyElbowAngle(angle: elbowAngleMean).score)
            elbowMeanForCue = elbowAngleMean
        } else {
            elbowScoreForCue = rangeBasedScore(value: elbowMean, range: FormCueRanges.ranges[.elbows]!)
            elbowMeanForCue = elbowMean
        }
        // Inconsistent carriage: a mean inside the band can hide arms pumping
        // open and shut every stride. Elite carriage holds the elbow near a
        // fixed angle, so high swing variability is itself the fault. Threshold
        // and slope are deliberately gentle — pose jitter inflates the std, and
        // the first pass at 14°/2.5x false-flagged a perfect-form reference clip.
        if elbowAngleStd.isFinite, elbowAngleStd > 20 {
            elbowScoreForCue = max(45, elbowScoreForCue - (elbowAngleStd - 20) * 1.5)
        }

        let (hipMean, hipStd) = robustStats(cleanedHipDrop)
        let hipsScore = rangeBasedScore(value: hipMean, range: FormCueRanges.ranges[.hipsStable]!)

        let headScoreForCue: Double
        let headMeanForCue: Double
        let headStdForCue: Double
        if headAngleMean >= 0.1 {
            headScoreForCue = Double(classifyHeadAngle(angle: headAngleMean).score)
            headMeanForCue = headAngleMean
            headStdForCue = headAngleStd
        } else {
            headScoreForCue = 50.0
            headMeanForCue = 0
            headStdForCue = headAngleStd
        }

        // Use median for foot placement to resist outlier frames (e.g. mid-swing mis-detections)
        let footPlacementFiltered = removeOutliers(footPlacementAngles).filter { $0.isFinite && !$0.isNaN }
        let footPlacementMedian: Double
        let footPlacementStd: Double
        if footPlacementFiltered.count >= 2 {
            let sorted = footPlacementFiltered.sorted()
            footPlacementMedian = sorted.count % 2 == 0
                ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2.0
                : sorted[sorted.count / 2]
            let mean = sorted.reduce(0, +) / Double(sorted.count)
            let variance = sorted.reduce(0) { $0 + pow($1 - mean, 2) } / Double(max(sorted.count - 1, 1))
            footPlacementStd = max(sqrt(variance), 1)
        } else {
            footPlacementMedian = robustStats(footPlacementAngles).mean
            footPlacementStd = max(robustStats(footPlacementAngles).std, 1)
        }
        var footPlacementScore = rangeBasedScore(value: footPlacementMedian, range: FormCueRanges.ranges[.footPlacement]!)
        // "Heel never touches": persistent toes-only running (no heel drop in
        // stance) overloads the calf/achilles and is the user-flagged red flag.
        // Only applied below sprint turnover — genuine sprinting is forefoot by
        // design. A rolling contact that brings the heel down passes untouched.
        if noHeelRatio.isFinite, cadenceMean < 170 {
            if noHeelRatio >= 0.7 {
                footPlacementScore = min(footPlacementScore, 42)
            } else if noHeelRatio >= 0.4 {
                footPlacementScore = min(footPlacementScore, 62)
            }
        }

        let formScores: [FormCueScore] = [
            FormCueScore(cue: .shinVertical, score: shinScore, rawValue: shinMeanForScore, mean: shinMeanForScore, std: shinStdEncoded),
            FormCueScore(cue: .quietFeet, score: quietScore, rawValue: quietMean, mean: quietMean, std: quietStd),
            FormCueScore(cue: .tallPosture, score: postureScoreForCue, rawValue: postureMeanForCue, mean: postureMeanForCue, std: postureStdForCue),
            FormCueScore(cue: .shortQuickSteps, score: cadenceScore, rawValue: cadenceMean, mean: cadenceMean, std: cadenceStd),
            FormCueScore(cue: .footUnderCOM, score: footUnderCOMScore, rawValue: underCOMMedian ?? comMean, mean: comMean, std: comStd),
            FormCueScore(cue: .elbows, score: elbowScoreForCue, rawValue: elbowMeanForCue, mean: elbowMeanForCue, std: elbowAngleStd),
            FormCueScore(cue: .hipsStable, score: hipsScore, rawValue: hipMean, mean: hipMean, std: hipStd),
            FormCueScore(cue: .eyesForward, score: headScoreForCue, rawValue: headMeanForCue, mean: headMeanForCue, std: headStdForCue),
            FormCueScore(cue: .footPlacement, score: footPlacementScore, rawValue: footPlacementMedian, mean: footPlacementMedian, std: max(footPlacementStd, 1))
        ]
        
        // The clean-window pass already trimmed entry/exit garbage, so the old
        // "drop the first 1s" warm-up trim is redundant and would just discard
        // good data. Keep trim() as identity (startIndex 0) — this also keeps the
        // fold-over-peaks alignment offset at zero (full-length series throughout).
        let analysisStartTime = times.first ?? 0
        func trim(_ values: [Double]) -> [Double] { values }
        let trimmedDuration = max((times.last ?? 0) - analysisStartTime, 0)
        
        let series = MetricSeries(
            durationSeconds: trimmedDuration,
            analysisStartTime: analysisStartTime,
            cadenceSeries: trim(cleanedCadence),
            strideLengthSeries: strideSeries,
            groundContactLeftSeries: trim(cleanedGctLeft),
            groundContactRightSeries: trim(cleanedGctRight),
            verticalOscillationSeries: trim(cleanedVertical),
            kneeAngleSeries: kneeSeries,
            hipDropSeries: trim(cleanedHipDrop),
            gaitCycleSeries: gaitSeries,
            leftKneeAngleTimeSeries: trim(cleanedLeftKnee),
            rightKneeAngleTimeSeries: trim(cleanedRightKnee),
            leftHipAngleTimeSeries: trim(cleanedLeftHip),
            rightHipAngleTimeSeries: trim(cleanedRightHip),
            leftAnkleAngleTimeSeries: trim(cleanedLeftAnkle),
            rightAnkleAngleTimeSeries: trim(cleanedRightAnkle),
            leftFootYTimeSeries: trim(cleanedLeftFootY),
            rightFootYTimeSeries: trim(cleanedRightFootY),
            leftFootVelTimeSeries: trim(cleanedLeftFootVel),
            rightFootVelTimeSeries: trim(cleanedRightFootVel),
            leftKneeAngularVelocitySeries: trim(leftKneeVel),
            rightKneeAngularVelocitySeries: trim(rightKneeVel),
            leftHipAngularVelocitySeries: trim(leftHipVel),
            rightHipAngularVelocitySeries: trim(rightHipVel),
            kneeSymmetrySeries: trim(kneeSymmetry),
            gctSymmetrySeries: trim(gctSymmetry),
            footVelocityXSeries: trim(cleanedFootVelX),
            hipMovementYSeries: trim(normalizedHipMovementY),
            headBobbingYSeries: trim(normalizedHeadBobbingY),
            armMovementXSeries: trim(normalizedArmMovementX),
            torsoAngleMean: torsoAngleMean,
            headAngleMean: headAngleMean,
            elbowAngleMean: elbowAngleMean,
            kneeAngleMean: kneeAngleMean,
            hipAngleMean: hipAngleMean,
            perFrameTorsoAngles: perFrameTorso,
            perFrameGazeAngles: perFrameGaze,
            perFrameElbowAngles: perFrameElbow,
            bodyHeightPixels: bodyHeight,
            leftFootHipDistanceSeries: useLeftSide ? leftFiltered : [],  // Only include if selected
            rightFootHipDistanceSeries: useRightSide ? rightFiltered : [],  // Only include if selected
            heelStrikeFrameIndices: selectedPeaks,
            formCueScores: formScores,
            frameRate: frameRate,
            shankAngleAtContactSignedDeg: shankAngleAtContactSigned,
            noHeelRatio: noHeelRatio
        )

        return (metrics, series)
    }
    
    private func getRenderSize(naturalSize: CGSize, transform: CGAffineTransform) -> (Int, Int) {
        // Calculate the oriented display size by applying the track transform
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let width = Int(abs(rect.width))
        let height = Int(abs(rect.height))
        return (width, height)
    }
    
    // Analyze tab is red-themed. The skeleton stays on-theme by drawing the near
    // (right) side and center in form-red and the far (left) side in white, so the
    // two sides remain distinguishable without introducing off-theme colors.
    private static let skeletonAccent = UIColor(red: 0, green: 0.90, blue: 1, alpha: 1)  // #00E5FF cyan

    private func jointColor(for joint: PoseJoint) -> UIColor {
        switch joint {
        case .nose, .neck:
            return .white
        default:
            if joint.isLeft { return .white }
            return Self.skeletonAccent
        }
    }

    private func connectionColor(for connection: (PoseJoint, PoseJoint)) -> UIColor {
        // Pure far-side (left-only) limbs in white; everything else in the cyan accent.
        if (connection.0.isLeft || connection.1.isLeft),
           !(connection.0.isRight || connection.1.isRight) {
            return .white
        }
        return Self.skeletonAccent
    }
    
    // MARK: - Outlier Removal
    
    /// Removes outliers using median filter + IQR-based clipping
    /// - Parameters:
    ///   - series: Input data array
    ///   - windowSize: Size of median filter window (default 5)
    ///   - iqrMultiplier: IQR multiplier for clipping bounds (default 1.5)
    /// - Returns: Cleaned series with outliers smoothed/clamped
    private func removeOutliers(_ series: [Double], windowSize: Int = 5, iqrMultiplier: Double = 1.5) -> [Double] {
        guard series.count > windowSize else { return series }
        
        // Step 1: Median filter to smooth short glitches
        var filtered = [Double](repeating: 0, count: series.count)
        let halfWindow = windowSize / 2
        
        for i in series.indices {
            let start = max(0, i - halfWindow)
            let end = min(series.count - 1, i + halfWindow)
            var window = Array(series[start...end])
            window.sort()
            filtered[i] = window[window.count / 2]
        }
        
        // Step 2: Calculate IQR bounds
        let validValues = filtered.filter { !$0.isNaN && $0.isFinite }
        guard validValues.count > 4 else { return filtered }
        
        let sorted = validValues.sorted()
        let q1Index = sorted.count / 4
        let q3Index = (sorted.count * 3) / 4
        let q1 = sorted[q1Index]
        let q3 = sorted[q3Index]
        let iqr = q3 - q1
        let lowerBound = q1 - iqrMultiplier * iqr
        let upperBound = q3 + iqrMultiplier * iqr
        
        // Step 3: Clamp values to IQR bounds
        return filtered.map { value in
            if value.isNaN || !value.isFinite { return value }
            return min(max(value, lowerBound), upperBound)
        }
    }
}

enum ProcessingError: LocalizedError {
    case noVideoTrack
    case writeFailed
    
    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "No video track found"
        case .writeFailed: return "Failed to write processed video"
        }
    }
}
