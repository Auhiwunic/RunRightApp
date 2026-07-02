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
}

struct GaitCycleInterval {
    let startTime: Double
    let endTime: Double
    let toeOffTime: Double
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

    // Form cue scores (0-100) and raw values
    let formCueScores: [FormCueScore]
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
        .shinVertical: FormCueRange(targetMin: -5, targetMax: 5, warnMin: -12, warnMax: 12, direction: .targetRange),
        .quietFeet: FormCueRange(targetMin: 0, targetMax: 0.08, warnMin: 0, warnMax: 0.15, direction: .lowerBetter),
        .tallPosture: FormCueRange(targetMin: 4, targetMax: 10, warnMin: 2, warnMax: 14, direction: .targetRange),
        .shortQuickSteps: FormCueRange(targetMin: 175, targetMax: 195, warnMin: 165, warnMax: 205, direction: .targetRange),
        .footUnderCOM: FormCueRange(targetMin: 0, targetMax: 0.06, warnMin: 0, warnMax: 0.12, direction: .lowerBetter),
        .elbows: FormCueRange(targetMin: 80, targetMax: 100, warnMin: 70, warnMax: 110, direction: .targetRange),
        .hipsStable: FormCueRange(targetMin: 0, targetMax: 4, warnMin: 0, warnMax: 7, direction: .lowerBetter),
        .eyesForward: FormCueRange(targetMin: -5, targetMax: 5, warnMin: -12, warnMax: 12, direction: .targetRange)
    ]
}

class VideoProcessor: ObservableObject {
    @Published var progress: Double = 0
    @Published var isProcessing = false
    @Published var processedVideoURL: URL?
    @Published var error: String?
    @Published var poseEngineName: String = ""
    @Published var usingBlazePose: Bool = false
    @Published var analysisMetrics: AnalysisMetrics?
    @Published var metricSeries: MetricSeries?
    
    var videoMode: VideoMode = .angled
    
    // Pose detector (initialized lazily to avoid heavy model load on app launch)
    private var poseDetector: PoseDetector = VisionPoseDetector()
    private let requireBlazePose: Bool = true
    
    // Fallback smoothing for edge cases
    private var previousPoints: [PoseJoint: CGPoint] = [:]
    private var missingFrameCount: [PoseJoint: Int] = [:]
    private let maxMissingFrames: Int = 5
    
    // Blip detection - permanently hide joints that teleport too often
    private var blipCount: [PoseJoint: Int] = [:]
    private var permanentlyHidden: Set<PoseJoint> = []
    private let maxBlipsBeforeHide: Int = 12 // Higher tolerance before hiding a joint
    private let blipThreshold: CGFloat = 0.25 // 25% of frame = teleport
    
    private var poseFrames: [PoseFrame] = []
    
