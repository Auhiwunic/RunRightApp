//
//  RunningPowerModel.swift
//  RunRightApp
//
//  Physics-based running POWER and IMPACT models for side-view gait analysis.
//
//  POWER is derived from the validated Morin et al. (2005) spring-mass "simple
//  method" — modelling the runner as a point mass on a single linear leg-spring
//  and approximating the vertical ground-reaction-force (vGRF) waveform with a
//  sine — combined with drive-angle range of motion. Every quantity is
//  normalised to body mass / body weight (peak force in ×BW, stiffness as the
//  spring-mass natural frequency), so the 0–100 score requires NO bodyweight
//  input and is robust to unknown runner mass.
//
//  Reference: Morin J-B, Dalleau G, Kyröläinen H, Jeannin T, Belli A.
//  "A simple method for measuring stiffness during running." J Appl Biomech,
//  21(2):167-180, 2005.  Fmax = m·g·(π/2)·(tf/tc + 1).
//
//  IMPACT captures the collision/braking cost at landing (overstride shank
//  angle, vertical oscillation, foot-strike pattern) — the opposite of power:
//  the force you absorb rather than the force you produce.
//

import Foundation

// MARK: - Confidence

/// How much trust the clip's frame rate / sample count allows for a metric.
enum MetricConfidence: String {
    case high      // frame rate high enough to resolve ground contact / flight
    case estimate  // low frame rate — timing-derived terms down-weighted
    case low       // too little data to be meaningful
}

// MARK: - Core physics (Morin spring-mass simple method)

enum RunPhysics {
    /// Standard gravity (m/s²).
    static let g = 9.80665

    /// Spring-mass model outputs, all mass-free.
    struct SpringMass {
        let contactTime: Double          // tc, seconds (median across steps)
        let flightTime: Double           // tf, seconds (median across steps)
        let dutyFactor: Double           // tc / (tc + tf), dimensionless
        let peakForceBW: Double          // Fmax / bodyweight  (×BW)
        let comDisplacement: Double      // Δy_c, vertical CoM travel during contact (m)
        let specificVertStiffness: Double // k_vert / m  (1/s²) = ω²
        let naturalFreqHz: Double         // √(k_vert/m) / 2π  (Hz)
        let sampleCount: Int
    }

    /// Median of finite values, or nil if empty.
    static func median(_ xs: [Double]) -> Double? {
        let v = xs.filter { $0.isFinite }.sorted()
        guard !v.isEmpty else { return nil }
        let n = v.count
        return n % 2 == 0 ? (v[n / 2 - 1] + v[n / 2]) / 2.0 : v[n / 2]
    }

    /// Morin "simple method" from per-step contact / flight times (seconds).
    /// Returns nil when no plausible contact time is available.
    ///
    /// Derivations (mass cancels throughout):
    ///   Fmax/(m·g) = (π/2)(tf/tc + 1)
    ///   Δy_c       = g·tc²·[ (tf/tc + 1)/(2π) + 1/8 ]
    ///   k_vert/m   = (Fmax/m) / Δy_c = g·(π/2)(tf/tc + 1) / Δy_c
    static func springMass(contactTimes tcs: [Double], flightTimes tfs: [Double]) -> SpringMass? {
        // Plausible running ground-contact window: 80–400 ms; flight 0–600 ms.
        guard let tc = median(tcs.filter { $0 > 0.08 && $0 < 0.40 }),
              let tf = median(tfs.filter { $0 >= 0.0 && $0 < 0.60 }),
              tc > 0 else { return nil }

        let ratio = tf / tc
        let peakForceBW = (.pi / 2.0) * (ratio + 1.0)
        let dyc = g * tc * tc * ((ratio + 1.0) / (2.0 * .pi) + 1.0 / 8.0)
        let kOverM = dyc > 1e-6 ? g * (.pi / 2.0) * (ratio + 1.0) / dyc : 0
        let fn = sqrt(max(kOverM, 0)) / (2.0 * .pi)
        let duty = tc / max(tc + tf, 1e-6)

        return SpringMass(
            contactTime: tc, flightTime: tf, dutyFactor: duty,
            peakForceBW: peakForceBW, comDisplacement: dyc,
            specificVertStiffness: kOverM, naturalFreqHz: fn,
            sampleCount: min(tcs.count, tfs.count)
        )
    }

