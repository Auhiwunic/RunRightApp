//
//  RunningFormMetrics.swift
//  RunRightApp
//

import Foundation
import simd
import CoreGraphics

struct RunningFormContact {
    let t: Double
    let frameIndex: Int
}

struct RunningFormStep {
    let tContact: Double
    let shinAngleDeg: Double
    let overstrideNorm: Double
    let brakingProxy: Double
    let trunkLeanDeg: Double
    let cadenceAtThatTime: Double
    let elbowAngleDeg: Double
    let kneeAngleDeg: Double        // stance-knee flexion at contact (hip-knee-ankle)
    let hipAngleDeg: Double         // trunk-thigh angle at contact (shoulder-hip-knee)
    let verticalOscNorm: Double
    let headForwardNorm: Double
    let scores: RunningFormScores
    let confidence: RunningFormStepConfidence
}

struct RunningFormSummary {
    let cadence: Double
    let shinAngleMean: Double
    let overstrideMean: Double
    let brakingMean: Double
    let trunkLeanMean: Double
    let elbowMean: Double
    let kneeAngleMean: Double
    let hipAngleMean: Double
    let verticalOscMean: Double
    let headForwardMean: Double
    let variability: RunningFormVariability
}

struct RunningFormVariability {
    let cadenceCV: Double
    let shinAngleStd: Double
    let overstrideStd: Double
    let brakingStd: Double
    let trunkLeanStd: Double
    let elbowStd: Double
    let verticalOscStd: Double
    let headForwardStd: Double
}

struct RunningFormScores {
    let shin: Double
    let overstride: Double
    let braking: Double
    let posture: Double
    let cadence: Double
    let elbow: Double
    let hips: Double
    let head: Double
    let total: Double
}

struct RunningFormStepConfidence {
    let overall: Double
    let perMetric: RunningFormScores
}

struct RunningFormConfidence {
    let overall: Double
    let perMetric: RunningFormScores
}

struct RunningFormResults {
    let contacts: [RunningFormContact]
    let steps: [RunningFormStep]
    let summary: RunningFormSummary
    let finalScores: RunningFormScores
    let confidence: RunningFormConfidence
    let debug: RunningFormDebug
}

struct RunningFormDebug {
    let rejectedContacts: Int
    let rejectionReasons: [String: Int]
}

struct RunningFormConfig {
    // Contact detection
    let minContactGapSeconds: Double = 0.25
    let minCadence: Double = 120
    let maxCadence: Double = 230
    let contactWindow: Int = 2
    
    // Scoring thresholds
    let shinGoodMax: Double = 8
    let shinHardMax: Double = 20
    let overstrideGoodMax: Double = 0.08
    let overstrideHardMax: Double = 0.20
    let brakingGoodMax: Double = 0.12
    let brakingHardMax: Double = 0.35
    let postureGoodMin: Double = 5
    let postureGoodMax: Double = 15
    let postureHardMax: Double = 25
    let cadenceGoodMin: Double = 165
    let cadenceGoodMax: Double = 200   // was 190; elites sustain 185-200 at pace
    let cadenceHardMin: Double = 130
    let cadenceHardMax: Double = 220
    let elbowGoodMin: Double = 80
    let elbowGoodMax: Double = 100
    let elbowHardMin: Double = 70
    let elbowHardMax: Double = 110
    let hipsOscGoodMax: Double = 0.04
    let hipsOscHardMax: Double = 0.10
    let headForwardGoodMax: Double = 0.08
    let headForwardHardMax: Double = 0.18
    
    // Weights
    let weightOverstride: Double = 0.25
    let weightBraking: Double = 0.20
    let weightShin: Double = 0.15
    let weightPosture: Double = 0.15
    let weightCadence: Double = 0.10
    let weightElbow: Double = 0.03
    let weightHips: Double = 0.10
    let weightHead: Double = 0.02
}

