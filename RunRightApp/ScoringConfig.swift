//
//  ScoringConfig.swift
//  RunRightApp
//
//  The calibration knobs of the scoring engine, in one tunable place. Every value
//  defaults to the shipped constant, so behaviour is identical until a value is
//  overridden. Firebase Remote Config can override any subset at runtime (see
//  RemoteConfigManager), which means we can RE-CALIBRATE THE ENGINE AFTER LAUNCH
//  WITHOUT AN APP STORE RELEASE — the app reads new values on next launch.
//
//  Only genuine calibration knobs live here. Research-grounded physics (Morin
//  spring-mass coefficients, the 0-100 score scale, percentile math) stays
//  compiled: those are not things you tune from a console.
//
//  Threading: the engine runs off the main thread, so the live config is held in
//  a lock-protected, Sendable store rather than the @MainActor RemoteConfigManager.
//

import Foundation

struct ScoringConfig: Codable, Sendable, Equatable {
    // MARK: DRIVE — hip drive ROM (RunningPowerModel.power)
    // Thigh sagittal sweep. Reward up to a strong sweep, plateau for genuinely
    // powerful runners, then fall off so exaggeration can't max the dial.
    var hipRampLo: Double = 25          // ° mapping to 0
    var hipRampHi: Double = 55          // ° mapping to 100
    var hipPlateauMax: Double = 70      // ° up to which the score holds at 100
    var hipFalloffSlope: Double = 1.8   // points lost per ° above the plateau

    // MARK: DRIVE — knee drive ROM (RunningPowerModel.power)
    var kneeRampLo: Double = 60
    var kneeRampHi: Double = 110
    var kneePlateauMax: Double = 122
    var kneeFalloffSlope: Double = 2.2

    // MARK: DRIVE — ankle push-off ROM (RunningPowerModel.power)
    // Same reward-plateau-falloff shape as hip/knee. The old plain ramp
    // saturated at 40° so every clip — clean or floppy — scored 100 and the
    // term was pure inflation.
    var ankleRampLo: Double = 20
    var ankleRampHi: Double = 45
    var anklePlateauMax: Double = 55
    var ankleFalloffSlope: Double = 2.5
    // Ankle sweep beyond this is a tracking artifact, not motion (physiologic
    // running ROM tops out near ~55°): the input becomes unmeasurable.
    var anklePlausibleMax: Double = 70
    // Hip plausibility for the camera-facing-side read. Sized so the falloff
    // keeps runway over real exaggeration (90-115° over-kips are penalized,
    // not dropped) while known occlusion artifacts (measured 129-150° on
    // clean elite footage) stay excluded. The legacy max(left,right)
    // fallback keeps the stricter scanMaxPlausibleHipROM window.
    var hipPlausibleMax: Double = 120

    // MARK: DRIVE — turnover pillar (RunPowerModel.power)
    // Quick steps in the running band are direct propulsion evidence (stride
    // power = force x turnover); ramps 0→100 across the band below. Outside
    // 100-200 spm the read is a slow-mo clip or a broken count → unmeasurable.
    var driveCadRampLo: Double = 140
    var driveCadRampHi: Double = 170

    // MARK: DRIVE — evidence corrections (VideoProcessor.powerResult)
    // Persistent toes-only running (heel never drops in stance) is calf
    // bounce, not propulsion: discount DRIVE up to driveNoHeelMaxDiscount,
    // ramping in from the onset ratio, only below sprint turnover. Tiers
    // match the footPlacement cue (0.4 moderate, 0.7 severe).
    var driveNoHeelOnset: Double = 0.4
    var driveNoHeelFull: Double = 0.7
    var driveNoHeelMaxDiscount: Double = 0.30
    var driveNoHeelCadenceMax: Double = 170
    // A single surviving evidence pillar cannot certify elite drive.
    var driveLonePillarCap: Double = 75
    // Below 60 fps the contact/flight read is quantization-dominated (one
    // 33 ms frame is a large slice of an elite flight). When the spring-mass
    // score contradicts the angle-based drive read by more than this many
    // points, the timing is dropped from the blend and the angles win.
    var driveSmDiscrepancyGate: Double = 30

    // MARK: SMOOTH — arm-swing amplitude (computeEfficiencyBreakdown)
    // Elbow-angle range: tight carriage (~15-25°) is efficient; flailing wide is a
    // real smoothness fault. Tight = 100, ramps down past the ceiling to a floor.
    var armEffCeiling: Double = 65      // ° up to which arm carriage scores 100
    var armEffSlope: Double = 1.3       // points lost per ° above the ceiling
    var armEffFloor: Double = 30        // lowest the arm-efficiency score can reach

    // MARK: OVERALL — fault-sensitive blend (faultSensitiveScore)
    // overall = w·mean + (1-w)·mean(worst third). Higher w = more forgiving.
    var faultBlendMeanWeight: Double = 0.5