    /// Specific vertical mechanical power (W/kg, mass-free): the rate of CoM-lifting
    /// work. Used for IMPACT/economy, NOT for the Power score (vertical bounce is not
    /// propulsion).  P/m = g · Δh · stepRate.
    static func specificVerticalPower(verticalOscillationMeters dh: Double, cadenceSpm: Double) -> Double {
        guard dh > 0, cadenceSpm > 0 else { return 0 }
        return g * dh * (cadenceSpm / 60.0)
    }
}

// MARK: - Scoring helpers

private func clamp(_ x: Double, _ lo: Double = 0, _ hi: Double = 100) -> Double { max(lo, min(hi, x)) }

/// Linear ramp: maps `value` in [a,b] to [0,100] (a→0, b→100), clamped.
private func ramp(_ value: Double, _ a: Double, _ b: Double) -> Double {
    guard b != a else { return 50 }
    return clamp((value - a) / (b - a) * 100.0)
}

/// Triangular band: 100 at `center`, falling to 0 at ±`halfWidth`.
private func band(_ value: Double, center: Double, halfWidth: Double) -> Double {
    guard halfWidth > 0 else { return 50 }
    return clamp(100.0 - abs(value - center) / halfWidth * 100.0)
}

/// Average of the present (non-nil) components only — never dilutes with a
/// neutral default for missing data.
private func averageOfPresent(_ parts: [Double?]) -> Double? {
    let present = parts.compactMap { $0 }
    guard !present.isEmpty else { return nil }
    return present.reduce(0, +) / Double(present.count)
}

// MARK: - POWER

struct PowerResult {
    let score: Int                  // 0–100 (50 when undetermined)
    let confidence: MetricConfidence
    let peakForceBW: Double?        // ×BW
    let dutyFactor: Double?
    let naturalFreqHz: Double?
    let label: String
    let detail: String
}

enum RunPowerModel {
    /// Frame rate at/above which ground-contact & flight times are trustworthy.
    static let reliableFPS: Double = 60