enum RunningFormMetrics {
    static func compute(
        frames: [PoseFrame],
        fps: Double,
        useWorld: Bool,
        config: RunningFormConfig = RunningFormConfig()
    ) -> RunningFormResults {
        let times = frames.map { $0.time }
        let dt = max(1.0 / max(fps, 1), 1.0 / 30.0)
        
        func point(_ frame: PoseFrame, _ joint: PoseJoint) -> CGPoint? {
            frame.points[joint]
        }
        
        func point3D(_ frame: PoseFrame, _ joint: PoseJoint) -> SIMD3<Double>? {
            frame.points3D[joint]
        }
        
        func frontSideByDepth(_ frame: PoseFrame) -> Bool {
            guard let lk = point3D(frame, .leftKnee), let rk = point3D(frame, .rightKnee) else {
                return frame.facingRight
            }
            return rk.z < lk.z
        }
        
        func frontPoint(_ frame: PoseFrame, left: PoseJoint, right: PoseJoint) -> CGPoint? {
            let useRight = frontSideByDepth(frame)
            return useRight ? point(frame, right) : point(frame, left)
        }
        
        func frontPoint3D(_ frame: PoseFrame, left: PoseJoint, right: PoseJoint) -> SIMD3<Double>? {
            let useRight = frontSideByDepth(frame)
            return useRight ? point3D(frame, right) : point3D(frame, left)
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
        
        func length(_ a: CGPoint, _ b: CGPoint) -> Double {
            hypot(Double(a.x - b.x), Double(a.y - b.y))
        }
        
        func normalize(_ v: CGPoint) -> CGPoint {
            let m = hypot(v.x, v.y)
            guard m > 0 else { return .zero }
            return CGPoint(x: v.x / m, y: v.y / m)
        }
        
        func verticalAngleDeg(_ v: CGPoint) -> Double {
            let vertical = CGPoint(x: 0, y: -1) // up
            let nv = normalize(v)
            let dot = max(-1.0, min(1.0, Double(nv.x * vertical.x + nv.y * vertical.y)))
            return abs(acos(dot) * 180 / .pi)
        }
        
        // Build front-side series
        var hipSeries: [CGPoint] = []
        var shoulderSeries: [CGPoint] = []
        var kneeSeries: [CGPoint] = []
        var ankleSeries: [CGPoint] = []
        var heelSeries: [CGPoint] = []
        var footIndexSeries: [CGPoint] = []
        var elbowSeries: [CGPoint] = []
        var wristSeries: [CGPoint] = []
        var noseSeries: [CGPoint] = []
        
        for frame in frames {
            hipSeries.append(frontPoint(frame, left: .leftHip, right: .rightHip) ?? .zero)
            shoulderSeries.append(frontPoint(frame, left: .leftShoulder, right: .rightShoulder) ?? .zero)
            kneeSeries.append(frontPoint(frame, left: .leftKnee, right: .rightKnee) ?? .zero)
            ankleSeries.append(frontPoint(frame, left: .leftAnkle, right: .rightAnkle) ?? .zero)
            heelSeries.append(frontPoint(frame, left: .leftHeel, right: .rightHeel) ?? .zero)
            footIndexSeries.append(frontPoint(frame, left: .leftFootIndex, right: .rightFootIndex) ?? .zero)
            elbowSeries.append(frontPoint(frame, left: .leftElbow, right: .rightElbow) ?? .zero)
            wristSeries.append(frontPoint(frame, left: .leftWrist, right: .rightWrist) ?? .zero)
            noseSeries.append(point(frame, .nose) ?? .zero)
        }
        
        func smooth(_ values: [Double], alpha: Double) -> [Double] {
            guard !values.isEmpty else { return [] }
            var out = values
            var prev = values[0]
            for i in 1..<values.count {
                let v = alpha * values[i] + (1 - alpha) * prev
                out[i] = v
                prev = v
            }
            return out
        }
        
        func derivative(_ values: [Double]) -> [Double] {
            guard values.count > 1 else { return values }
            var out = Array(repeating: 0.0, count: values.count)
            for i in 1..<values.count {
                out[i] = (values[i] - values[i - 1]) / dt
            }
            return out
        }
        
        // Foot point
        let footSeries = zip(ankleSeries, zip(heelSeries, footIndexSeries)).map { ankle, others -> CGPoint in
            let heel = others.0
            let toe = others.1
            return CGPoint(x: (ankle.x + heel.x + toe.x) / 3, y: (ankle.y + heel.y + toe.y) / 3)
        }
        
        let footX = smooth(footSeries.map { Double($0.x) }, alpha: 0.2)
        let footY = smooth(footSeries.map { Double($0.y) }, alpha: 0.2)
        let footSpeed = smooth(zip(derivative(footX), derivative(footY)).map { hypot($0, $1) }, alpha: 0.2)
        let footVelX = smooth(derivative(footX), alpha: 0.2)
        let footVelY = smooth(derivative(footY), alpha: 0.2)
        
        // Contact detection
        var contacts: [RunningFormContact] = []
        var rejected = 0
        var rejectionReasons: [String: Int] = [:]
        let minGapFrames = Int(max(config.minContactGapSeconds * fps, 1))
        var lastIndex = -minGapFrames
        
        func isLocalMin(_ arr: [Double], _ i: Int, _ w: Int) -> Bool {
            let start = max(i - w, 0)
            let end = min(i + w, arr.count - 1)
            let val = arr[i]
            for j in start...end where j != i {
                if arr[j] < val { return false }
            }
            return true
        }
        
        func isLocalMax(_ arr: [Double], _ i: Int, _ w: Int) -> Bool {
            let start = max(i - w, 0)
            let end = min(i + w, arr.count - 1)
            let val = arr[i]
            for j in start...end where j != i {
                if arr[j] > val { return false }
            }
            return true
        }
        
        for i in config.contactWindow..<(frames.count - config.contactWindow) {
            if i - lastIndex < minGapFrames { continue }
            let speedMin = isLocalMin(footSpeed, i, config.contactWindow)
            // Coordinates are top-left origin (y increases downward), so the foot
            // is on the ground at its LOWEST screen point = a local MAXIMUM of y,
            // not a minimum. (Previously isLocalMin, which detected swing apex.)
            let heightAtGround = isLocalMax(footY, i, config.contactWindow)
            let forwardMax = isLocalMax(footX, i, config.contactWindow)
            let cues = [speedMin, heightAtGround, forwardMax].filter { $0 }.count
            if cues >= 2 {
                contacts.append(RunningFormContact(t: times[i], frameIndex: i))
                lastIndex = i
            } else {
                rejected += 1
                rejectionReasons["low_cues", default: 0] += 1
            }
        }
        
        // Reject unrealistic cadence
        if contacts.count >= 2 {
            let intervals = zip(contacts.dropFirst(), contacts).map { $0.t - $1.t }
            let meanStep = intervals.reduce(0, +) / Double(intervals.count)
            let cadence = meanStep > 0 ? 60 / meanStep : 0
            if cadence < config.minCadence || cadence > config.maxCadence {
                rejected += contacts.count
                rejectionReasons["cadence_out_of_range", default: 0] += contacts.count
                contacts.removeAll()
            }
        }
        
        // Step metrics
        let legLengths = zip(hipSeries, zip(kneeSeries, ankleSeries)).map { hip, others -> Double in
            let knee = others.0
            let ankle = others.1
            return length(hip, knee) + length(knee, ankle)
        }
        let torsoLengths = zip(shoulderSeries, hipSeries).map { length($0, $1) }
        let legLength = max(legLengths.filter { $0 > 0 }.reduce(0, +) / Double(max(legLengths.filter { $0 > 0 }.count, 1)), 1)
        let torsoLength = max(torsoLengths.filter { $0 > 0 }.reduce(0, +) / Double(max(torsoLengths.filter { $0 > 0 }.count, 1)), 1)
        
        func scoreLowerBetter(_ value: Double, goodMax: Double, hardMax: Double) -> Double {
            if value <= goodMax { return 100 }
            if value >= hardMax { return 0 }
            let t = (value - goodMax) / max(hardMax - goodMax, 1e-6)
            return 100 * (1 - t)
        }
        
        func scoreRange(_ value: Double, goodMin: Double, goodMax: Double, hardMin: Double, hardMax: Double) -> Double {
            if value >= goodMin && value <= goodMax { return 100 }
            if value < goodMin {
                let t = (goodMin - value) / max(goodMin - hardMin, 1e-6)
                return max(0, 100 * (1 - t))
            }
            let t = (value - goodMax) / max(hardMax - goodMax, 1e-6)
            return max(0, 100 * (1 - t))
        }
        
        var steps: [RunningFormStep] = []
        let cadence: Double = {
            guard contacts.count > 1 else { return 0 }
            let intervals = zip(contacts.dropFirst(), contacts).map { $0.t - $1.t }
            let meanStep = intervals.reduce(0, +) / Double(intervals.count)
            return meanStep > 0 ? 60 / meanStep : 0
        }()
        
        for c in contacts {
            let i = c.frameIndex
            guard i < frames.count else { continue }
            
            let hip = hipSeries[i]
            let knee = kneeSeries[i]
            let ankle = ankleSeries[i]
            let shoulder = shoulderSeries[i]
            let elbow = elbowSeries[i]
            let wrist = wristSeries[i]
            let nose = noseSeries[i]
            let foot = footSeries[i]
            
            let shinVec = CGPoint(x: knee.x - ankle.x, y: knee.y - ankle.y)
            let shinAngle = verticalAngleDeg(shinVec)
            
            let overstride = (Double(foot.x - hip.x)) / legLength
            
            let vAt = footVelX[i]
            let vAfter = i + 3 < footVelX.count ? footVelX[i + 3] : vAt
            let decel = max(0, vAt - vAfter)
            let brakingProxy = max(0, overstride) + abs(vAt) * 0.5 + decel * 0.5
            
            let trunkVec = CGPoint(x: shoulder.x - hip.x, y: shoulder.y - hip.y)
            let trunkLean = atan2(Double(trunkVec.x), Double(-trunkVec.y)) * 180 / .pi
            
            let elbowAngle = angleDegrees(shoulder, elbow, wrist)
            let kneeAngle = angleDegrees(hip, knee, ankle)       // stance-knee flexion at contact
            let hipAngle = angleDegrees(shoulder, hip, knee)     // trunk-thigh angle at contact

            // Only frames with a detected front-hip count toward vertical
            // oscillation; the `.zero` sentinels appended for missing joints would
            // otherwise inflate the std and wrongly tank the hips score (#8).
            let hipYs = hipSeries.filter { !($0.x == 0 && $0.y == 0) }.map { Double($0.y) }
            let hipOsc = (hipYs.count > 1 ? std(values: hipYs) : 0) / torsoLength
            let headForward = (Double(nose.x - shoulder.x)) / torsoLength
            
            let shinScore = scoreLowerBetter(shinAngle, goodMax: config.shinGoodMax, hardMax: config.shinHardMax)
            let overstrideScore = scoreLowerBetter(max(0, overstride), goodMax: config.overstrideGoodMax, hardMax: config.overstrideHardMax)
            let brakingScore = scoreLowerBetter(brakingProxy, goodMax: config.brakingGoodMax, hardMax: config.brakingHardMax)
            let postureScore = scoreRange(trunkLean, goodMin: config.postureGoodMin, goodMax: config.postureGoodMax, hardMin: 0, hardMax: config.postureHardMax)
            let cadenceScore = scoreRange(cadence, goodMin: config.cadenceGoodMin, goodMax: config.cadenceGoodMax, hardMin: config.cadenceHardMin, hardMax: config.cadenceHardMax)
            let elbowScore = scoreRange(elbowAngle, goodMin: config.elbowGoodMin, goodMax: config.elbowGoodMax, hardMin: config.elbowHardMin, hardMax: config.elbowHardMax)
            let hipsScore = scoreLowerBetter(hipOsc, goodMax: config.hipsOscGoodMax, hardMax: config.hipsOscHardMax)
            let headScore = scoreLowerBetter(abs(headForward), goodMax: config.headForwardGoodMax, hardMax: config.headForwardHardMax)
            
            let total = weightedTotal(
                shin: shinScore,
                overstride: overstrideScore,
                braking: brakingScore,
                posture: postureScore,
                cadence: cadenceScore,
                elbow: elbowScore,
                hips: hipsScore,
                head: headScore,
                config: config
            )
            
            let perMetric = RunningFormScores(
                shin: shinScore,
                overstride: overstrideScore,
                braking: brakingScore,
                posture: postureScore,
                cadence: cadenceScore,
                elbow: elbowScore,
                hips: hipsScore,
                head: headScore,
                total: total
            )
            
            let conf = RunningFormStepConfidence(overall: confidenceForFrame(frameIndex: i, frames: frames), perMetric: perMetric)
            
            steps.append(
                RunningFormStep(
                    tContact: c.t,
                    shinAngleDeg: shinAngle,
                    overstrideNorm: overstride,
                    brakingProxy: brakingProxy,
                    trunkLeanDeg: trunkLean,
                    cadenceAtThatTime: cadence,
                    elbowAngleDeg: elbowAngle,
                    kneeAngleDeg: kneeAngle,
                    hipAngleDeg: hipAngle,
                    verticalOscNorm: hipOsc,
                    headForwardNorm: headForward,
                    scores: perMetric,
                    confidence: conf
                )
            )
        }
        
        let summary = RunningFormSummary(
            cadence: cadence,
            shinAngleMean: mean(steps.map { $0.shinAngleDeg }),
            overstrideMean: mean(steps.map { $0.overstrideNorm }),
            brakingMean: mean(steps.map { $0.brakingProxy }),
            trunkLeanMean: mean(steps.map { $0.trunkLeanDeg }),
            elbowMean: mean(steps.map { $0.elbowAngleDeg }),
            kneeAngleMean: mean(steps.map { $0.kneeAngleDeg }),
            hipAngleMean: mean(steps.map { $0.hipAngleDeg }),
            verticalOscMean: mean(steps.map { $0.verticalOscNorm }),
            headForwardMean: mean(steps.map { $0.headForwardNorm }),
            variability: RunningFormVariability(
                cadenceCV: cv(steps.map { $0.cadenceAtThatTime }),
                shinAngleStd: std(values: steps.map { $0.shinAngleDeg }),
                overstrideStd: std(values: steps.map { $0.overstrideNorm }),
                brakingStd: std(values: steps.map { $0.brakingProxy }),
                trunkLeanStd: std(values: steps.map { $0.trunkLeanDeg }),
                elbowStd: std(values: steps.map { $0.elbowAngleDeg }),
                verticalOscStd: std(values: steps.map { $0.verticalOscNorm }),
                headForwardStd: std(values: steps.map { $0.headForwardNorm })
            )
        )
        
        let finalScores = RunningFormScores(
            shin: mean(steps.map { $0.scores.shin }),
            overstride: mean(steps.map { $0.scores.overstride }),
            braking: mean(steps.map { $0.scores.braking }),
            posture: mean(steps.map { $0.scores.posture }),
            cadence: mean(steps.map { $0.scores.cadence }),
            elbow: mean(steps.map { $0.scores.elbow }),
            hips: mean(steps.map { $0.scores.hips }),
            head: mean(steps.map { $0.scores.head }),
            total: mean(steps.map { $0.scores.total })
        )
        
        let confidence = RunningFormConfidence(
            overall: steps.count >= 6 ? 1.0 : 0.5,
            perMetric: finalScores
        )
        
        return RunningFormResults(
            contacts: contacts,
            steps: steps,
            summary: summary,
            finalScores: finalScores,
            confidence: confidence,
            debug: RunningFormDebug(rejectedContacts: rejected, rejectionReasons: rejectionReasons)
        )
    }
    
    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
    
    private static func std(values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let m = mean(values)
        let variance = values.reduce(0) { $0 + pow($1 - m, 2) } / Double(values.count - 1)
        return sqrt(variance)
    }
    
    private static func cv(_ values: [Double]) -> Double {
        let m = mean(values)
        guard m != 0 else { return 0 }
        return std(values: values) / m
    }
    
    private static func weightedTotal(
        shin: Double,
        overstride: Double,
        braking: Double,
        posture: Double,
        cadence: Double,
        elbow: Double,
        hips: Double,
        head: Double,
        config: RunningFormConfig
    ) -> Double {
        let totalWeight = config.weightShin + config.weightOverstride + config.weightBraking + config.weightPosture +
        config.weightCadence + config.weightElbow + config.weightHips + config.weightHead
        guard totalWeight > 0 else { return 0 }
        
        let sum = shin * config.weightShin +
        overstride * config.weightOverstride +
        braking * config.weightBraking +
        posture * config.weightPosture +
        cadence * config.weightCadence +
        elbow * config.weightElbow +
        hips * config.weightHips +
        head * config.weightHead
        return sum / totalWeight
    }
    
    private static func confidenceForFrame(frameIndex: Int, frames: [PoseFrame]) -> Double {
        guard frameIndex < frames.count else { return 0 }
        let frame = frames[frameIndex]
        let required: [PoseJoint] = [.leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle, .leftShoulder, .rightShoulder]
        let present = required.filter { frame.points[$0] != nil }.count
        return Double(present) / Double(required.count)
    }
}

