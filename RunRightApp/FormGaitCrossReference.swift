//
//  FormGaitCrossReference.swift
//  RunRightApp
//
//  Fuses the skeleton/form analysis (video pose cues) with the shoe-sole wear
//  analysis (gait type + strike + wear zones) the way a clinician would: the two
//  sources sample different time-windows (video = one session, wear = accumulated
//  history), so when they AGREE confidence is high; when only one fires it's a
//  single-source read; when they conflict it's flagged for a re-check.
//
//  Pure logic — no SwiftUI — so it's easy to reason about and test.
//

import Foundation

/// How well the two sources corroborate a single finding.
enum Corroboration {
    case confirmed   // video + shoe wear agree → highest confidence
    case videoOnly   // seen in this session's video only
    case shoeOnly    // seen in the accumulated shoe wear only
    case mismatch    // shoe history and video disagree → re-check

    var label: String {
        switch self {
        case .confirmed: return "CONFIRMED"
        case .videoOnly: return "VIDEO"
        case .shoeOnly:  return "SHOE"
        case .mismatch:  return "CHECK"
        }
    }

    /// Hex the view maps to a colour.
    var hex: String {
        switch self {
        case .confirmed: return "#00FF7F"  // green — both sources agree
        case .videoOnly: return "#00CED1"  // cyan — form/video
        case .shoeOnly:  return "#FF8C00"  // orange — shoe wear
        case .mismatch:  return "#FFD23F"  // amber — needs a second look
        }
    }
}

struct CombinedInsight: Identifiable {
    /// Stable identity so SwiftUI can diff recomputed lists instead of
    /// tearing every row down (a fresh UUID per render broke ForEach diffing).
    var id: String { title + corroboration.label }
    let title: String
    let detail: String
    let corroboration: Corroboration
    let severity: Double   // 0 = worst … 100 = best; drives ordering (lower shown first)
    let isPositive: Bool
}

struct FormGaitInputs {
    var cueScores: [FormCue: Double]   // 0–100 per form cue
    var gaitType: String?              // neutral | pronation | overpronation | supination
    var strikePattern: String?         // heel | midfoot | forefoot
    var wear: [String: Int]            // zone name → 0..3 intensity (max of L/R)
    var hasVideo: Bool
    var hasShoe: Bool
    /// Validated signed shank angle at contact (deg). The reliable overstride
    /// signal — the old shinVertical/footUnderCOM cues are miscalibrated proxies.
    var shankAngleAtContactSignedDeg: Double? = nil
}

enum FormGaitCrossReference {

    // MARK: helpers

    private static func score(_ i: FormGaitInputs, _ cue: FormCue) -> Double { i.cueScores[cue] ?? 100 }
    private static func heavy(_ i: FormGaitInputs, _ zones: [String]) -> Bool { zones.contains { (i.wear[$0] ?? 0) >= 2 } }

    /// Convert a stored wear-zone colour to a 0..3 intensity.
    static func intensity(_ colour: String) -> Int {
        switch colour.lowercased() {
        case "red": return 3
        case "orange": return 2
        case "yellow": return 1
        default: return 0   // green / none
        }
    }

    /// Build insights from the persisted latest analysis + shoe scan (no live
    /// processor needed) — used by the Coach tab and Home. Empty if no analysis.
    static func storedInsights() -> [CombinedInsight] {
        guard let form = ScorecardDataStore.shared.load(),
              let stored = form.cueScores, !stored.isEmpty else { return [] }

        var scores: [FormCue: Double] = [:]
        for (raw, score) in stored { if let cue = FormCue(rawValue: raw) { scores[cue] = score } }

        let left = ScorecardDataStore.shared.loadWearZones(side: "left")
        let right = ScorecardDataStore.shared.loadWearZones(side: "right")
        let gaitType = ScorecardDataStore.shared.loadGaitType()
        let strike = ScorecardDataStore.shared.loadGaitStrike()
        let hasShoe = left != nil || right != nil || gaitType != nil || strike != nil

        let zones = ["bigToe", "lesserToes", "medialBall", "centralBall", "lateralBall",
                     "medialMidfoot", "lateralMidfoot", "medialHeel", "centralHeel", "lateralHeel"]
        var wear: [String: Int] = [:]
        for z in zones {
            let l = left.map { intensity($0.color(for: z)) } ?? 0
            let r = right.map { intensity($0.color(for: z)) } ?? 0
            wear[z] = max(l, r)
        }

        return insights(FormGaitInputs(cueScores: scores, gaitType: gaitType, strikePattern: strike,
                                       wear: wear, hasVideo: true, hasShoe: hasShoe,
                                       shankAngleAtContactSignedDeg: form.overstrideDeg))
    }