    // Hide one forearm based on head facing direction per frame
    private enum BodySide {
        case left
        case right
    }
    
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
            processedVideoURL = nil
            analysisMetrics = nil
            metricSeries = nil
        }
        
        poseDetector = PoseDetectorFactory.make(preferBlazePose: true)
        let isBlaze = poseDetector.isBlazePose
        let engineName = poseDetector.engineName
        await MainActor.run {
            usingBlazePose = isBlaze
            poseEngineName = engineName
        }
        
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
        previousPoints = [:]
        missingFrameCount = [:]
        blipCount = [:]
        permanentlyHidden = []
        poseFrames = []
        
        do {
            let outputURL = try await processVideoFrames(inputURL: url)
            await MainActor.run {
                processedVideoURL = outputURL
                isProcessing = false
                progress = 1.0
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                isProcessing = false
            }
        }
    }
    
    private func processVideoFrames(inputURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: inputURL)
        
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.noVideoTrack
        }
        
        let duration = try await asset.load(.duration)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        
        // Get the actual display size for the oriented output
        let (renderWidth, renderHeight) = getRenderSize(naturalSize: naturalSize, transform: transform)
        let visionOrientation: CGImagePropertyOrientation = .up
        
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
        
        let totalFrames = Double(duration.seconds * Double(frameRate))
        var frameCount: Double = 0
        
        // Process frames
        while reader.status == .reading {
            autoreleasepool {
                if writerInput.isReadyForMoreMediaData,
                   let sampleBuffer = readerOutput.copyNextSampleBuffer(),
                   let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    
                    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    
                    // Detect pose (BlazePose if available, Vision fallback)
                    let timestampMs = Int(presentationTime.seconds * 1000)
                    let observation = self.poseDetector.detectPose(
                        pixelBuffer: pixelBuffer,
                        orientation: visionOrientation,
                        timestampMs: timestampMs
                    )
                    
                    // Convert normalized coordinates to pixels and apply filtering/smoothing
                    var bodyPoints: [PoseJoint: CGPoint] = [:]
                    var bodyPoints3D: [PoseJoint: SIMD3<Double>] = observation.points3D
                    let jointNames: [PoseJoint] = PoseJoint.allCases
                    
                        for jointName in jointNames {
                            // Skip permanently hidden joints
                            if self.permanentlyHidden.contains(jointName) { continue }
                            
                        if let point = observation.points2D[jointName] {
                            // Coordinates are normalized 0-1 in oriented output space
                            // Mirror skeleton left-to-right to match mirrored playback
                                let newPoint = CGPoint(
                                x: CGFloat(renderWidth) - (point.x * CGFloat(renderWidth)),
                                y: point.y * CGFloat(renderHeight)
                                )
                                
                                // Check for teleportation/blip
                                if let prevPoint = self.previousPoints[jointName] {
                                    let dx = abs(newPoint.x - prevPoint.x) / CGFloat(renderWidth)
                                    let dy = abs(newPoint.y - prevPoint.y) / CGFloat(renderHeight)
                                    
                                    if dx > self.blipThreshold || dy > self.blipThreshold {
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
                    
                    // Decide forearm to hide based on mirrored preview direction:
                    // If torso->nose leans right, keep green (right) and remove blue (left).
                    let forearmToHide: BodySide = {
                        let torsoMid: CGPoint? = {
                            if let lh = bodyPoints[.leftHip], let rh = bodyPoints[.rightHip] {
                                return CGPoint(x: (lh.x + rh.x) / 2, y: (lh.y + rh.y) / 2)
                            }
                            if let ls = bodyPoints[.leftShoulder], let rs = bodyPoints[.rightShoulder] {
                                return CGPoint(x: (ls.x + rs.x) / 2, y: (ls.y + rs.y) / 2)
                            }
                            return nil
                        }()
                        guard let nose = bodyPoints[.nose], let torso = torsoMid else {
                            return .left
                        }
                        return nose.x >= torso.x ? .left : .right
                    }()
                    
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
                        if let nose = bodyPoints[.nose],
                           let ls = bodyPoints[.leftShoulder],
                           let rs = bodyPoints[.rightShoulder] {
                            let mid = CGPoint(x: (ls.x + rs.x) / 2, y: (ls.y + rs.y) / 2)
                            let facingRight = nose.x >= mid.x
                            let keepRight = facingRight
                            let jointsToRemove: [PoseJoint] = keepRight
                                ? [.leftShoulder, .leftElbow, .leftWrist, .leftHip, .leftKnee, .leftAnkle, .leftHeel, .leftFootIndex]
                                : [.rightShoulder, .rightElbow, .rightWrist, .rightHip, .rightKnee, .rightAnkle, .rightHeel, .rightFootIndex]
                            for joint in jointsToRemove {
                                bodyPoints.removeValue(forKey: joint)
                                bodyPoints3D.removeValue(forKey: joint)
                            }
                        }
                    }
                    
                    if !bodyPoints.isEmpty {
                        let facingRight: Bool = {
                            if let nose = bodyPoints[.nose],
                               let ls = bodyPoints[.leftShoulder],
                               let rs = bodyPoints[.rightShoulder] {
                                let mid = CGPoint(x: (ls.x + rs.x) / 2, y: (ls.y + rs.y) / 2)
                                return nose.x >= mid.x
                            }
                            return true
                        }()
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
                        points: bodyPoints
                    ) {
                        adaptor.append(processedBuffer, withPresentationTime: presentationTime)
                    }
                    
                    frameCount += 1
                    let currentProgress = min(frameCount / totalFrames, 0.99)
                    Task { @MainActor in
                        self.progress = currentProgress
                    }
                }
            }
        }
        
        writerInput.markAsFinished()
        await writer.finishWriting()
        
        if writer.status == .failed {
            throw writer.error ?? ProcessingError.writeFailed
        }
        
        let fps = frameRate > 0 ? Double(frameRate) : 30
        let computed = computeMetrics(frames: poseFrames, renderSize: CGSize(width: renderWidth, height: renderHeight), frameRate: fps)
        await MainActor.run {
            self.analysisMetrics = computed.0
            self.metricSeries = computed.1
        }
        
        return outputURL
    }
    
    private func drawSkeletonOnFrame(pixelBuffer: CVPixelBuffer, renderSize: CGSize, points: [PoseJoint: CGPoint]) -> CVPixelBuffer? {
        // Create output pixel buffer
        var outputBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(renderSize.width),
            Int(renderSize.height),
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &outputBuffer
        )
        
        guard let buffer = outputBuffer else { return nil }
        
        // Render the oriented video frame into the output buffer
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let ciContext = CIContext()
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
        
        // Flip context so coordinates match top-left origin
        ctx.translateBy(x: 0, y: renderSize.height)
        ctx.scaleBy(x: 1, y: -1)
        
        // Draw skeleton if we have points
        if !points.isEmpty {
            // Draw connections
            ctx.setLineWidth(4.0)
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
        
        func pelvisAxes(for frame: PoseFrame) -> (origin: SIMD3<Double>, xAxis: SIMD3<Double>, yAxis: SIMD3<Double>, zAxis: SIMD3<Double>)? {
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
        
        // Body height estimate
        var heightSamples: [Double] = []
        for frame in frames {
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
        let bodyHeight = max(percentile(heightSamples, 0.5), 1.0)
        
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
            } else {
                leftFootY.append(.nan)
                rightFootY.append(.nan)
                leftXRel.append(.nan)
                rightXRel.append(.nan)
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
            let yValid = ySeries.filter { !$0.isNaN }
            guard yValid.count > 4 else { return [] }
            
            let yThresh = percentile(yValid, 0.45)
            let vAbs = vRelSeries.compactMap { $0.isNaN ? nil : abs($0) }
            let vScale = max(percentile(vAbs, 0.5), 0.03)
            let vGate = max(0.04, vScale * 0.9)
            let yVelAbs = yVelSeries.compactMap { $0.isNaN ? nil : abs($0) }
            let yVelGate = max(percentile(yVelAbs, 0.5), 0.01)
            
            // Lenient min gap 0.12–0.18s
            let minGap = max(1, Int((frameRate * 0.14).rounded()))
            var indices: [Int] = []
            var last = -minGap
            
            for i in 2..<(ySeries.count - 2) {
                guard !ySeries[i - 1].isNaN,
                      !ySeries[i].isNaN,
                      !ySeries[i + 1].isNaN,
                      !vRelSeries[i].isNaN,
                      !yVelSeries[i].isNaN else { continue }
                
                let isLocalMin = ySeries[i] <= ySeries[i - 1] && ySeries[i] <= ySeries[i + 1]
                let lowY = ySeries[i] <= yThresh
                let nearZeroVel = abs(vRelSeries[i]) <= vGate
                let yVelFlat = abs(yVelSeries[i]) <= yVelGate
                
                // Velocity peak condition: recent peak then decline
                let prevV = vRelSeries[i - 1]
                let nextV = vRelSeries[i + 1]
                let passedPeak = abs(prevV) > abs(vRelSeries[i]) && abs(nextV) < abs(prevV)
                
                let cues = [isLocalMin || lowY, nearZeroVel || passedPeak, yVelFlat].filter { $0 }.count
                
                if cues >= 2 {
                    if i - last >= minGap {
                        indices.append(i)
                        last = i
                    }
                }
            }
            return indices
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
            times: [Double]
        ) -> [CycleIndex] {
            guard strikes.count > 1 else { return [] }
            let vAbs = vRel.compactMap { $0.isNaN ? nil : abs($0) }
            let vScale = max(percentile(vAbs, 0.7), 0.04)
            let vGate = max(0.02, vScale * 0.5)
            let yAbs = yVel.compactMap { $0.isNaN ? nil : abs($0) }
            let yScale = max(percentile(yAbs, 0.7), 0.015)
            let yGate = max(0.008, yScale * 0.35)
            let directionWindow = max(1, Int((frameRate * 0.12).rounded()))
            let minStride = 0.2
            let maxStride = 3.0
            
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
                    guard !vRel[j].isNaN, !yVel[j].isNaN else { continue }
                    let rising = yVel[j] < -yGate || (j > 0 && yVel[j] < 0 && yVel[j - 1] >= 0)
                    if stanceDir < 0 {
                        if vRel[j] > vGate && rising && (vRel[j - 1].isNaN || vRel[j - 1] <= 0) {
                            toeOffIndex = j
                            break
                        }
                    } else {
                        if vRel[j] < -vGate && rising && (vRel[j - 1].isNaN || vRel[j - 1] >= 0) {
                            toeOffIndex = j
                            break
                        }
                    }
                }
                
                if let toeOff = toeOffIndex {
                    let stanceDuration = max(times[toeOff] - times[start], 0)
                    if stanceDuration >= 0.08 && stanceDuration <= 0.45 {
                        cycles.append(CycleIndex(start: start, end: end, toeOff: toeOff))
                    }
                }
            }
            return cycles
        }
        
        let leftStrikes = detectHeelStrikes(ySeries: leftFootYSmooth, vRelSeries: leftVRel, yVelSeries: leftYVel)
        let rightStrikes = detectHeelStrikes(ySeries: rightFootYSmooth, vRelSeries: rightVRel, yVelSeries: rightYVel)
        let leftCycles = detectCycles(strikes: leftStrikes, vRel: leftVRel, yVel: leftYVel, times: times)
        let rightCycles = detectCycles(strikes: rightStrikes, vRel: rightVRel, yVel: rightYVel, times: times)
        
        func frontSideIsRight() -> Bool {
            let rightFrames = frames.filter { $0.facingRight }
            return rightFrames.count >= (frames.count - rightFrames.count)
        }
        
        let frontIsRight = frontSideIsRight()
        
        let stepCount = leftStrikes.count + rightStrikes.count
        let cadence = duration > 0 ? (Double(stepCount) / duration) * 60 : 0
        
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
        let avgStride = ((leftStride.reduce(0, +) + rightStride.reduce(0, +)) /
            Double(max(leftStride.count + rightStride.count, 1)))
        let strideLength = avgStride
        
        func groundContactTimes(from cycles: [CycleIndex]) -> [Double] {
            cycles.map { (times[$0.toeOff] - times[$0.start]) * 1000 }
        }
        
        let gctLeft = groundContactTimes(from: leftCycles)
        let gctRight = groundContactTimes(from: rightCycles)
        let avgGctLeft = gctLeft.isEmpty ? 0 : gctLeft.reduce(0, +) / Double(gctLeft.count)
        let avgGctRight = gctRight.isEmpty ? 0 : gctRight.reduce(0, +) / Double(gctRight.count)
        
        func groundContactSeries(_ ySeries: [Double]) -> [Double] {
            let valid = ySeries.filter { !$0.isNaN }
            guard !valid.isEmpty else { return Array(repeating: 0, count: ySeries.count) }
            // Lower threshold from 0.8 to 0.6 for more sensitive detection
            let threshold = percentile(valid, 0.6)
            var raw = Array(repeating: 0.0, count: ySeries.count)
            var current = 0
            for i in 0..<ySeries.count {
                if !ySeries[i].isNaN && ySeries[i] >= threshold {
                    current += 1
                    raw[i] = Double(current) / frameRate * 1000
                } else {
                    current = 0
                    raw[i] = 0
                }
            }
            // Apply EMA smoothing to prevent sharp jumps
            return emaSmoothSeries(raw, alpha: 0.15)
        }
        
        // EMA smoother with delta clamping
        func emaSmoothSeries(_ values: [Double], alpha: Double) -> [Double] {
            guard values.count > 1 else { return values }
            var smoothed = Array(repeating: 0.0, count: values.count)
            smoothed[0] = values[0]
            for i in 1..<values.count {
                // EMA: new = alpha * current + (1 - alpha) * previous
                let raw = values[i]
                let prev = smoothed[i - 1]
                var newVal = alpha * raw + (1 - alpha) * prev
                // Clamp delta to prevent extreme jumps (max 10 units per frame)
                let maxDelta = 10.0
                let delta = newVal - prev
                if abs(delta) > maxDelta {
                    newVal = prev + (delta > 0 ? maxDelta : -maxDelta)
                }
                smoothed[i] = newVal
            }
            return smoothed
        }
        
        let frameCount = frames.count
        var hipY: [Double] = []
        var hipDropSeries: [Double] = []
        var kneeAngles: [Double] = []
        var trunkAngles: [Double] = []
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
        
        var leftKneeFlexSeries = Array(repeating: Double.nan, count: frameCount)
        var rightKneeFlexSeries = Array(repeating: Double.nan, count: frameCount)
        var leftHipFlexSeries = Array(repeating: Double.nan, count: frameCount)
        var rightHipFlexSeries = Array(repeating: Double.nan, count: frameCount)
        var leftAnkleFlexSeries = Array(repeating: Double.nan, count: frameCount)
        var rightAnkleFlexSeries = Array(repeating: Double.nan, count: frameCount)
        
        for (index, frame) in frames.enumerated() {
            let axes = pelvisAxes(for: frame)
            if let lh = point(frame, .leftHip),
               let rh = point(frame, .rightHip) {
                let hipMid = midPoint(lh, rh)
                hipY.append(Double(hipMid.y))
                hipDiffs.append(abs(Double(lh.y - rh.y)))
                
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
                    let ankleAngle = 180 - angleDegrees3D(lKnee3, lAnkle3, lFoot3)
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
                    let ankleAngle = 180 - angleDegrees(lKnee, lAnkle, lFoot)
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
                    let ankleAngle = 180 - angleDegrees3D(rKnee3, rAnkle3, rFoot3)
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
                    let ankleAngle = 180 - angleDegrees(rKnee, rAnkle, rFoot)
                    rightAnkleFlex.append(ankleAngle)
                    rightAnkleFlexSeries[index] = ankleAngle
                }
            }
            
            if let lShoulder = point(frame, .leftShoulder),
               let lElbow = point(frame, .leftElbow),
               let lWrist = point(frame, .leftWrist) {
                leftElbowFlex.append(180 - angleDegrees(lShoulder, lElbow, lWrist))
                leftWristX.append(Double(lWrist.x))
            }
            
            if let rShoulder = point(frame, .rightShoulder),
               let rElbow = point(frame, .rightElbow),
               let rWrist = point(frame, .rightWrist) {
                rightElbowFlex.append(180 - angleDegrees(rShoulder, rElbow, rWrist))
                rightWristX.append(Double(rWrist.x))
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
        
        let verticalOscillation = hipY.isEmpty ? 0 : (percentile(hipY, 0.9) - percentile(hipY, 0.1)) / bodyHeight * 100
        let trunkLean = trunkAngles.isEmpty ? 0 : trunkAngles.reduce(0, +) / Double(trunkAngles.count)
        let headStability = headOffsets.isEmpty ? 0 : (headOffsets.reduce(0, +) / Double(headOffsets.count)) / bodyHeight * 100
        let hipDrop = hipDiffs.isEmpty ? 0 : (hipDiffs.reduce(0, +) / Double(hipDiffs.count)) / bodyHeight * 100
        let kneeValgus = kneeValgusVals.isEmpty ? 0 : kneeValgusVals.reduce(0, +) / Double(kneeValgusVals.count)
        
        func range(_ values: [Double]) -> Double {
            guard let minVal = values.min(), let maxVal = values.max() else { return 0 }
            return maxVal - minVal
        }
        
        let kneeFlexLeftRange = range(leftKneeFlex)
        let kneeFlexRightRange = range(rightKneeFlex)
        let hipExtLeftRange = range(leftHipFlex)
        let hipExtRightRange = range(rightHipFlex)
        let ankleLeftRange = range(leftAnkleFlex)
        let ankleRightRange = range(rightAnkleFlex)
        let elbowLeftRange = range(leftElbowFlex)
        let elbowRightRange = range(rightElbowFlex)
        
        let leftWristRange = range(leftWristX)
        let rightWristRange = range(rightWristX)
        let armSwingSymmetry = (leftWristRange + rightWristRange) > 0
            ? 100 - (abs(leftWristRange - rightWristRange) / max((leftWristRange + rightWristRange) / 2, 1)) * 100
            : 0
        
        let strideSym = (leftStride.count > 0 && rightStride.count > 0)
            ? 100 - (abs((leftStride.reduce(0, +) / Double(leftStride.count)) - (rightStride.reduce(0, +) / Double(rightStride.count)))
                / max((leftStride.reduce(0, +) / Double(leftStride.count) + rightStride.reduce(0, +) / Double(rightStride.count)) / 2, 1)) * 100
            : 0
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
        
        // Build per-frame series (dense like hip drop)
        let strideSeries: [Double] = leftStride + rightStride
        let gctLeftSeries = groundContactSeries(leftFootY)
        let gctRightSeries = groundContactSeries(rightFootY)
        // Use 2.5-second rolling window for smoother cadence
        let windowSeconds = 2.5
        let windowFrames = max(1, Int((frameRate * windowSeconds).rounded()))
        let strikeIndicesSorted = (leftStrikes + rightStrikes).sorted()
        
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
            while startPtr < strikeIndicesSorted.count && strikeIndicesSorted[startPtr] < windowStart {
                startPtr += 1
            }
            while endPtr < strikeIndicesSorted.count && strikeIndicesSorted[endPtr] <= i {
                endPtr += 1
            }
            let strikeCount = max(0, endPtr - startPtr)
            let windowDuration = max(Double(i - windowStart + 1) / frameRate, 0.001)
            rawCadenceSeries[i] = (Double(strikeCount) / windowDuration) * 60
            
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
            var smoothed = Array(repeating: 0.0, count: values.count)
            smoothed[0] = values[0]
            for i in 1..<values.count {
                let raw = values[i]
                let prev = smoothed[i - 1]
                var newVal = alpha * raw + (1 - alpha) * prev
                let delta = newVal - prev
                if abs(delta) > maxDelta {
                    newVal = prev + (delta > 0 ? maxDelta : -maxDelta)
                }
                smoothed[i] = newVal
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
            GaitCycleInterval(startTime: times[$0.start], endTime: times[$0.end], toeOffTime: times[$0.toeOff])
        }
        let rightCyclesIntervals = rightCycles.map {
            GaitCycleInterval(startTime: times[$0.start], endTime: times[$0.end], toeOffTime: times[$0.toeOff])
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
            armSwingSymmetry: armSwingSymmetry
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
            guard let lk = frame.points3D[.leftKnee], let rk = frame.points3D[.rightKnee] else {
                return frontIsRight
            }
            return rk.z < lk.z
        }
        
        let frontKneeSeries = zip(frames, zip(cleanedLeftKnee, cleanedRightKnee)).map { frame, vals -> Double in
            let useRight = frontSideByDepth(frame)
            return useRight ? vals.1 : vals.0
        }
        let kneeOverAnkle = frontKneeSeries.map { $0.isNaN ? 0 : $0 }
        let (shinMean, shinStd) = robustStats(kneeOverAnkle)
        let shinScore = rangeBasedScore(value: shinMean, range: FormCueRanges.ranges[.shinVertical]!)

        let (quietMean, quietStd) = robustStats(cleanedLeftFootVel + cleanedRightFootVel)
        let quietScore = rangeBasedScore(value: quietMean, range: FormCueRanges.ranges[.quietFeet]!)

        let (postureMean, postureStd) = robustStats(trunkAngles)
        let postureScore = rangeBasedScore(value: postureMean, range: FormCueRanges.ranges[.tallPosture]!)

        let cadenceMean = robustStats(cleanedCadence).mean
        let cadenceStd = robustStats(cleanedCadence).std
        let cadenceScore = rangeBasedScore(value: cadenceMean, range: FormCueRanges.ranges[.shortQuickSteps]!)

        let (comMean, comStd) = robustStats(absArray(cleanedLeftFootY) + absArray(cleanedRightFootY))
        let comScore = rangeBasedScore(value: comMean, range: FormCueRanges.ranges[.footUnderCOM]!)

        let frontHipSeries = zip(frames, zip(cleanedLeftHip, cleanedRightHip)).map { frame, vals -> Double in
            let useRight = frontSideByDepth(frame)
            return useRight ? vals.1 : vals.0
        }
        // removed knee drive cue

        let frontElbowSeries = zip(frames, zip(leftElbowFlex, rightElbowFlex)).map { frame, vals -> Double in
            let useRight = frontSideByDepth(frame)
            return useRight ? vals.1 : vals.0
        }
        let elbowMean = frontElbowSeries.reduce(0, +) / Double(max(frontElbowSeries.count, 1))
        let elbowScore = rangeBasedScore(value: elbowMean, range: FormCueRanges.ranges[.elbows]!)

        let (hipMean, hipStd) = robustStats(cleanedHipDrop)
        let hipsScore = rangeBasedScore(value: hipMean, range: FormCueRanges.ranges[.hipsStable]!)

        // removed relax shoulders cue

        let headTiltMean = robustStats(headOffsets).mean
        let headScore = rangeBasedScore(value: headTiltMean, range: FormCueRanges.ranges[.eyesForward]!)

        let formScores: [FormCueScore] = [
            FormCueScore(cue: .shinVertical, score: shinScore, rawValue: shinMean, mean: shinMean, std: shinStd),
            FormCueScore(cue: .quietFeet, score: quietScore, rawValue: quietMean, mean: quietMean, std: quietStd),
            FormCueScore(cue: .tallPosture, score: postureScore, rawValue: postureMean, mean: postureMean, std: postureStd),
            FormCueScore(cue: .shortQuickSteps, score: cadenceScore, rawValue: cadenceMean, mean: cadenceMean, std: cadenceStd),
            FormCueScore(cue: .footUnderCOM, score: comScore, rawValue: comMean, mean: comMean, std: comStd),
            FormCueScore(cue: .elbows, score: elbowScore, rawValue: elbowMean, mean: elbowMean, std: 10),
            FormCueScore(cue: .hipsStable, score: hipsScore, rawValue: hipMean, mean: hipMean, std: hipStd),
            FormCueScore(cue: .eyesForward, score: headScore, rawValue: headTiltMean, mean: headTiltMean, std: max(robustStats(headOffsets).std, 1))
        ]
        
        let analysisStartTime = times.first(where: { $0 >= 1.0 }) ?? 0
        let startIndex = times.firstIndex(where: { $0 >= analysisStartTime }) ?? 0
        func trim(_ values: [Double]) -> [Double] {
            guard startIndex < values.count else { return [] }
            return Array(values[startIndex...])
        }
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
            formCueScores: formScores
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
    
    private func jointColor(for joint: PoseJoint) -> UIColor {
        switch joint {
        case .nose, .neck:
            return .systemYellow
        default:
            if joint.isLeft { return .cyan }
            if joint.isRight { return UIColor(red: 0, green: 1, blue: 0.5, alpha: 1) }
            return .systemGreen
        }
    }
    
    private func connectionColor(for connection: (PoseJoint, PoseJoint)) -> UIColor {
        if connection.0.isLeft || connection.1.isLeft {
            if connection.0.isRight || connection.1.isRight {
                return .systemGreen
            }
            return .cyan
        }
        if connection.0.isRight || connection.1.isRight {
            return UIColor(red: 0, green: 1, blue: 0.5, alpha: 1)
        }
        return .systemGreen
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