    // MARK: Scan-quality gates (VideoProcessor)
    var scanMinCleanSeconds: Double = 3.0    // shortest usable clean window
    var scanMaxJitterRatio: Double = 0.06    // above this, tracking is "jumpy"
    // Post-metrics plausibility gate: flag footage whose MEASURED data is
    // physiologically impossible or non-periodic (a jittery skeleton). Sensitive
    // by design — a false retake costs less than scoring bad footage.
    var scanMaxPlausibleHipROM: Double = 85    // ° hip sweep above this = unstable
    var scanMaxPlausibleKneeROM: Double = 150  // ° knee sweep above this = unstable
    var scanMinGaitClarity: Double = 0.30      // stride autocorr below this = jumpy

    static let `default` = ScoringConfig()
}

// Partial overrides: a Remote Config JSON that sets only some keys still decodes,
// each missing key falling back to its shipped default. So you can change one
// number in the console without resending the whole blob.
extension ScoringConfig {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ScoringConfig.default
        func v(_ key: CodingKeys, _ fallback: Double) -> Double {
            (try? c.decodeIfPresent(Double.self, forKey: key)) .flatMap { $0 } ?? fallback
        }
        hipRampLo = v(.hipRampLo, d.hipRampLo)
        hipRampHi = v(.hipRampHi, d.hipRampHi)
        hipPlateauMax = v(.hipPlateauMax, d.hipPlateauMax)
        hipFalloffSlope = v(.hipFalloffSlope, d.hipFalloffSlope)
        kneeRampLo = v(.kneeRampLo, d.kneeRampLo)
        kneeRampHi = v(.kneeRampHi, d.kneeRampHi)
        kneePlateauMax = v(.kneePlateauMax, d.kneePlateauMax)
        kneeFalloffSlope = v(.kneeFalloffSlope, d.kneeFalloffSlope)
        ankleRampLo = v(.ankleRampLo, d.ankleRampLo)
        ankleRampHi = v(.ankleRampHi, d.ankleRampHi)
        anklePlateauMax = v(.anklePlateauMax, d.anklePlateauMax)
        ankleFalloffSlope = v(.ankleFalloffSlope, d.ankleFalloffSlope)
        anklePlausibleMax = v(.anklePlausibleMax, d.anklePlausibleMax)
        hipPlausibleMax = v(.hipPlausibleMax, d.hipPlausibleMax)
        driveCadRampLo = v(.driveCadRampLo, d.driveCadRampLo)
        driveCadRampHi = v(.driveCadRampHi, d.driveCadRampHi)
        driveLonePillarCap = v(.driveLonePillarCap, d.driveLonePillarCap)
        driveNoHeelOnset = v(.driveNoHeelOnset, d.driveNoHeelOnset)
        driveNoHeelFull = v(.driveNoHeelFull, d.driveNoHeelFull)
        driveNoHeelMaxDiscount = v(.driveNoHeelMaxDiscount, d.driveNoHeelMaxDiscount)
        driveNoHeelCadenceMax = v(.driveNoHeelCadenceMax, d.driveNoHeelCadenceMax)
        driveSmDiscrepancyGate = v(.driveSmDiscrepancyGate, d.driveSmDiscrepancyGate)
        armEffCeiling = v(.armEffCeiling, d.armEffCeiling)
        armEffSlope = v(.armEffSlope, d.armEffSlope)
        armEffFloor = v(.armEffFloor, d.armEffFloor)
        faultBlendMeanWeight = v(.faultBlendMeanWeight, d.faultBlendMeanWeight)
        scanMinCleanSeconds = v(.scanMinCleanSeconds, d.scanMinCleanSeconds)
        scanMaxJitterRatio = v(.scanMaxJitterRatio, d.scanMaxJitterRatio)
        scanMaxPlausibleHipROM = v(.scanMaxPlausibleHipROM, d.scanMaxPlausibleHipROM)
        scanMaxPlausibleKneeROM = v(.scanMaxPlausibleKneeROM, d.scanMaxPlausibleKneeROM)
        scanMinGaitClarity = v(.scanMinGaitClarity, d.scanMinGaitClarity)
    }
}

/// Thread-safe holder for the live config. The engine reads this from background
/// threads; RemoteConfigManager writes it on the main thread after a fetch.
final class ScoringConfigStore: @unchecked Sendable {
    static let shared = ScoringConfigStore()
    private let lock = NSLock()
    private var _config = ScoringConfig.default

    var config: ScoringConfig {
        lock.lock(); defer { lock.unlock() }
        return _config
    }

    func update(_ newValue: ScoringConfig) {
        lock.lock(); _config = newValue; lock.unlock()
    }
}

/// Short accessor for engine call sites: `scoringConfig.hipPlateauMax`.
var scoringConfig: ScoringConfig { ScoringConfigStore.shared.config }