    // MARK: the engine

    static func insights(_ i: FormGaitInputs) -> [CombinedInsight] {
        var out: [CombinedInsight] = []

        let gait = i.gaitType?.lowercased() ?? ""
        let pronationGait = gait == "pronation" || gait == "overpronation"
        let supinationGait = gait == "supination"
        let heelStrikeShoe = (i.strikePattern?.lowercased() == "heel") || heavy(i, ["centralHeel", "medialHeel"])

        // ── Rule A — braking heel strike / overstride ──────────────────────────
        // Video: foot landing ahead of the hips. Prefer the VALIDATED signed
        // shank-angle-at-contact (same signal as SHIN/OVERSTRIDE and the dashboard
        // card) — the old shinVertical/footUnderCOM cues are miscalibrated and read
        // a 0° shank as heel-braking. Fall back to them only if it's unavailable.
        let overstride: Double = i.shankAngleAtContactSignedDeg
            .map { Double(classifyShinStrideSigned(angle: $0).score) }
            ?? min(score(i, .shinVertical), score(i, .footUnderCOM), score(i, .footPlacement))
        let videoOverstride = i.hasVideo && overstride < 65
        // A heel strike is only "braking" if the foot also lands AHEAD of the body.
        // When the video directly shows a good landing (foot under you), it overrides
        // the heel-strike-implies-braking inference — heel striking on its own is not
        // a fault. Only raise the shoe-heel path when the video doesn't contradict it.
        let videoGoodLanding = i.hasVideo && overstride >= 65
        let shoeHeel = i.hasShoe && heelStrikeShoe && !videoGoodLanding
        if videoOverstride || shoeHeel {
            let corr: Corroboration = (videoOverstride && shoeHeel) ? .confirmed : (videoOverstride ? .videoOnly : .shoeOnly)
            let detail: String
            switch corr {
            case .confirmed: detail = "Your foot lands ahead of your hips and most of your shoe wear is at the heel. Lift your cadence about 8 percent so each step lands under your body."
            case .videoOnly: detail = "Your foot lands ahead of your hips. Lift your cadence and take quicker, shorter steps so it lands under you."
            default:         detail = "Most of your shoe wear is at the heel, which points to a braking heel strike. A small cadence bump usually fixes it."
            }
            out.append(.init(title: "Heel braking", detail: detail, corroboration: corr, severity: overstride, isPositive: false))
        }

        // ── Rule B — overpronation, read from the hip (kinetic chain) ──────────
        // Shoe : inward roll (pronation gait or medial wear).
        // Video: contralateral hip drop (glute-med control).
        let medialWear = i.hasShoe && (pronationGait || heavy(i, ["medialBall", "medialMidfoot", "medialHeel"]))
        let hipScore = score(i, .hipsStable)
        let hipDrop = i.hasVideo && hipScore < 65
        if medialWear || hipDrop {
            let mismatch = medialWear && i.hasVideo && hipScore >= 80
            let corr: Corroboration = mismatch ? .mismatch
                : (medialWear && hipDrop) ? .confirmed
                : (hipDrop ? .videoOnly : .shoeOnly)
            let detail: String
            switch corr {
            case .confirmed: detail = "Your shoe rolls inward and your hips drop on landing. The cause is hip and glute control, not your arch. Add single leg strength and lift your cadence to fix it from the top down."
            case .videoOnly: detail = "Your hips drop on landing. Strengthen the glute med with single leg bridges and lateral band walks before it shows up at the knee or foot."
            case .shoeOnly:  detail = "Your shoe wears on the inside edge. If it pairs with hip drop or knee pain, fix it from the hip. On its own a comfortable neutral shoe is fine."
            case .mismatch:  detail = "Your shoe leans inward but your hips looked stable today. Likely a mild, well controlled roll. Recheck on a tired run."
            }
            out.append(.init(
                title: mismatch ? "Mild pronation" : "Hip pronation",
                detail: detail, corroboration: corr,
                severity: hipDrop ? hipScore : 70, isPositive: false))
        }

        // ── Rule C — true supination (with the lateral-heel caveat) ────────────
        // Lateral HEEL wear alone is normal (everyone lands posterolateral, then
        // pronates), so only flag supination when wear runs lateral THROUGH the
        // forefoot as well.
        if i.hasShoe {
            let lateralForefoot = heavy(i, ["lateralBall"])
            if supinationGait && lateralForefoot {
                out.append(.init(
                    title: "Supination",
                    detail: "Your wear runs to the outside through the forefoot, so your foot is not rolling in to absorb shock. Choose cushioning and comfort over a control shoe, and build calf and ankle strength.",
                    corroboration: .shoeOnly, severity: 60, isPositive: false))
            }
        }

        // ── Rule D — heavy / loud landing ──────────────────────────────────────
        let quiet = score(i, .quietFeet)
        if i.hasVideo && quiet < 60 {
            let shoeImpact = i.hasShoe && heavy(i, ["centralHeel", "lateralHeel"])
            let corr: Corroboration = shoeImpact ? .confirmed : .videoOnly
            // don't pile on top of an already-confirmed braking heel strike
            if !(videoOverstride && shoeHeel) {
                out.append(.init(
                    title: "Heavy landing",
                    detail: corr == .confirmed
                        ? "You brake hard at contact and your heel wear backs it up. Cue soft, quiet feet and lift your cadence to lower the impact."
                        : "You land harder than you need to. Cue soft, quiet feet and add a small cadence bump.",
                    corroboration: corr, severity: quiet, isPositive: false))
            }
        }

        // ── Remaining low form cues (video-only, not already covered) ──────────
        if i.hasVideo {
            for cue in [FormCue.shortQuickSteps, .tallPosture, .eyesForward, .elbows] where score(i, cue) < 60 {
                out.append(.init(title: shortTitle(cue), detail: videoTip(cue),
                                 corroboration: .videoOnly, severity: score(i, cue), isPositive: false))
            }
        }

        // ── Rule E — positive corroboration (only if nothing negative fired) ───
        if !out.contains(where: { !$0.isPositive }) {
            let detail = i.hasShoe
                ? "Your form and your shoe wear agree. Efficient, balanced mechanics. Hold your cadence and keep it up."
                : "No clear weak spots in your form today. Scan a shoe to check it against your wear pattern."
            out.append(.init(title: "Efficient gait", detail: detail,
                             corroboration: i.hasShoe ? .confirmed : .videoOnly,
                             severity: 100, isPositive: true))
        }

        // rank: negatives first, by confidence then severity; positives last
        return out.sorted { a, b in
            if a.isPositive != b.isPositive { return !a.isPositive }
            let wa = weight(a.corroboration), wb = weight(b.corroboration)
            if wa != wb { return wa > wb }
            return a.severity < b.severity
        }
    }

    // MARK: copy

    private static func weight(_ c: Corroboration) -> Int {
        switch c { case .confirmed: return 3; case .videoOnly, .shoeOnly: return 2; case .mismatch: return 0 }
    }

    private static func shortTitle(_ cue: FormCue) -> String {
        switch cue {
        case .shortQuickSteps: return "Low cadence"
        case .tallPosture:     return "Posture / lean"
        case .eyesForward:     return "Head down"
        case .elbows:          return "Arm carriage"
        default:               return cue.rawValue
        }
    }

    private static func videoTip(_ cue: FormCue) -> String {
        switch cue {
        case .shortQuickSteps: return "Take quicker, shorter steps. Aim for 175 to 195 spm with a metronome."
        case .tallPosture:     return "Lean from the ankles, not the waist. Run tall and open your chest."
        case .eyesForward:     return "Look up. Fix your gaze about 20 metres ahead and keep your chin level."
        case .elbows:          return "Bend your elbows near 90 degrees and swing back, not across your body."
        default:               return ""
        }
    }
}