    /// Compute the Power score.
    /// - contactTimes/flightTimes: per-step seconds (from detected gait cycles).
    /// - hip/ankle/knee ROM: sagittal range of motion in degrees (drive proxies); nil if unknown.
    /// - cadenceSpm: measured step rate; turnover in the running band is direct
    ///   propulsion evidence (stride power = force × turnover). nil if unknown.
    /// - frameRate: clip fps (gates the spring-mass weighting + confidence).
    static func power(
        contactTimes: [Double],
        flightTimes: [Double],
        hipExtensionRangeDeg: Double?,
        ankleRangeDeg: Double?,
        kneeDriveRangeDeg: Double?,
        cadenceSpm: Double? = nil,
        frameRate: Double
    ) -> PowerResult {
        let sm = RunPhysics.springMass(contactTimes: contactTimes, flightTimes: flightTimes)
        let fpsReliable = frameRate >= reliableFPS

        // ── Spring-mass force & elastic-return scores (need usable contact timing) ──
        // Peak vGRF in running is typically ~2.0–2.9 ×BW; more force application =
        // more powerful, with a gentle penalty for harsh values > 3.0.
        let forceScore: Double? = sm.map { s in
            let base = ramp(s.peakForceBW, 1.8, 2.7)
            let harsh = s.peakForceBW > 3.0 ? min(20, (s.peakForceBW - 3.0) * 30) : 0
            return clamp(base - harsh)
        }
        // Leg-spring "springiness": running natural frequency ~2.4–3.8 Hz; stiffer
        // (higher fn) returns elastic energy better.
        let springScore: Double? = sm.map { band($0.naturalFreqHz, center: 3.2, halfWidth: 1.6) }
        // Flight / duty: more time airborne (lower duty) reflects a more powerful,
        // bouncier stride. Distance duty ~0.34–0.45; lower scores higher.
        let dutyScore: Double? = sm.map { ramp(0.45 - $0.dutyFactor, 0.0, 0.16) }

        // ── Drive ROM (angle-based, robust at any frame rate) ──
        // Hip extension at toe-off (backside drive), ankle plantarflexion ROM
        // (push-off), knee drive ROM. Ranges in degrees over the gait cycle.
        // Hip drive (thigh sagittal sweep). Real backside drive tops out around a
        // strong sweep; a plain ramp saturates and keeps rewarding past that, so a
        // runner who over-drives the knee up and kicks the leg back excessively
        // (thigh sweeping far past what a stride needs) reads as maximum power.
        // Measured elite drive sits near ~60°; an exaggerated, "overdoing it"
        // stride runs to ~110°+. Reward up to a strong sweep, hold a plateau for
        // genuinely powerful runners, then fall off so exaggeration cannot max the
        // dial. A normal-to-elite runner (≤ ~70°) is untouched.
        let cfg = scoringConfig
        let hipScore: Double? = hipExtensionRangeDeg.map { r in
            if r <= cfg.hipRampHi { return ramp(r, cfg.hipRampLo, cfg.hipRampHi) }
            if r <= cfg.hipPlateauMax { return 100 }
            return clamp(100 - (r - cfg.hipPlateauMax) * cfg.hipFalloffSlope)
        }
        // Ankle plantarflexion ROM (push-off). Same reward-plateau-falloff
        // shape as hip/knee: the old plain ramp saturated at 40°, so clean and
        // floppy ankles alike scored 100 and the term was pure inflation.
        let ankleScore: Double? = ankleRangeDeg.map { r in
            if r <= cfg.ankleRampHi { return ramp(r, cfg.ankleRampLo, cfg.ankleRampHi) }
            if r <= cfg.anklePlateauMax { return 100 }
            return clamp(100 - (r - cfg.anklePlateauMax) * cfg.ankleFalloffSlope)
        }
        // Knee drive ROM. Strong drive shows a healthy knee-flexion range, but a
        // plain ramp saturates at 100 and keeps rewarding past that — so an
        // exaggerated, kipping recovery (heel flicking up far toward the glute)
        // reads as maximum power when it is really wasted motion. Reward up to a
        // strong range, hold a short plateau, then fall off so an over-kipped leg
        // cannot max the dial. A normal-to-fast runner (≤ ~122°) is untouched.
        let kneeScore: Double? = kneeDriveRangeDeg.map { r in
            if r <= cfg.kneeRampHi { return ramp(r, cfg.kneeRampLo, cfg.kneeRampHi) }
            if r <= cfg.kneePlateauMax { return 100 }
            return clamp(100 - (r - cfg.kneePlateauMax) * cfg.kneeFalloffSlope)
        }
        // Turnover pillar: quick steps in the running band are propulsion the
        // joint sweeps can't see (an elite 172 spm stride drives hard with a
        // COMPACT sweep, which the ROM ramps under-credit). Outside 100-200
        // spm the read is slow-mo footage or a broken count → unmeasurable.
        let cadenceScore: Double? = cadenceSpm.flatMap { cad in
            guard cad >= 100, cad <= 200 else { return nil }
            return ramp(cad, cfg.driveCadRampLo, cfg.driveCadRampHi)
        }
        var driveScore = averageOfPresent([hipScore, ankleScore, kneeScore, cadenceScore])
        // A single surviving pillar (often just one joint after plausibility
        // filtering) is too little evidence to certify elite drive.
        let pillarCount = [hipScore, ankleScore, kneeScore, cadenceScore].compactMap { $0 }.count
        if pillarCount == 1, let d = driveScore {
            driveScore = min(d, cfg.driveLonePillarCap)
        }
        debugLog("[Power] hipROM=\(hipExtensionRangeDeg.map { Int($0) } ?? -1) ankleROM=\(ankleRangeDeg.map { Int($0) } ?? -1) kneeROM=\(kneeDriveRangeDeg.map { Int($0) } ?? -1) cad=\(cadenceSpm.map { Int($0) } ?? -1) -> hipS=\(hipScore.map { Int($0) } ?? -1) ankleS=\(ankleScore.map { Int($0) } ?? -1) kneeS=\(kneeScore.map { Int($0) } ?? -1) cadS=\(cadenceScore.map { Int($0) } ?? -1) pillars=\(pillarCount) drive=\(driveScore.map { Int($0) } ?? -1)")

        // ── Combine, weighted by frame-rate reliability ──
        let smScore = averageOfPresent([forceScore, springScore, dutyScore])
        let confidence: MetricConfidence
        let composite: Double?
        if let smScore, fpsReliable, (sm?.sampleCount ?? 0) >= 3 {
            // Trust the spring-mass physics; drive adds context.
            composite = 0.65 * smScore + 0.35 * (driveScore ?? smScore)
            confidence = .high
        } else if let driveScore {
            // Low fps or sparse timing: lean on robust drive angles; fold in any
            // spring-mass read at reduced weight and flag as an estimate — but
            // only while the two reads roughly agree. Below 60 fps a single
            // 33 ms frame is a large slice of an elite flight, so when the
            // timing-based score flatly contradicts the angle-based one, the
            // timing is quantization noise and the angles win.
            if let smScore, abs(driveScore - smScore) <= cfg.driveSmDiscrepancyGate {
                composite = 0.6 * driveScore + 0.4 * smScore
            } else {
                composite = driveScore
            }
            confidence = .estimate
        } else if let smScore, fpsReliable {
            composite = smScore
            confidence = .estimate
        } else {
            // No drive angles AND sub-60fps timing: pure quantized contact/
            // flight cannot stand alone (a one-frame rounding error swings
            // peak force ~40%). Unmeasurable, not a fake number.
            composite = nil
            confidence = .low
        }

        debugLog("[Power] smS=\(smScore.map { Int($0) } ?? -1) fps=\(Int(frameRate)) conf=\(confidence.rawValue) composite=\(composite.map { Int($0) } ?? -1)")

        guard let composite else {
            return PowerResult(
                score: 50, confidence: .low,
                peakForceBW: sm?.peakForceBW, dutyFactor: sm?.dutyFactor,
                naturalFreqHz: sm?.naturalFreqHz,
                label: "Not enough data",
                detail: "Couldn't read foot contacts or joint drive. Film the full body side-on; recording in slo-mo (60–240 fps) gives the most accurate power read."
            )
        }

        let score = Int(clamp(composite).rounded())
        let label: String
        let detail: String
        switch score {
        case 80...100:
            label = "Powerful, springy stride"
            detail = "You apply force quickly and return it elastically — strong drive off the ground with good air time."
        case 62..<80:
            label = "Solid drive"
            detail = "Reasonable force and leg spring. Strides, hills, and plyometrics will build more push-off power and elastic return."
        default:
            label = "Build power"
            detail = "Ground force and drive read low. Strength work and short hill sprints develop a stiffer, more propulsive stride."
        }
        let estimateNote = confidence == .high ? "" : " (estimate — record in slo-mo for a precise reading)"
        return PowerResult(
            score: score, confidence: confidence,
            peakForceBW: sm?.peakForceBW, dutyFactor: sm?.dutyFactor,
            naturalFreqHz: sm?.naturalFreqHz,
            label: label, detail: detail + estimateNote
        )
    }
}

