//
//  PoseDetection.swift
//  RunRightApp
//
//  Pose detection abstraction with BlazePose (MediaPipe) and Vision fallback
//

import Foundation
import Vision
import simd

#if canImport(MediaPipeTasksVision)
import MediaPipeTasksVision
#endif

// MARK: - Pose Joint Definition (extended for BlazePose)
enum PoseJoint: CaseIterable, Hashable {
    case nose
    case neck
    case leftShoulder
    case rightShoulder
    case leftElbow
    case rightElbow
    case leftWrist
    case rightWrist
    case leftHip
    case rightHip
    case leftKnee
    case rightKnee
    case leftAnkle
    case rightAnkle
    case leftHeel
    case rightHeel
    case leftFootIndex
    case rightFootIndex
    
    var isLeft: Bool {
        switch self {
        case .leftShoulder, .leftElbow, .leftWrist, .leftHip, .leftKnee, .leftAnkle, .leftHeel, .leftFootIndex:
            return true
        default:
            return false
        }
    }
    
    var isRight: Bool {
        switch self {
        case .rightShoulder, .rightElbow, .rightWrist, .rightHip, .rightKnee, .rightAnkle, .rightHeel, .rightFootIndex:
            return true
        default:
            return false
        }
    }
}

// MARK: - Pose Observation
struct PoseObservation {
    let points2D: [PoseJoint: CGPoint]
    let points3D: [PoseJoint: SIMD3<Double>]
}

// MARK: - Pose Detector Protocol
protocol PoseDetector {
    var engineName: String { get }
    var isBlazePose: Bool { get }
    func reset()
    func detectPose(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        timestampMs: Int
    ) -> PoseObservation
}

// MARK: - Factory
enum PoseDetectorFactory {
    static func make(preferBlazePose: Bool = true) -> PoseDetector {
#if canImport(MediaPipeTasksVision)
        if let detector = BlazePoseDetector.makeIfAvailable() {
            return detector
        }
#endif
        return VisionPoseDetector()
    }
}

// MARK: - Vision Fallback
final class VisionPoseDetector: PoseDetector {
    let engineName = "Apple Vision"
    let isBlazePose = false
    private var sequenceHandler = VNSequenceRequestHandler()
    
    func reset() {
        sequenceHandler = VNSequenceRequestHandler()
    }
    
    func detectPose(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        timestampMs: Int
    ) -> PoseObservation {
        let request = VNDetectHumanBodyPoseRequest()
        try? sequenceHandler.perform([request], on: pixelBuffer, orientation: orientation)
        
        guard let observation = request.results?.first else {
            return PoseObservation(points2D: [:], points3D: [:])
        }
        
        let mapping: [(PoseJoint, VNHumanBodyPoseObservation.JointName)] = [
            (.nose, .nose),
            (.neck, .neck),
            (.leftShoulder, .leftShoulder),
            (.rightShoulder, .rightShoulder),
            (.leftElbow, .leftElbow),
            (.rightElbow, .rightElbow),
            (.leftWrist, .leftWrist),
            (.rightWrist, .rightWrist),
            (.leftHip, .leftHip),
            (.rightHip, .rightHip),
            (.leftKnee, .leftKnee),
            (.rightKnee, .rightKnee),
            (.leftAnkle, .leftAnkle),
            (.rightAnkle, .rightAnkle)
        ]
        
        var points: [PoseJoint: CGPoint] = [:]
        for (joint, vnJoint) in mapping {
            if let pt = try? observation.recognizedPoint(vnJoint),
               pt.confidence > 0.1 {
                // Vision points are normalized with origin at lower-left; convert to top-left
                points[joint] = CGPoint(x: pt.location.x, y: 1.0 - pt.location.y)
            }
        }
        return PoseObservation(points2D: points, points3D: [:])
    }
}

#if canImport(MediaPipeTasksVision)
// MARK: - BlazePose via MediaPipe Tasks
final class BlazePoseDetector: PoseDetector {
    let engineName = "MediaPipe BlazePose"
    let isBlazePose = true
    private let landmarker: PoseLandmarker
    
    private init(landmarker: PoseLandmarker) {
        self.landmarker = landmarker
    }
    
    static func modelPath() -> String? {
        let candidates = [
            "pose_landmarker_heavy",
            "pose_landmarker_heavy_fp16",
            "pose_landmarker_heavy_fp32",
            "pose_landmarker_full",
            "pose_landmarker_lite"
        ]
        
        for name in candidates {
            if let path = Bundle.main.path(
                forResource: name,
                ofType: "task",
                inDirectory: "Models"
            ) {
                return path
            }
        }
        
        // Fallback: file placed at bundle root
        for name in candidates {
            if let path = Bundle.main.path(forResource: name, ofType: "task") {
                return path
            }
        }
        return nil
    }
    
    static func makeIfAvailable() -> BlazePoseDetector? {
        guard let modelPath = modelPath() else { return nil }
        
        do {
            let options = PoseLandmarkerOptions()
            options.baseOptions.modelAssetPath = modelPath
            options.runningMode = .video
            options.numPoses = 1
            options.minPoseDetectionConfidence = 0.5
            options.minPosePresenceConfidence = 0.5
            options.minTrackingConfidence = 0.5
            
            let landmarker = try PoseLandmarker(options: options)
            return BlazePoseDetector(landmarker: landmarker)
        } catch {
            return nil
        }
    }
    
    func reset() {
        // PoseLandmarker doesn't need reset; keep instance for performance
    }
    
