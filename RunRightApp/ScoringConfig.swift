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