// MARK: - IMPACT

struct ImpactResult {
    let score: Int                 // 0–100 (higher = lower impact = better)
    let confidence: MetricConfidence
    let shankAngleDeg: Double?      // signed: + = forward (overstride), − = vertical/behind
    let verticalOscillationCm: Double?
    let footStrike: String
    let label: String
    let detail: String
}

enum RunImpactModel {
    /// Compute the Impact (landing-cost) score.
    /// - shankAngleAtContactDeg: SIGNED shank inclination at initial contact.
    ///   Positive = shank leaning forward of vertical → foot ahead of body → overstride.
    ///   Validated overstride convention: 0→+15° = overstriding, −15→0° = good.
    /// - verticalOscillationCm: CoM vertical travel (cm).
    /// - footStrike: "Heel Strike" / "Forefoot Strike" / "Mixed" / "Unknown".
    static func impact(
        shankAngleAtContactDeg: Double?,
        verticalOscillationCm: Double?,
        footStrike: String
    ) -> ImpactResult {
        // Overstride: some forward shank lean at contact is normal even for
        // elites; only penalise once the foot lands well ahead of the body.
        // Good up to ~10°, ramping to a fault by ~26°.
        let overstrideScore: Double? = shankAngleAtContactDeg.map { clamp(100.0 - ramp($0, 10, 26)) }
        // Vertical oscillation: typical distance running is ~6–11 cm; lower = a
        // softer, more economical ride. Good ≤ ~9 cm, jarring by ~14 cm. The old
        // 16 cm ceiling was far too lenient (a big bouncer still scored well).
        let oscScore: Double? = verticalOscillationCm.map { clamp(100.0 - ramp($0, 9, 14)) }
        // Foot-strike loading: a heel strike raises the impact transient slightly
        // but is not a fault by itself for distance running (many elites heel
        // strike) — only a mild penalty, since overstride already captures the risk.
        let strikeScore: Double?
        switch footStrike {
        case "Forefoot Strike": strikeScore = 95
        case "Mixed":           strikeScore = 90
        case "Heel Strike":     strikeScore = 82
        default:                strikeScore = nil
        }

        let parts = [overstrideScore, oscScore, strikeScore].compactMap { $0 }
        guard !parts.isEmpty else {
            return ImpactResult(
                score: 50, confidence: .low,
                shankAngleDeg: shankAngleAtContactDeg, verticalOscillationCm: verticalOscillationCm,
                footStrike: footStrike, label: "Not enough data",
                detail: "Couldn't measure landing mechanics. Film the full body side-on so the foot and shin are visible at contact."
            )
        }

        let mean = parts.reduce(0, +) / Double(parts.count)
        let worst = parts.min() ?? mean
        // Gentler worst-weighting: one moderate pillar shouldn't tank an
        // otherwise-good landing, but the worst still pulls the score down.
        let composite = 0.35 * worst + 0.65 * mean
        debugLog("[Impact] shank=\(shankAngleAtContactDeg.map { String(format: "%.1f", $0) } ?? "nil") voCm=\(verticalOscillationCm.map { String(format: "%.1f", $0) } ?? "nil") strike=\(footStrike) -> over=\(overstrideScore.map { Int($0) } ?? -1) osc=\(oscScore.map { Int($0) } ?? -1) strikeS=\(strikeScore.map { Int($0) } ?? -1) -> \(Int(composite))")

        let score = Int(clamp(composite).rounded())
        let label: String
        let detail: String
        switch score {
        case 80...100:
            label = "Light, controlled landing"
            detail = "You land close to under your body with low bounce — little braking and low joint loading."
        case 62..<80:
            label = "Moderate impact"
            detail = "Some braking at contact. Lifting cadence slightly and landing with the foot closer under your hips will soften it."
        default:
            label = "High impact"
            detail = "You're landing ahead of your body and/or bouncing — that brakes each step and loads the joints. Quicker, lighter steps under your hips help most."
        }
        return ImpactResult(
            score: score,
            confidence: shankAngleAtContactDeg == nil ? .estimate : .high,
            shankAngleDeg: shankAngleAtContactDeg, verticalOscillationCm: verticalOscillationCm,
            footStrike: footStrike, label: label, detail: detail
        )
    }
}