    func detectPose(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        timestampMs: Int
    ) -> PoseObservation {
        guard let mpImage = try? MPImage(pixelBuffer: pixelBuffer) else {
            return PoseObservation(points2D: [:], points3D: [:])
        }
        guard let result = try? landmarker.detect(
            videoFrame: mpImage,
            timestampInMilliseconds: timestampMs
        ) else {
            return PoseObservation(points2D: [:], points3D: [:])
        }
        
        guard let landmarks = result.landmarks.first else {
            return PoseObservation(points2D: [:], points3D: [:])
        }
        
        func orientedPoint(_ index: Int) -> CGPoint? {
            guard index >= 0 && index < landmarks.count else { return nil }
            let lm = landmarks[index]
            let visibility = lm.visibility?.doubleValue ?? 0
            let presence = lm.presence?.doubleValue ?? 0
            guard visibility > 0.3 || presence > 0.3 else { return nil }
            // MediaPipe normalized coords are origin top-left; adjust for orientation
            let raw = CGPoint(x: CGFloat(lm.x), y: CGFloat(lm.y))
            let oriented = applyOrientation(raw, orientation: orientation)
            return CGPoint(x: 1.0 - oriented.x, y: oriented.y)
        }
        
        func orientedPoint3D(_ index: Int) -> SIMD3<Double>? {
            guard index >= 0 && index < landmarks.count else { return nil }
            let lm = landmarks[index]
            let visibility = lm.visibility?.doubleValue ?? 0
            let presence = lm.presence?.doubleValue ?? 0
            guard visibility > 0.3 || presence > 0.3 else { return nil }
            let raw = CGPoint(x: CGFloat(lm.x), y: CGFloat(lm.y))
            let oriented = applyOrientation(raw, orientation: orientation)
            return SIMD3<Double>(Double(1.0 - oriented.x), Double(oriented.y), Double(lm.z))
        }
        
        // BlazePose indices
        // 0 nose, 11 L shoulder, 12 R shoulder, 13 L elbow, 14 R elbow, 15 L wrist, 16 R wrist
        // 23 L hip, 24 R hip, 25 L knee, 26 R knee, 27 L ankle, 28 R ankle
        // 29 L heel, 30 R heel, 31 L foot index, 32 R foot index
        var points: [PoseJoint: CGPoint] = [:]
        var points3D: [PoseJoint: SIMD3<Double>] = [:]
        
        points[.nose] = orientedPoint(0)
        points3D[.nose] = orientedPoint3D(0)
        points[.leftShoulder] = orientedPoint(11)
        points3D[.leftShoulder] = orientedPoint3D(11)
        points[.rightShoulder] = orientedPoint(12)
        points3D[.rightShoulder] = orientedPoint3D(12)
        points[.leftElbow] = orientedPoint(13)
        points3D[.leftElbow] = orientedPoint3D(13)
        points[.rightElbow] = orientedPoint(14)
        points3D[.rightElbow] = orientedPoint3D(14)
        points[.leftWrist] = orientedPoint(15)
        points3D[.leftWrist] = orientedPoint3D(15)
        points[.rightWrist] = orientedPoint(16)
        points3D[.rightWrist] = orientedPoint3D(16)
        points[.leftHip] = orientedPoint(23)
        points3D[.leftHip] = orientedPoint3D(23)
        points[.rightHip] = orientedPoint(24)
        points3D[.rightHip] = orientedPoint3D(24)
        points[.leftKnee] = orientedPoint(25)
        points3D[.leftKnee] = orientedPoint3D(25)
        points[.rightKnee] = orientedPoint(26)
        points3D[.rightKnee] = orientedPoint3D(26)
        points[.leftAnkle] = orientedPoint(27)
        points3D[.leftAnkle] = orientedPoint3D(27)
        points[.rightAnkle] = orientedPoint(28)
        points3D[.rightAnkle] = orientedPoint3D(28)
        points[.leftHeel] = orientedPoint(29)
        points3D[.leftHeel] = orientedPoint3D(29)
        points[.rightHeel] = orientedPoint(30)
        points3D[.rightHeel] = orientedPoint3D(30)
        points[.leftFootIndex] = orientedPoint(31)
        points3D[.leftFootIndex] = orientedPoint3D(31)
        points[.rightFootIndex] = orientedPoint(32)
        points3D[.rightFootIndex] = orientedPoint3D(32)
        
        // Compute neck as midpoint of shoulders if present
        if let ls = points[.leftShoulder], let rs = points[.rightShoulder] {
            points[.neck] = CGPoint(x: (ls.x + rs.x) / 2, y: (ls.y + rs.y) / 2)
        }
        if let ls = points3D[.leftShoulder], let rs = points3D[.rightShoulder] {
            points3D[.neck] = (ls + rs) / 2
        }
        
        return PoseObservation(
            points2D: points.compactMapValues { $0 },
            points3D: points3D.compactMapValues { $0 }
        )
    }
    
    private func applyOrientation(_ point: CGPoint, orientation: CGImagePropertyOrientation) -> CGPoint {
        switch orientation {
        case .up:
            return point
        case .down:
            return CGPoint(x: 1.0 - point.x, y: 1.0 - point.y)
        case .left:
            return CGPoint(x: point.y, y: 1.0 - point.x)
        case .right:
            return CGPoint(x: 1.0 - point.y, y: point.x)
        case .upMirrored:
            return CGPoint(x: 1.0 - point.x, y: point.y)
        case .downMirrored:
            return CGPoint(x: point.x, y: 1.0 - point.y)
        case .leftMirrored:
            return CGPoint(x: 1.0 - point.y, y: 1.0 - point.x)
        case .rightMirrored:
            return CGPoint(x: point.y, y: point.x)
        @unknown default:
            return point
        }
    }
}
#endif

