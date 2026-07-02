//
//  AnalyzeView.swift
//  RunRightApp
//
//  Pixel-perfect match to HTML prototype with VideoProcessor backend

import SwiftUI
import PhotosUI
import AVKit
import AVFoundation

enum VideoMode: String, CaseIterable, Identifiable {
    case angled
    case side
    
    var id: String { rawValue }
}

struct AnalyzeView: View {
    @StateObject private var processor = VideoProcessor()
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedVideoURL: URL?
    @State private var showingInstructions = false
    @State private var replayPlayer: AVPlayer?
    @State private var isPreparingVideo = false
    @State private var showingPreview = false
    @State private var videoMode: VideoMode = .angled
    
    var body: some View {
        ZStack {
            AppTheme.bgColor.ignoresSafeArea()
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    // Top Bar with gradient
                    topBar
                    
                    // Upload Section
                    AnalyzeSectionHeader(title: "Upload Video")
                        .padding(.top, 24)
                    
                    Picker("Video Mode", selection: $videoMode) {
                        Text("Angled").tag(VideoMode.angled)
                        Text("Side").tag(VideoMode.side)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    
                    Button(action: { showingInstructions = true }) {
                        Text("See Instructions")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.clear)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                            .cornerRadius(12)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $selectedItem, matching: .videos) {
                            Text("Upload Video")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(.white.opacity(0.5))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                                .cornerRadius(10)
                        }
                        
                        Button(action: {}) {
                            Text("Record Video")
                                .font(.system(size: 12, weight: .regular))
                                .foregroundColor(.white.opacity(0.5))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.clear)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                                .cornerRadius(10)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    
                    // Error indicator
                    if let error = processor.error {
                        VStack(spacing: 10) {
                            Text("Analysis Failed")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                            Text(error)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.6))
                                .multilineTextAlignment(.center)
                            Button("Try Again") {
                                resetProcessor()
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppTheme.accentColor)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    }
                    
                    // Preparing / Processing indicator
                    if isPreparingVideo || processor.isProcessing {
                        VStack(spacing: 12) {
                            if isPreparingVideo {
                                ProgressView()
                                    .tint(AppTheme.accentColor)
                                Text("Preparing video...")
                                    .font(.system(size: 13))
                                    .foregroundColor(.white)
                            } else {
                                ProgressView(value: processor.progress)
                                    .tint(AppTheme.accentColor)
                                Text("Processing... \(Int(processor.progress * 100))%")
                                    .font(.system(size: 13))
                                    .foregroundColor(.white)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    }
                    
                    // Processed video result (overlay replay)
                    if let processedURL = processor.processedVideoURL {
                        VStack(spacing: 12) {
                            HStack {
                                Text("Overlay Replay")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.6))
                                Spacer()
                                Text(processor.poseEngineName)
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                            
                            VideoPlayer(player: replayPlayer ?? AVPlayer(url: processedURL))
                                .frame(height: 200)
                                .cornerRadius(12)
                            
                            HStack(spacing: 16) {
                                ShareLink(item: processedURL) {
                                    Text("Download Video")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(AppTheme.accentColor)
                                }
                                
                                Button(action: { resetProcessor() }) {
                                    Text("New Analysis")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(AppTheme.accentColor)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                    }
                    
                    AnalyzeSectionDivider()
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                    
                    // Form Score Section
                    AnalyzeSectionHeader(title: "Form Score")
                        .padding(.top, 24)
                    radarSection
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    AnalyzeSectionDivider()
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                    
                    // Recent Analyses Section
                    AnalyzeSectionHeader(title: "Recent Analyses")
                        .padding(.top, 24)
                    recentAnalyses
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    
                    // Bottom padding for tab bar
                    Spacer().frame(height: 120)
                }
            }
            
            // Instructions Popup
            if showingInstructions {
                instructionsPopup
            }

            // Full-screen loading overlay
            if isPreparingVideo || processor.isProcessing {
                loadingOverlay
            }
        }
        .onChange(of: selectedItem) { _, newItem in
            Task {
                if let newItem = newItem {
                    await loadVideo(from: newItem)
                }
            }
        }
        .fullScreenCover(isPresented: $showingPreview) {
            if let processedURL = processor.processedVideoURL {
                AnalyzePreviewView(
                    videoURL: processedURL,
                    poseEngineName: processor.poseEngineName,
                    metrics: processor.analysisMetrics,
                    series: processor.metricSeries,
                    onClose: {
                        showingPreview = false
                    },
                    onNewAnalysis: {
                        showingPreview = false
                        resetProcessor()
                    }
                )
            }
        }
    }
    
    // MARK: - Top Bar
    private var topBar: some View {
        ZStack {
            // Gradient background
            ZStack {
                RadialGradient(
                    colors: [Color(hex: "#1a1a1a"), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 200
                )
                RadialGradient(
                    colors: [Color(hex: "#181818"), .clear],
                    center: .bottomTrailing,
                    startRadius: 0,
                    endRadius: 150
                )
            }
            .background(AppTheme.bgColor)
            
            Text("Form Analysis")
                .font(.system(size: 26, weight: .medium))
                .foregroundColor(AppTheme.primaryText)
                .tracking(-0.3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
        }
        .frame(height: 100)
    }
    
    // MARK: - Radar Section
    private var radarSection: some View {
        VStack(spacing: 16) {
            // Score
            Text("78")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.white)
                .tracking(-2)
            
            Text("Form Score")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.5))
            
            // Radar Chart
            RadarChartView()
                .frame(width: 200, height: 200)
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Recent Analyses
    private var recentAnalyses: some View {
        VStack(spacing: 10) {
            RecentAnalysisRow(date: "Jan 8, 2026", score: "78/100")
            RecentAnalysisRow(date: "Jan 5, 2026", score: "74/100")
            RecentAnalysisRow(date: "Jan 2, 2026", score: "71/100")
        }
    }
    
    // MARK: - Instructions Popup
    private var instructionsPopup: some View {
        ZStack {
            Color.black.opacity(0.9)
                .ignoresSafeArea()
                .onTapGesture { showingInstructions = false }
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Recording Instructions")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppTheme.primaryText)
                    Spacer()
                    Button(action: { showingInstructions = false }) {
                        Text("✕")
                            .font(.system(size: 18))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .overlay(
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1),
                    alignment: .bottom
                )
                
                // Body
                ScrollView {
                    VStack(spacing: 16) {
                        // Treadmill instruction
                        InstructionRow(
                            imageName: "angle",
                            title: "Treadmill",
                            description: "Film from the side at a 45° rear angle. Capture your full body in frame with the camera at hip height. Record 10-15 seconds of running. Avoid baggy, dark, or loose clothing and ensure good lighting."
                        )
                        
                        // Outdoor instruction
                        InstructionRow(
                            imageName: "index-img",
                            title: "Outdoor",
                            description: "Film directly from the side on flat ground. Less accurate than treadmill due to limb overlap and obscured body parts making tracking more difficult. Best used when treadmill is unavailable."
                        )
                    }
                    .padding(20)
                }
            }
            .frame(width: UIScreen.main.bounds.width * 0.9)
            .background(Color(hex: "#111111"))
            .cornerRadius(16)
        }
    }
    
    // MARK: - Video Loading
    private func loadVideo(from item: PhotosPickerItem) async {
        await MainActor.run {
            isPreparingVideo = true
        }
        do {
            if let data = try await item.loadTransferable(type: Data.self) {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mov")
                try data.write(to: tempURL)
                
                await MainActor.run {
                    selectedVideoURL = tempURL
                    processVideo()
                    isPreparingVideo = false
                }
            } else {
                await MainActor.run {
                    processor.error = "Failed to load video data."
                    isPreparingVideo = false
                }
            }
        } catch {
            await MainActor.run {
                processor.error = "Failed to load video: \(error.localizedDescription)"
                isPreparingVideo = false
            }
        }
    }
    
    private func processVideo() {
        guard let url = selectedVideoURL else { return }
        Task {
            processor.videoMode = videoMode
            await processor.processVideo(url: url)
            await MainActor.run {
                if let processedURL = processor.processedVideoURL {
                    replayPlayer = AVPlayer(url: processedURL)
                    showingPreview = true
                }
            }
        }
    }
    
    private func resetProcessor() {
        selectedItem = nil
        selectedVideoURL = nil
        processor.processedVideoURL = nil
        processor.error = nil
        processor.progress = 0
        isPreparingVideo = false
        showingPreview = false
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.92)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView(value: processor.isProcessing ? processor.progress : nil)
                    .progressViewStyle(CircularProgressViewStyle(tint: AppTheme.accentColor))
                    .scaleEffect(1.8)
                Text(isPreparingVideo ? "Preparing video..." : "Analyzing form...")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                if processor.isProcessing {
                    Text("\(Int(processor.progress * 100))%")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
    }
}

// MARK: - Full Screen Preview
struct AnalyzePreviewView: View {
    let videoURL: URL
    let poseEngineName: String
    let metrics: AnalysisMetrics?
    let series: MetricSeries?
    let onClose: () -> Void
    let onNewAnalysis: () -> Void
    
    @State private var player: AVPlayer
    @State private var playbackTime: Double = 0
    @State private var timeObserver: Any?
    
    init(
        videoURL: URL,
        poseEngineName: String,
        metrics: AnalysisMetrics?,
        series: MetricSeries?,
        onClose: @escaping () -> Void,
        onNewAnalysis: @escaping () -> Void
    ) {
        self.videoURL = videoURL
        self.poseEngineName = poseEngineName
        self.metrics = metrics
        self.series = series
        self.onClose = onClose
        self.onNewAnalysis = onNewAnalysis
        _player = State(initialValue: AVPlayer(url: videoURL))
    }
    
    var body: some View {
        ZStack {
            AppTheme.bgColor.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Fixed header with video - stays visible while scrolling
                VStack(spacing: 0) {
                    HStack {
                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundColor(.white.opacity(0.7))
                                .padding(10)
                                .background(Color.white.opacity(0.08))
                                .clipShape(Circle())
                        }
                        Spacer()
                        Text("Preview")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        Spacer().frame(width: 36)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    
                    HStack {
                        Text(poseEngineName)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.5))
                        Spacer()
                        HStack(spacing: 12) {
                            ShareLink(item: videoURL) {
                                Text("Download")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(AppTheme.accentColor)
                            }
                            
                            Button(action: onNewAnalysis) {
                                Text("New")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(AppTheme.accentColor)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
                    
                    VideoPlayer(player: player)
                        .frame(height: 220)
                        .cornerRadius(12)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 8)
                }
                .background(AppTheme.bgColor)
                
                // Scrollable content below the video
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        graphSection
                            .padding(.top, 16)
                        
                        Spacer().frame(height: 40)
                    }
                }
            }
        }
        .onAppear {
            if timeObserver == nil {
                let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
                timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
                    playbackTime = time.seconds
                }
            }
        }
        .onDisappear {
            if let observer = timeObserver {
                player.removeTimeObserver(observer)
                timeObserver = nil
            }
        }
    }
    
    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Key Metrics")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
            
            MetricGroup(title: "Core Running Metrics", items: [
                MetricItem("Cadence", formatNumber(metrics?.cadence, unit: "spm"), info: MetricInfo.cadence),
                MetricItem("Ground Contact L", formatNumber(metrics?.groundContactLeft, unit: "ms"), info: MetricInfo.groundContact),
                MetricItem("Ground Contact R", formatNumber(metrics?.groundContactRight, unit: "ms"), info: MetricInfo.groundContact),
                MetricItem("Vertical Oscillation", formatNumber(metrics?.verticalOscillation, unit: "%"), info: MetricInfo.verticalOscillation),
                MetricItem("Left/Right Balance", formatNumber(metrics?.symmetryScore, unit: "%"), info: MetricInfo.symmetry)
            ])
            
            MetricGroup(title: "Posture & Alignment", items: [
                MetricItem("Trunk Lean Angle", formatNumber(metrics?.trunkLean, unit: "°"), info: MetricInfo.trunkLean),
                MetricItem("Hip Drop (L/R)", formatNumber(metrics?.hipDrop, unit: "%"), info: MetricInfo.hipDrop),
                MetricItem("Arm Swing Symmetry", formatNumber(metrics?.armSwingSymmetry, unit: "%"), info: MetricInfo.armSwing)
            ])
            
            MetricGroup(title: "Joint Kinematics", items: [
                MetricItem("Knee Flexion L", formatNumber(metrics?.kneeFlexionRangeLeft, unit: "°"), info: MetricInfo.kneeFlexion),
                MetricItem("Knee Flexion R", formatNumber(metrics?.kneeFlexionRangeRight, unit: "°"), info: MetricInfo.kneeFlexion),
                MetricItem("Hip Extension L", formatNumber(metrics?.hipExtensionRangeLeft, unit: "°"), info: MetricInfo.hipExtension),
                MetricItem("Hip Extension R", formatNumber(metrics?.hipExtensionRangeRight, unit: "°"), info: MetricInfo.hipExtension),
                MetricItem("Elbow Range L", formatNumber(metrics?.elbowRangeLeft, unit: "°"), info: MetricInfo.elbowRange),
                MetricItem("Elbow Range R", formatNumber(metrics?.elbowRangeRight, unit: "°"), info: MetricInfo.elbowRange)
            ])
        }
    }
    
    private var graphSection: some View {
        let gait = series?.gaitCycleSeries
        let stanceFallback: Double = {
            guard let gait = gait else { return 0 }
            if gait.leftStancePercent > 0 && gait.rightStancePercent > 0 {
                return (gait.leftStancePercent + gait.rightStancePercent) / 2
            }
            return max(gait.leftStancePercent, gait.rightStancePercent)
        }()
        let duration = series?.durationSeconds ?? 0
        let analysisStart = series?.analysisStartTime ?? 0
        let eventMarkers: [GaitEvent] = {
            guard let gait = gait else { return [] }
            var events: [GaitEvent] = []
            for cycle in gait.leftCycles {
                let start = cycle.startTime - analysisStart
                let toeOff = cycle.toeOffTime - analysisStart
                if start >= 0 { events.append(GaitEvent(time: start, isLeft: true, type: .heelStrike)) }
                if toeOff >= 0 { events.append(GaitEvent(time: toeOff, isLeft: true, type: .toeOff)) }
            }
            for cycle in gait.rightCycles {
                let start = cycle.startTime - analysisStart
                let toeOff = cycle.toeOffTime - analysisStart
                if start >= 0 { events.append(GaitEvent(time: start, isLeft: false, type: .heelStrike)) }
                if toeOff >= 0 { events.append(GaitEvent(time: toeOff, isLeft: false, type: .toeOff)) }
            }
            return events.sorted { $0.time < $1.time }
        }()
        let cadenceBands: [ReferenceBand] = [
            ReferenceBand(min: 180, max: 200, color: .green),
            ReferenceBand(min: 170, max: 180, color: .yellow)
        ]
        let gctBands: [ReferenceBand] = [
            ReferenceBand(min: 180, max: 220, color: .green),
            ReferenceBand(min: 220, max: 260, color: .yellow)
        ]
        let voBands: [ReferenceBand] = [
            ReferenceBand(min: 0, max: 6, color: .green),
            ReferenceBand(min: 6, max: 10, color: .yellow)
        ]
        
        return VStack(alignment: .leading, spacing: 18) {
            Text("Graphs")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
            
            // Gait Cycle Graphs (normalized 0-100%) + Time Series (with cursor)
            if gait == nil || (gait?.leftKneeAngle.isEmpty == true && gait?.rightKneeAngle.isEmpty == true) {
                GraphCard(title: "Gait Cycle Graphs", series: [], unit: "°", durationSeconds: 0, info: "Gait cycle graphs require detecting at least two heel strikes. Try a clearer side-view video.")
            } else if let gait = gait {
                // Knee Flexion
                GaitCycleGraphCard(
                    title: "Knee Flexion — Gait Cycle",
                    leftSeries: gait.leftKneeAngle,
                    rightSeries: gait.rightKneeAngle,
                    leftStd: gait.leftKneeAngleStd,
                    rightStd: gait.rightKneeAngleStd,
                    leftCycles: gait.leftKneeCycles,
                    rightCycles: gait.rightKneeCycles,
                    unit: "°",
                    stancePercent: stanceFallback,
                    isEstimate: true,
                    info: MetricInfo.gaitKnee
                )
                TimeSeriesGraphCard(
                    title: "Knee Flexion — Time Series",
                    leftSeries: series?.leftKneeAngleTimeSeries ?? [],
                    rightSeries: series?.rightKneeAngleTimeSeries ?? [],
                    unit: "°",
                    durationSeconds: duration,
                    playbackTime: max(playbackTime - analysisStart, 0),
                    isEstimate: true,
                    events: eventMarkers,
                    info: "Knee flexion angle over the full video duration. Cursor syncs with video playback."
                )
                
                // Hip Flexion
                GaitCycleGraphCard(
                    title: "Hip Flexion — Gait Cycle",
                    leftSeries: gait.leftHipAngle,
                    rightSeries: gait.rightHipAngle,
                    leftStd: gait.leftHipAngleStd,
                    rightStd: gait.rightHipAngleStd,
                    leftCycles: gait.leftHipCycles,
                    rightCycles: gait.rightHipCycles,
                    unit: "°",
                    stancePercent: stanceFallback,
                    isEstimate: true,
                    info: MetricInfo.gaitHip
                )
                TimeSeriesGraphCard(
                    title: "Hip Flexion — Time Series",
                    leftSeries: series?.leftHipAngleTimeSeries ?? [],
                    rightSeries: series?.rightHipAngleTimeSeries ?? [],
                    unit: "°",
                    durationSeconds: duration,
                    playbackTime: max(playbackTime - analysisStart, 0),
                    isEstimate: true,
                    events: eventMarkers,
                    info: "Hip flexion angle over the full video duration. Cursor syncs with video playback."
                )
                
                // Ankle Dorsiflexion
                GaitCycleGraphCard(
                    title: "Ankle Dorsiflexion — Gait Cycle",
                    leftSeries: gait.leftAnkleAngle,
                    rightSeries: gait.rightAnkleAngle,
                    leftStd: gait.leftAnkleAngleStd,
                    rightStd: gait.rightAnkleAngleStd,
                    leftCycles: gait.leftAnkleCycles,
                    rightCycles: gait.rightAnkleCycles,
                    unit: "°",
                    stancePercent: stanceFallback,
                    isEstimate: true,
                    info: MetricInfo.gaitAnkle
                )
                TimeSeriesGraphCard(
                    title: "Ankle Dorsiflexion — Time Series",
                    leftSeries: series?.leftAnkleAngleTimeSeries ?? [],
                    rightSeries: series?.rightAnkleAngleTimeSeries ?? [],
                    unit: "°",
                    durationSeconds: duration,
                    playbackTime: max(playbackTime - analysisStart, 0),
                    isEstimate: true,
                    events: eventMarkers,
                    info: "Ankle dorsiflexion over the full video duration. Cursor syncs with video playback."
                )
                
                // Foot height/velocity removed (angle-unsafe)
                PhasePlotCard(
                    title: "Knee Phase Plot (Angle vs Velocity)",
                    leftAngleSeries: series?.leftKneeAngleTimeSeries ?? [],
                    rightAngleSeries: series?.rightKneeAngleTimeSeries ?? [],
                    leftVelocitySeries: series?.leftKneeAngularVelocitySeries ?? [],
                    rightVelocitySeries: series?.rightKneeAngularVelocitySeries ?? [],
                    info: "Butterfly diagram of knee angle vs angular velocity. Smooth loops indicate stable gait cycles."
                )
                
                PhasePlotCard(
                    title: "Hip Phase Plot (Angle vs Velocity)",
                    leftAngleSeries: series?.leftHipAngleTimeSeries ?? [],
                    rightAngleSeries: series?.rightHipAngleTimeSeries ?? [],
                    leftVelocitySeries: series?.leftHipAngularVelocitySeries ?? [],
                    rightVelocitySeries: series?.rightHipAngularVelocitySeries ?? [],
                    info: "Butterfly diagram of hip angle vs angular velocity. Asymmetry can indicate imbalance."
                )
                
                SymmetryGraphCard(
                    title: "Knee Symmetry Index",
                    series: series?.kneeSymmetrySeries ?? [],
                    durationSeconds: duration,
                    events: eventMarkers,
                    info: "Left-right knee symmetry over time. Values beyond ±10% indicate asymmetry."
                )
                
                SymmetryGraphCard(
                    title: "GCT Symmetry Index",
                    series: series?.gctSymmetrySeries ?? [],
                    durationSeconds: duration,
                    events: eventMarkers,
                    info: "Ground contact time symmetry over time. Values beyond ±10% indicate imbalance."
                )
            }
            
            // Other time-based graphs
            GraphCard(title: "Cadence Over Time", series: series?.cadenceSeries ?? [], unit: "spm", durationSeconds: duration, events: eventMarkers, referenceBands: cadenceBands, info: MetricInfo.graphCadence)
            DualGraphCard(
                title: "Ground Contact Time (L/R)",
                leftSeries: series?.groundContactLeftSeries ?? [],
                rightSeries: series?.groundContactRightSeries ?? [],
                unit: "ms",
                durationSeconds: duration,
                events: eventMarkers,
                referenceBands: gctBands,
                info: MetricInfo.graphGCT
            )
            // Hip drop removed (angle-unsafe)
        }
    }

    private var formScoresSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Form Scores")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 20)
            
            ForEach(series?.formCueScores ?? []) { score in
                FormScoreCard(score: score, tip: FormCueTips.tips[score.cue] ?? "")
                    .padding(.horizontal, 20)
            }
        }
        .padding(.top, 10)
    }
    
    private func formatNumber(_ value: Double?, unit: String) -> String {
        guard let value = value else { return "—" }
        if unit == "body" {
            return String(format: "%.2f× body", value)
        }
        if unit == "spm" {
            return String(format: "%.0f spm", value)
        }
        return String(format: "%.1f %@", value, unit)
    }
}

private struct MetricGroup: View {
    let title: String
    let items: [MetricItem]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
                .padding(.horizontal, 20)
            
            VStack(spacing: 8) {
                ForEach(items) { item in
                    MetricRow(item: item)
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

private struct MetricRow: View {
    let item: MetricItem
    @State private var showInfo = false
    
    var body: some View {
        HStack {
            Text(item.title)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.85))
            
            if !item.info.isEmpty {
                Button(action: { showInfo = true }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            
            Spacer()
            Text(item.value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppTheme.accentColor.opacity(0.9))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05))
        .cornerRadius(10)
        .sheet(isPresented: $showInfo) {
            InfoSheet(title: item.title, description: item.info)
        }
    }
}

private struct InfoSheet: View {
    let title: String
    let description: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(description)
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.9))
                    .lineSpacing(4)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.bgColor)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(AppTheme.accentColor)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct MetricItem: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    let info: String
    
    init(_ title: String, _ value: String, info: String = "") {
        self.title = title
        self.value = value
        self.info = info
    }
}

// MARK: - Metric Explanations
private enum MetricInfo {
    static let cadence = "Steps per minute. Optimal: 170–180 spm for most runners. Higher cadence reduces impact forces and injury risk."
    static let groundContact = "Time your foot spends on the ground each step. Faster runners typically have 180–250ms. Longer times may indicate overstriding."
    static let verticalOscillation = "Vertical bounce during running. Lower is more efficient. Elite runners stay under 6%. High values waste energy."
    static let symmetry = "Balance between left and right sides. Aim for 95%+. Low symmetry may indicate muscle imbalance or injury compensation."
    static let trunkLean = "Forward lean angle of your torso. 5–15° is optimal. Too upright = inefficient, too forward = strain on lower back."
    static let hipDrop = "Pelvis tilt when one foot is off the ground. Aim for <5%. High hip drop often indicates weak hip abductors."
    static let armSwing = "Symmetry of arm movement. Arms should mirror each other. Imbalance can indicate tight muscles or poor coordination."
    static let kneeFlexion = "Range of knee bend during gait cycle. Running typically needs 40–60° during stance, more during swing."
    static let hipExtension = "Hip range behind the body at toe-off. Limited extension reduces stride efficiency and power."
    static let elbowRange = "Arm swing amplitude. Arms should swing naturally, elbows at ~90°. Overreaching wastes energy."
    
    static let graphCadence = "Shows step rate over the video duration. Smooth curves indicate steady rhythm. Sharp drops may be artifacts or actual pace changes."
    static let graphGCT = "Ground contact time for left (cyan) and right (green). Similar values = good symmetry. Spikes indicate harder landings."
    static let graphVerticalOsc = "Bounce magnitude over time. Consistent values show smooth gait. High peaks may indicate fatigue or terrain changes."
    static let graphKneeAngle = "Knee flexion throughout the video. Rhythmic waves follow your gait cycle. Flat sections = occlusion or tracking loss."
    static let graphHipDrop = "Pelvis tilt difference between left and right hip. Peaks occur at each stance phase."
    
    static let gaitKnee = "Knee angle through a normalized gait cycle (0–100%). Stance phase is shaded. Compare L/R for symmetry."
    static let gaitHip = "Hip flexion/extension through the gait cycle. Extension peaks near toe-off (~60%). Compare L/R for power symmetry."
    static let gaitAnkle = "Ankle dorsiflexion through the gait cycle. Positive = toes up, negative = pointed. Key for push-off power."
    static let gaitFootY = "Foot height (normalized to body) through gait cycle. Peaks show foot clearance during swing."
    static let gaitFootVel = "Foot velocity relative to pelvis. Zero-crossings help identify heel strike and toe-off events."
}

private enum FormCueTips {
    static let tips: [FormCue: String] = [
        .shinVertical: "Aim for a vertical shin at contact. Good range: −5° to +5°. Overstriding causes the foot to land too far ahead, increasing braking.",
        .quietFeet: "Quieter steps mean less braking. Good range: 0–0.08. Focus on landing softly under your hips.",
        .tallPosture: "Run tall with a slight forward lean from the ankles. Good range: 4–10°. Avoid bending at the waist.",
        .shortQuickSteps: "Slightly quicker steps reduce impact. Good range: 175–195 spm. Think light, fast cadence rather than long strides.",
        .footUnderCOM: "Land under your hips, not ahead. Good range: 0–0.06. This reduces braking forces.",
        .elbows: "Keep elbows near 90° and swing straight back. Good range: 80–100°. Avoid crossing hands in front of your body.",
        .hipsStable: "Stable hips reduce energy loss. Good range: 0–4%. Strengthen glutes to control hip drop.",
        .eyesForward: "Keep your gaze forward and head neutral. Good range: −5° to +5°. Looking down collapses posture and wastes energy."
    ]
}

private enum GaitEventType {
    case heelStrike
    case toeOff
}

private struct GaitEvent: Identifiable {
    let id = UUID()
    let time: Double
    let isLeft: Bool
    let type: GaitEventType
}

private struct ReferenceBand {
    let min: Double
    let max: Double
    let color: Color
}

private struct GraphBadge: View {
    let text: String
    let color: Color
    
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.black)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.9))
            .clipShape(Capsule())
    }
}

private struct GradientScoreBar: View {
    let score: Double
    let mean: Double
    let std: Double
    
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let clamped = min(max(score, 0), 100)
            let markerX = width * CGFloat(clamped / 100)
            let meanX = width * CGFloat(min(max(mean, 0), 100) / 100)
            let stdLeft = width * CGFloat(min(max(mean - std, 0), 100) / 100)
            let stdRight = width * CGFloat(min(max(mean + std, 0), 100) / 100)
            
            ZStack(alignment: .leading) {
                LinearGradient(
                    gradient: Gradient(colors: [.red, .yellow, .green]),
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: 10)
                .clipShape(Capsule())
                
                // SD band
                Rectangle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: max(stdRight - stdLeft, 0), height: 10)
                    .offset(x: stdLeft)
                    .clipShape(Capsule())
                
                // Score marker
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color.black.opacity(0.2), lineWidth: 1))
                    .offset(x: markerX - 5)
            }
        }
        .frame(height: 14)
    }
}

private struct FormScoreCard: View {
    let score: FormCueScore
    let tip: String
    @State private var showInfo = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(score.cue.rawValue)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                
                Button(action: { showInfo = true }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Text(String(format: "%.0f", score.score))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            }
            
            GradientScoreBar(score: score.score, mean: score.mean, std: score.std)
        }
        .padding(12)
        .background(Color.white.opacity(0.04))
        .cornerRadius(12)
        .sheet(isPresented: $showInfo) {
            InfoSheet(title: score.cue.rawValue, description: tip)
        }
    }
}
private struct GraphCard: View {
    let title: String
    let series: [Double]
    let unit: String
    let durationSeconds: Double
    var isAngleUnsafe: Bool = false
    var isEstimate: Bool = false
    var events: [GaitEvent] = []
    var referenceBands: [ReferenceBand] = []
    var info: String = ""
    @State private var showInfo = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                
                if isEstimate {
                    GraphBadge(text: "3D Estimate", color: .yellow)
                }
                
                if isAngleUnsafe {
                    GraphBadge(text: "Angle-unsafe", color: .orange)
                }
                
                if !info.isEmpty {
                    Button(action: { showInfo = true }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            
            GeometryReader { outerGeo in
                let containerWidth = outerGeo.size.width
                let scrollableWidth = max(containerWidth, CGFloat(durationSeconds) * 80)
                
                if series.isEmpty {
                    Text("No data")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.45))
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        SparklineView(
                            series: series,
                            color: AppTheme.accentColor,
                            unit: unit,
                            durationSeconds: durationSeconds,
                            referenceBands: referenceBands,
                            events: events
                        )
                        .frame(width: scrollableWidth)
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(height: 360)
        }
        .padding(.horizontal, 20)
        .sheet(isPresented: $showInfo) {
            InfoSheet(title: title, description: info)
        }
    }
}

private struct DualGraphCard: View {
    let title: String
    let leftSeries: [Double]
    let rightSeries: [Double]
    let unit: String
    let durationSeconds: Double
    var isAngleUnsafe: Bool = false
    var isEstimate: Bool = false
    var events: [GaitEvent] = []
    var referenceBands: [ReferenceBand] = []
    var info: String = ""
    @State private var showInfo = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                
                if isEstimate {
                    GraphBadge(text: "3D Estimate", color: .yellow)
                }
                
                if isAngleUnsafe {
                    GraphBadge(text: "Angle-unsafe", color: .orange)
                }
                
                if !info.isEmpty {
                    Button(action: { showInfo = true }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            
            GeometryReader { outerGeo in
                let containerWidth = outerGeo.size.width
                let scrollableWidth = max(containerWidth, CGFloat(durationSeconds) * 80)
                
                if leftSeries.isEmpty && rightSeries.isEmpty {
                    Text("No data")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.45))
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        ZStack {
                            if !leftSeries.isEmpty {
                                SparklineView(
                                    series: leftSeries,
                                    color: .cyan,
                                    unit: unit,
                                    durationSeconds: durationSeconds,
                                    referenceBands: referenceBands,
                                    events: events
                                )
                            }
                            if !rightSeries.isEmpty {
                                SparklineView(
                                    series: rightSeries,
                                    color: Color(red: 0, green: 1, blue: 0.5),
                                    attachAxes: false,
                                    unit: unit,
                                    durationSeconds: durationSeconds,
                                    events: []
                                )
                            }
                        }
                        .frame(width: scrollableWidth)
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(height: 360)
        }
        .padding(.horizontal, 20)
        .sheet(isPresented: $showInfo) {
            InfoSheet(title: title, description: info)
        }
    }
}

// MARK: - Time Series Graph with Video-Synced Cursor
private struct TimeSeriesGraphCard: View {
    let title: String
    let leftSeries: [Double]
    let rightSeries: [Double]
    let unit: String
    let durationSeconds: Double
    let playbackTime: Double
    var isAngleUnsafe: Bool = false
    var isEstimate: Bool = false
    var events: [GaitEvent] = []
    var info: String = ""
    @State private var showInfo = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                    
                    if isEstimate {
                        GraphBadge(text: "3D Estimate", color: .yellow)
                    }
                    
                    if isAngleUnsafe {
                        GraphBadge(text: "Angle-unsafe", color: .orange)
                    }
                    
                    if !info.isEmpty {
                        Button(action: { showInfo = true }) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
                HStack(spacing: 12) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 8, height: 8)
                        Text("Left")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(red: 0, green: 1, blue: 0.5))
                            .frame(width: 8, height: 8)
                        Text("Right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }
            
            GeometryReader { outerGeo in
                let containerWidth = outerGeo.size.width
                let scrollableWidth = max(containerWidth, CGFloat(durationSeconds) * 80)
                
                if leftSeries.isEmpty && rightSeries.isEmpty {
                    Text("No data")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.45))
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        TimeSeriesSparklineView(
                            leftSeries: leftSeries,
                            rightSeries: rightSeries,
                            unit: unit,
                            durationSeconds: durationSeconds,
                            playbackTime: playbackTime,
                            events: events,
                            containerWidth: containerWidth
                        )
                        .frame(width: scrollableWidth)
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(height: 360)
        }
        .padding(.horizontal, 20)
        .sheet(isPresented: $showInfo) {
            InfoSheet(title: title, description: info)
        }
    }
}

private struct TimeSeriesSparklineView: View {
    let leftSeries: [Double]
    let rightSeries: [Double]
    let unit: String
    let durationSeconds: Double
    let playbackTime: Double
    let events: [GaitEvent]
    let containerWidth: CGFloat
    
    var body: some View {
        GeometryReader { geo in
            let values = leftSeries + rightSeries
            let minVal = values.min() ?? 0
            let maxVal = values.max() ?? 1
            let range = max(maxVal - minVal, 0.0001)
            let plotInset = EdgeInsets(top: 24, leading: 70, bottom: 55, trailing: 16)
            let plotWidth = geo.size.width - plotInset.leading - plotInset.trailing
            let plotHeight = geo.size.height - plotInset.top - plotInset.bottom
            let leftStep = plotWidth / CGFloat(max(leftSeries.count - 1, 1))
            let rightStep = plotWidth / CGFloat(max(rightSeries.count - 1, 1))
            let totalSeconds = max(durationSeconds, 0.001)
            let cursorPercent = min(max(playbackTime / totalSeconds, 0), 1)
            
            ZStack {
                // Gridlines
                Path { path in
                    let horizontalLines = 4
                    let verticalLines = 4
                    for i in 0...horizontalLines {
                        let y = plotInset.top + (plotHeight / CGFloat(horizontalLines)) * CGFloat(i)
                        path.move(to: CGPoint(x: plotInset.leading, y: y))
                        path.addLine(to: CGPoint(x: plotInset.leading + plotWidth, y: y))
                    }
                    for i in 0...verticalLines {
                        let x = plotInset.leading + (plotWidth / CGFloat(verticalLines)) * CGFloat(i)
                        path.move(to: CGPoint(x: x, y: plotInset.top))
                        path.addLine(to: CGPoint(x: x, y: plotInset.top + plotHeight))
                    }
                }
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                
                // Axes
                Path { path in
                    path.move(to: CGPoint(x: plotInset.leading, y: plotInset.top))
                    path.addLine(to: CGPoint(x: plotInset.leading, y: plotInset.top + plotHeight))
                    path.addLine(to: CGPoint(x: plotInset.leading + plotWidth, y: plotInset.top + plotHeight))
                }
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                
                // Event markers (HS/TO)
                ForEach(events) { event in
                    let x = plotInset.leading + plotWidth * CGFloat(min(max(event.time / totalSeconds, 0), 1))
                    Path { path in
                        path.move(to: CGPoint(x: x, y: plotInset.top))
                        path.addLine(to: CGPoint(x: x, y: plotInset.top + plotHeight))
                    }
                    .stroke(
                        event.isLeft ? Color.cyan.opacity(0.7) : Color(red: 0, green: 1, blue: 0.5).opacity(0.7),
                        style: StrokeStyle(lineWidth: 1.5, dash: event.type == .toeOff ? [4, 4] : [])
                    )
                    
                    Text(event.type == .heelStrike ? "HS" : "TO")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(event.isLeft ? Color.cyan.opacity(0.8) : Color(red: 0, green: 1, blue: 0.5).opacity(0.8))
                        .position(x: x + 10, y: plotInset.top + 10)
                }
                
                // Left series line
                if !leftSeries.isEmpty {
                    Path { path in
                        for idx in leftSeries.indices {
                            let x = plotInset.leading + CGFloat(idx) * leftStep
                            let normalized = (leftSeries[idx] - minVal) / range
                            let y = plotInset.top + plotHeight - (CGFloat(normalized) * plotHeight)
                            if idx == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(Color.cyan, lineWidth: 2.5)
                }
                
                // Right series line
                if !rightSeries.isEmpty {
                    Path { path in
                        for idx in rightSeries.indices {
                            let x = plotInset.leading + CGFloat(idx) * rightStep
                            let normalized = (rightSeries[idx] - minVal) / range
                            let y = plotInset.top + plotHeight - (CGFloat(normalized) * plotHeight)
                            if idx == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(Color(red: 0, green: 1, blue: 0.5), lineWidth: 2.5)
                }
                
                // Video-synced cursor
                let cursorX = plotInset.leading + plotWidth * CGFloat(cursorPercent)
                Path { path in
                    path.move(to: CGPoint(x: cursorX, y: plotInset.top))
                    path.addLine(to: CGPoint(x: cursorX, y: plotInset.top + plotHeight))
                }
                .stroke(Color.white, lineWidth: 2)
                
                // Y-axis labels
                VStack(alignment: .leading, spacing: 0) {
                    Text(formatValue(maxVal))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Text(formatValue((maxVal + minVal) / 2))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                    Text(formatValue(minVal))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }
                .frame(width: 60, alignment: .trailing)
                .padding(.top, plotInset.top)
                .padding(.bottom, plotInset.bottom)
                .padding(.leading, 4)
                
                // X-axis labels (time in seconds) - dynamic based on duration
                VStack {
                    Spacer()
                    HStack(spacing: 0) {
                    let labelCount = max(Int(totalSeconds / 2) + 1, 3) // Label every 2 seconds, minimum 3 labels
                    let cappedLabels = min(labelCount, 7) // Cap at 7 labels to avoid overlap
                        ForEach(0..<cappedLabels, id: \.self) { i in
                            let time = totalSeconds * Double(i) / Double(cappedLabels - 1)
                            Text(timeLabel(time))
                                .font(.system(size: 11, weight: i == 0 || i == cappedLabels - 1 ? .medium : .regular))
                                .foregroundColor(.white.opacity(i == 0 || i == cappedLabels - 1 ? 0.8 : 0.6))
                            if i < cappedLabels - 1 {
                                Spacer()
                            }
                        }
                    }
                    .padding(.leading, plotInset.leading)
                    .padding(.trailing, plotInset.trailing)
                    .padding(.bottom, 8)
                    
                    Text("Time (s)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.bottom, 4)
                }
                
                // Y-axis title
                VStack {
                    Text(unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .rotationEffect(.degrees(-90))
                        .fixedSize()
                    Spacer()
                }
                .frame(width: 20)
                .padding(.top, plotInset.top + 20)
            }
        }
    }
    
    private func formatValue(_ value: Double) -> String {
        switch unit {
        case "spm":
            return String(format: "%.0f", value)
        case "ms":
            return String(format: "%.0f", value)
        case "%":
            return String(format: "%.1f%%", value)
        case "°":
            return String(format: "%.0f°", value)
        case "body":
            return String(format: "%.2f", value)
        case "body/s":
            return String(format: "%.2f", value)
        default:
            return String(format: "%.2f", value)
        }
    }
    
    private func timeLabel(_ seconds: Double) -> String {
        if seconds >= 60 {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(mins)m \(secs)s"
        }
        return String(format: "%.1fs", seconds)
    }
}

private struct SymmetryGraphCard: View {
    let title: String
    let series: [Double]
    let durationSeconds: Double
    var events: [GaitEvent] = []
    var info: String = ""
    @State private var showInfo = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                
                if !info.isEmpty {
                    Button(action: { showInfo = true }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            
            GeometryReader { outerGeo in
                let containerWidth = outerGeo.size.width
                let scrollableWidth = max(containerWidth, CGFloat(durationSeconds) * 80)
                
                if series.isEmpty {
                    Text("No data")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.45))
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        SymmetrySparklineView(series: series, durationSeconds: durationSeconds, events: events)
                            .frame(width: scrollableWidth)
                            .padding(.vertical, 8)
                    }
                }
            }
            .frame(height: 360)
        }
        .padding(.horizontal, 20)
        .sheet(isPresented: $showInfo) {
            InfoSheet(title: title, description: info)
        }
    }
}

private struct SymmetrySparklineView: View {
    let series: [Double]
    let durationSeconds: Double
    let events: [GaitEvent]
    
    var body: some View {
        GeometryReader { geo in
            let values = series.count == 1 ? [series[0], series[0]] : series
            let minVal = min(values.min() ?? -10, -10)
            let maxVal = max(values.max() ?? 10, 10)
            let range = max(maxVal - minVal, 0.0001)
            let plotInset = EdgeInsets(top: 24, leading: 70, bottom: 50, trailing: 16)
            let plotWidth = geo.size.width - plotInset.leading - plotInset.trailing
            let plotHeight = geo.size.height - plotInset.top - plotInset.bottom
            let step = plotWidth / CGFloat(max(values.count - 1, 1))
            let totalSeconds = max(durationSeconds, 0)
            
            ZStack {
                // Gridlines and axes
                Path { path in
                    let horizontalLines = 4
                    let verticalLines = 4
                    for i in 0...horizontalLines {
                        let y = plotInset.top + (plotHeight / CGFloat(horizontalLines)) * CGFloat(i)
                        path.move(to: CGPoint(x: plotInset.leading, y: y))
                        path.addLine(to: CGPoint(x: plotInset.leading + plotWidth, y: y))
                    }
                    for i in 0...verticalLines {
                        let x = plotInset.leading + (plotWidth / CGFloat(verticalLines)) * CGFloat(i)
                        path.move(to: CGPoint(x: x, y: plotInset.top))
                        path.addLine(to: CGPoint(x: x, y: plotInset.top + plotHeight))
                    }
                }
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                
                // Zero line
                let zeroY = plotInset.top + plotHeight - (CGFloat((0 - minVal) / range) * plotHeight)
                Path { path in
                    path.move(to: CGPoint(x: plotInset.leading, y: zeroY))
                    path.addLine(to: CGPoint(x: plotInset.leading + plotWidth, y: zeroY))
                }
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
                
                // Asymmetry highlight (>10%)
                Path { path in
                    for idx in values.indices {
                        if abs(values[idx]) >= 10 {
                            let x = plotInset.leading + CGFloat(idx) * step
                            path.move(to: CGPoint(x: x, y: plotInset.top))
                            path.addLine(to: CGPoint(x: x, y: plotInset.top + plotHeight))
                        }
                    }
                }
                .stroke(Color.red.opacity(0.25), lineWidth: 1)
                
                // Event markers
                ForEach(events) { event in
                    let x = plotInset.leading + plotWidth * CGFloat(min(max(event.time / max(totalSeconds, 0.001), 0), 1))
                    Path { path in
                        path.move(to: CGPoint(x: x, y: plotInset.top))
                        path.addLine(to: CGPoint(x: x, y: plotInset.top + plotHeight))
                    }
                    .stroke(
                        event.isLeft ? Color.cyan.opacity(0.6) : Color(red: 0, green: 1, blue: 0.5).opacity(0.6),
                        style: StrokeStyle(lineWidth: 1.2, dash: event.type == .toeOff ? [4, 4] : [])
                    )
                }
                
                // Series line
                Path { path in
                    for idx in values.indices {
                        let x = plotInset.leading + CGFloat(idx) * step
                        let normalized = (values[idx] - minVal) / range
                        let y = plotInset.top + plotHeight - (CGFloat(normalized) * plotHeight)
                        if idx == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(Color.white, lineWidth: 2)
                
                // Axis labels
                VStack(alignment: .leading, spacing: 0) {
                    Text(String(format: "%.0f%%", maxVal))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Text("0%")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                    Text(String(format: "%.0f%%", minVal))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }
                .frame(width: 60, alignment: .trailing)
                .padding(.top, plotInset.top)
                .padding(.bottom, plotInset.bottom)
                .padding(.leading, 4)
                
                VStack {
                    Spacer()
                    HStack {
                        Text(timeLabel(0))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        Text(timeLabel(totalSeconds / 2))
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.6))
                        Spacer()
                        Text(timeLabel(totalSeconds))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.leading, plotInset.leading)
                    .padding(.trailing, plotInset.trailing)
                    .padding(.bottom, 6)
                    
                    Text("Time (s)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.bottom, 4)
                }
                
                VStack {
                    Text("%")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .rotationEffect(.degrees(-90))
                        .fixedSize()
                    Spacer()
                }
                .frame(width: 20)
                .padding(.top, plotInset.top + 20)
            }
        }
    }
    
    private func timeLabel(_ seconds: Double) -> String {
        if seconds >= 60 {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(mins)m \(secs)s"
        }
        return "\(Int(seconds))s"
    }
}

private struct PhasePlotCard: View {
    let title: String
    let leftAngleSeries: [Double]
    let rightAngleSeries: [Double]
    let leftVelocitySeries: [Double]
    let rightVelocitySeries: [Double]
    var info: String = ""
    @State private var showInfo = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                
                if !info.isEmpty {
                    Button(action: { showInfo = true }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            
            GeometryReader { outerGeo in
                let containerWidth = outerGeo.size.width
                let scrollableWidth = max(containerWidth, 900)
                
                if leftAngleSeries.isEmpty && rightAngleSeries.isEmpty {
                    Text("No data")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.45))
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        PhasePlotView(
                            leftAngleSeries: leftAngleSeries,
                            rightAngleSeries: rightAngleSeries,
                            leftVelocitySeries: leftVelocitySeries,
                            rightVelocitySeries: rightVelocitySeries
                        )
                        .frame(width: scrollableWidth)
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(height: 360)
        }
        .padding(.horizontal, 20)
        .sheet(isPresented: $showInfo) {
            InfoSheet(title: title, description: info)
        }
    }
}

private struct PhasePlotView: View {
    let leftAngleSeries: [Double]
    let rightAngleSeries: [Double]
    let leftVelocitySeries: [Double]
    let rightVelocitySeries: [Double]
    
    var body: some View {
        GeometryReader { geo in
            let angleValues = leftAngleSeries + rightAngleSeries
            let velocityValues = leftVelocitySeries + rightVelocitySeries
            let minAngle = angleValues.min() ?? 0
            let maxAngle = angleValues.max() ?? 1
            let minVel = velocityValues.min() ?? -1
            let maxVel = velocityValues.max() ?? 1
            let angleRange = max(maxAngle - minAngle, 0.0001)
            let velRange = max(maxVel - minVel, 0.0001)
            let plotInset = EdgeInsets(top: 24, leading: 70, bottom: 50, trailing: 16)
            let plotWidth = geo.size.width - plotInset.leading - plotInset.trailing
            let plotHeight = geo.size.height - plotInset.top - plotInset.bottom
            
            ZStack {
                // Gridlines
                Path { path in
                    let horizontalLines = 4
                    let verticalLines = 4
                    for i in 0...horizontalLines {
                        let y = plotInset.top + (plotHeight / CGFloat(horizontalLines)) * CGFloat(i)
                        path.move(to: CGPoint(x: plotInset.leading, y: y))
                        path.addLine(to: CGPoint(x: plotInset.leading + plotWidth, y: y))
                    }
                    for i in 0...verticalLines {
                        let x = plotInset.leading + (plotWidth / CGFloat(verticalLines)) * CGFloat(i)
                        path.move(to: CGPoint(x: x, y: plotInset.top))
                        path.addLine(to: CGPoint(x: x, y: plotInset.top + plotHeight))
                    }
                }
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                
                // Axes
                Path { path in
                    path.move(to: CGPoint(x: plotInset.leading, y: plotInset.top))
                    path.addLine(to: CGPoint(x: plotInset.leading, y: plotInset.top + plotHeight))
                    path.addLine(to: CGPoint(x: plotInset.leading + plotWidth, y: plotInset.top + plotHeight))
                }
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                
                if !leftAngleSeries.isEmpty, !leftVelocitySeries.isEmpty {
                    Path { path in
                        let count = min(leftAngleSeries.count, leftVelocitySeries.count)
                        for i in 0..<count {
                            let xVal = (leftAngleSeries[i] - minAngle) / angleRange
                            let yVal = (leftVelocitySeries[i] - minVel) / velRange
                            let x = plotInset.leading + CGFloat(xVal) * plotWidth
                            let y = plotInset.top + plotHeight - CGFloat(yVal) * plotHeight
                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(Color.cyan, lineWidth: 2)
                }
                
                if !rightAngleSeries.isEmpty, !rightVelocitySeries.isEmpty {
                    Path { path in
                        let count = min(rightAngleSeries.count, rightVelocitySeries.count)
                        for i in 0..<count {
                            let xVal = (rightAngleSeries[i] - minAngle) / angleRange
                            let yVal = (rightVelocitySeries[i] - minVel) / velRange
                            let x = plotInset.leading + CGFloat(xVal) * plotWidth
                            let y = plotInset.top + plotHeight - CGFloat(yVal) * plotHeight
                            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                    }
                    .stroke(Color(red: 0, green: 1, blue: 0.5), lineWidth: 2)
                }
                
                // Axis labels
                VStack(alignment: .leading, spacing: 0) {
                    Text(String(format: "%.0f°/s", maxVel))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Text(String(format: "%.0f°/s", minVel))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }
                .frame(width: 60, alignment: .trailing)
                .padding(.top, plotInset.top)
                .padding(.bottom, plotInset.bottom)
                .padding(.leading, 4)
                
                VStack {
                    Spacer()
                    HStack {
                        Text(String(format: "%.0f°", minAngle))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        Text(String(format: "%.0f°", maxAngle))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.leading, plotInset.leading)
                    .padding(.trailing, plotInset.trailing)
                    .padding(.bottom, 6)
                    
                    Text("Angle (°)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.bottom, 4)
                }
                
                VStack {
                    Text("Velocity (°/s)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .rotationEffect(.degrees(-90))
                        .fixedSize()
                    Spacer()
                }
                .frame(width: 20)
                .padding(.top, plotInset.top + 20)
            }
        }
    }
}

private struct GaitCycleGraphCard: View {
    let title: String
    let leftSeries: [Double]
    let rightSeries: [Double]
    let leftStd: [Double]
    let rightStd: [Double]
    let leftCycles: [[Double]]
    let rightCycles: [[Double]]
    let unit: String
    let stancePercent: Double
    var isEstimate: Bool = false
    var isAngleUnsafe: Bool = false
    var info: String = ""
    @State private var showInfo = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                    
                    if isEstimate {
                        GraphBadge(text: "3D Estimate", color: .yellow)
                    }
                    
                    if isAngleUnsafe {
                        GraphBadge(text: "Angle-unsafe", color: .orange)
                    }
                    
                    if !info.isEmpty {
                        Button(action: { showInfo = true }) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
                HStack(spacing: 12) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 8, height: 8)
                        Text("Left")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Color(red: 0, green: 1, blue: 0.5))
                            .frame(width: 8, height: 8)
                        Text("Right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
            }
            
            GeometryReader { outerGeo in
                let containerWidth = outerGeo.size.width
                let scrollableWidth = max(containerWidth, 900)
                
                if leftSeries.isEmpty && rightSeries.isEmpty {
                    Text("No data")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.45))
                } else {
                    ScrollView(.horizontal, showsIndicators: true) {
                        GaitCycleSparklineView(
                            leftSeries: leftSeries,
                            rightSeries: rightSeries,
                            leftStd: leftStd,
                            rightStd: rightStd,
                            leftCycles: leftCycles,
                            rightCycles: rightCycles,
                            unit: unit,
                            stancePercent: stancePercent
                        )
                        .frame(width: scrollableWidth)
                        .padding(.vertical, 8)
                    }
                }
            }
            .frame(height: 360)
        }
        .padding(.horizontal, 20)
        .sheet(isPresented: $showInfo) {
            InfoSheet(title: title, description: info)
        }
    }
}

private struct SparklineView: View {
    let series: [Double]
    let color: Color
    var attachAxes: Bool = true
    let unit: String
    let durationSeconds: Double
    var referenceBands: [ReferenceBand] = []
    var events: [GaitEvent] = []
    
    var body: some View {
        GeometryReader { geo in
            let values = series.count == 1 ? [series[0], series[0]] : series
            let minVal = values.min() ?? 0
            let maxVal = values.max() ?? 1
            let range = max(maxVal - minVal, 0.0001)
            // Increased insets for larger labels
            let plotInset = EdgeInsets(top: 24, leading: 70, bottom: 50, trailing: 16)
            let plotWidth = geo.size.width - plotInset.leading - plotInset.trailing
            let plotHeight = geo.size.height - plotInset.top - plotInset.bottom
            let step = plotWidth / CGFloat(max(values.count - 1, 1))
            let totalSeconds = max(durationSeconds, 0)
            let midSeconds = totalSeconds / 2
            
            ZStack {
                if attachAxes {
                    // Gridlines
                    Path { path in
                        let horizontalLines = 4
                        let verticalLines = 4
                        for i in 0...horizontalLines {
                            let y = plotInset.top + (plotHeight / CGFloat(horizontalLines)) * CGFloat(i)
                            path.move(to: CGPoint(x: plotInset.leading, y: y))
                            path.addLine(to: CGPoint(x: plotInset.leading + plotWidth, y: y))
                        }
                        for i in 0...verticalLines {
                            let x = plotInset.leading + (plotWidth / CGFloat(verticalLines)) * CGFloat(i)
                            path.move(to: CGPoint(x: x, y: plotInset.top))
                            path.addLine(to: CGPoint(x: x, y: plotInset.top + plotHeight))
                        }
                    }
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    
                    // Axes
                    Path { path in
                        path.move(to: CGPoint(x: plotInset.leading, y: plotInset.top))
                        path.addLine(to: CGPoint(x: plotInset.leading, y: plotInset.top + plotHeight))
                        path.addLine(to: CGPoint(x: plotInset.leading + plotWidth, y: plotInset.top + plotHeight))
                    }
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
                }
                
                if attachAxes, !referenceBands.isEmpty {
                    ForEach(0..<referenceBands.count, id: \.self) { index in
                        let band = referenceBands[index]
                        let clampedMin = min(max(band.min, minVal), maxVal)
                        let clampedMax = min(max(band.max, minVal), maxVal)
                        let yMax = plotInset.top + plotHeight - (CGFloat((clampedMax - minVal) / range) * plotHeight)
                        let yMin = plotInset.top + plotHeight - (CGFloat((clampedMin - minVal) / range) * plotHeight)
                        Rectangle()
                            .fill(band.color.opacity(0.12))
                            .frame(width: plotWidth, height: max(yMin - yMax, 0))
                            .position(x: plotInset.leading + plotWidth / 2, y: yMax + (yMin - yMax) / 2)
                    }
                }
                
                // Event markers (HS/TO)
                if attachAxes {
                    ForEach(events) { event in
                        let x = plotInset.leading + plotWidth * CGFloat(min(max(event.time / max(totalSeconds, 0.001), 0), 1))
                        Path { path in
                            path.move(to: CGPoint(x: x, y: plotInset.top))
                            path.addLine(to: CGPoint(x: x, y: plotInset.top + plotHeight))
                        }
                        .stroke(
                            event.isLeft ? Color.cyan.opacity(0.6) : Color(red: 0, green: 1, blue: 0.5).opacity(0.6),
                            style: StrokeStyle(lineWidth: 1.2, dash: event.type == .toeOff ? [4, 4] : [])
                        )
                    }
                }
                
                // Series line
                Path { path in
                    for idx in values.indices {
                        let x = plotInset.leading + CGFloat(idx) * step
                        let normalized = (values[idx] - minVal) / range
                        let y = plotInset.top + plotHeight - (CGFloat(normalized) * plotHeight)
                        if idx == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(color, lineWidth: 2)
                
                if attachAxes {
                    // Y-axis labels (min/mid/max) - positioned on left side
                    VStack(alignment: .leading, spacing: 0) {
                        Text(formatValue(maxVal))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        Text(formatValue((maxVal + minVal) / 2))
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.6))
                        Spacer()
                        Text(formatValue(minVal))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .frame(width: 60, alignment: .trailing)
                    .padding(.top, plotInset.top)
                    .padding(.bottom, plotInset.bottom)
                    .padding(.leading, 4)
                    
                    // X-axis labels (actual time) - positioned at bottom
                    VStack {
                        Spacer()
                        HStack {
                            Text(timeLabel(0))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                            Spacer()
                            Text(timeLabel(midSeconds))
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.6))
                            Spacer()
                            Text(timeLabel(totalSeconds))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .padding(.leading, plotInset.leading)
                        .padding(.trailing, plotInset.trailing)
                        .padding(.bottom, 6)
                        
                        // X-axis title
                        Text("Time (s)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.bottom, 4)
                    }
                    
                    // Y-axis title - rotated on the left
                    VStack {
                        Text(unit)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                            .rotationEffect(.degrees(-90))
                            .fixedSize()
                        Spacer()
                    }
                    .frame(width: 20)
                    .padding(.top, plotInset.top + 20)
                }
            }
        }
    }
    
    private func formatValue(_ value: Double) -> String {
        switch unit {
        case "spm":
            return String(format: "%.0f spm", value)
        case "ms":
            return String(format: "%.0f ms", value)
        case "%":
            return String(format: "%.1f%%", value)
        case "°":
            return String(format: "%.0f°", value)
        case "body":
            return String(format: "%.2f× body", value)
        default:
            return String(format: "%.1f %@", value, unit)
        }
    }
    
    private func timeLabel(_ seconds: Double) -> String {
        if seconds >= 60 {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return "\(mins)m \(secs)s"
        }
        return "\(Int(seconds))s"
    }
}

private struct GaitCycleSparklineView: View {
    let leftSeries: [Double]
    let rightSeries: [Double]
    let leftStd: [Double]
    let rightStd: [Double]
    let leftCycles: [[Double]]
    let rightCycles: [[Double]]
    let unit: String
    let stancePercent: Double
    
    var body: some View {
        GeometryReader { geo in
            let values = leftSeries + rightSeries
            let minVal = values.min() ?? 0
            let maxVal = values.max() ?? 1
            let range = max(maxVal - minVal, 0.0001)
            // Larger insets for bigger labels
            let plotInset = EdgeInsets(top: 24, leading: 70, bottom: 55, trailing: 16)
            let plotWidth = geo.size.width - plotInset.leading - plotInset.trailing
            let plotHeight = geo.size.height - plotInset.top - plotInset.bottom
            let leftStep = plotWidth / CGFloat(max(leftSeries.count - 1, 1))
            let rightStep = plotWidth / CGFloat(max(rightSeries.count - 1, 1))
            
            ZStack {
                // Stance shading
                if stancePercent > 0 {
                    let stanceWidth = plotWidth * CGFloat(min(max(stancePercent, 0), 100)) / 100
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: stanceWidth, height: plotHeight)
                        .position(x: plotInset.leading + stanceWidth / 2, y: plotInset.top + plotHeight / 2)
                }
                
                // Gridlines
                Path { path in
                    let horizontalLines = 4
                    let verticalLines = 4
                    for i in 0...horizontalLines {
                        let y = plotInset.top + (plotHeight / CGFloat(horizontalLines)) * CGFloat(i)
                        path.move(to: CGPoint(x: plotInset.leading, y: y))
                        path.addLine(to: CGPoint(x: plotInset.leading + plotWidth, y: y))
                    }
                    for i in 0...verticalLines {
                        let x = plotInset.leading + (plotWidth / CGFloat(verticalLines)) * CGFloat(i)
                        path.move(to: CGPoint(x: x, y: plotInset.top))
                        path.addLine(to: CGPoint(x: x, y: plotInset.top + plotHeight))
                    }
                }
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                
                // Axes
                Path { path in
                    path.move(to: CGPoint(x: plotInset.leading, y: plotInset.top))
                    path.addLine(to: CGPoint(x: plotInset.leading, y: plotInset.top + plotHeight))
                    path.addLine(to: CGPoint(x: plotInset.leading + plotWidth, y: plotInset.top + plotHeight))
                }
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                
                // Left cycle overlays
                ForEach(0..<leftCycles.count, id: \.self) { cycleIdx in
                    let cycle = leftCycles[cycleIdx]
                    if !cycle.isEmpty {
                        Path { path in
                            let step = plotWidth / CGFloat(max(cycle.count - 1, 1))
                            for idx in cycle.indices {
                                let x = plotInset.leading + CGFloat(idx) * step
                                let normalized = (cycle[idx] - minVal) / range
                                let y = plotInset.top + plotHeight - (CGFloat(normalized) * plotHeight)
                                if idx == 0 {
                                    path.move(to: CGPoint(x: x, y: y))
                                } else {
                                    path.addLine(to: CGPoint(x: x, y: y))
                                }
                            }
                        }
                        .stroke(Color.cyan.opacity(0.2), lineWidth: 1)
                    }
                }
                
                // Left SD band
                if leftSeries.count == leftStd.count, !leftSeries.isEmpty {
                    Path { path in
                        let step = plotWidth / CGFloat(max(leftSeries.count - 1, 1))
                        for idx in leftSeries.indices {
                            let x = plotInset.leading + CGFloat(idx) * step
                            let upper = leftSeries[idx] + leftStd[idx]
                            let normalized = (upper - minVal) / range
                            let y = plotInset.top + plotHeight - (CGFloat(normalized) * plotHeight)
                            if idx == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        for idx in leftSeries.indices.reversed() {
                            let x = plotInset.leading + CGFloat(idx) * step
                            let lower = leftSeries[idx] - leftStd[idx]
                            let normalized = (lower - minVal) / range
                            let y = plotInset.top + plotHeight - (CGFloat(normalized) * plotHeight)
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        path.closeSubpath()
                    }
                    .fill(Color.cyan.opacity(0.12))
                }
                
                // Left mean line
                if !leftSeries.isEmpty {
                    Path { path in
                        for idx in leftSeries.indices {
                            let x = plotInset.leading + CGFloat(idx) * leftStep
                            let normalized = (leftSeries[idx] - minVal) / range
                            let y = plotInset.top + plotHeight - (CGFloat(normalized) * plotHeight)
                            if idx == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(Color.cyan, lineWidth: 2.5)
                }
                
                // Right cycle overlays
                ForEach(0..<rightCycles.count, id: \.self) { cycleIdx in
                    let cycle = rightCycles[cycleIdx]
                    if !cycle.isEmpty {
                        Path { path in
                            let step = plotWidth / CGFloat(max(cycle.count - 1, 1))
                            for idx in cycle.indices {
                                let x = plotInset.leading + CGFloat(idx) * step
                                let normalized = (cycle[idx] - minVal) / range
                                let y = plotInset.top + plotHeight - (CGFloat(normalized) * plotHeight)
                                if idx == 0 {
                                    path.move(to: CGPoint(x: x, y: y))
                                } else {
                                    path.addLine(to: CGPoint(x: x, y: y))
                                }
                            }
                        }
                        .stroke(Color(red: 0, green: 1, blue: 0.5).opacity(0.2), lineWidth: 1)
                    }
                }
                
                // Right SD band
                if rightSeries.count == rightStd.count, !rightSeries.isEmpty {
                    Path { path in
                        let step = plotWidth / CGFloat(max(rightSeries.count - 1, 1))
                        for idx in rightSeries.indices {
                            let x = plotInset.leading + CGFloat(idx) * step
                            let upper = rightSeries[idx] + rightStd[idx]
                            let normalized = (upper - minVal) / range
                            let y = plotInset.top + plotHeight - (CGFloat(normalized) * plotHeight)
                            if idx == 0 { path.move(to: CGPoint(x: x, y: y)) }
                            else { path.addLine(to: CGPoint(x: x, y: y)) }
                        }
                        for idx in rightSeries.indices.reversed() {
                            let x = plotInset.leading + CGFloat(idx) * step
                            let lower = rightSeries[idx] - rightStd[idx]
                            let normalized = (lower - minVal) / range
                            let y = plotInset.top + plotHeight - (CGFloat(normalized) * plotHeight)
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                        path.closeSubpath()
                    }
                    .fill(Color(red: 0, green: 1, blue: 0.5).opacity(0.12))
                }
                
                // Right mean line
                if !rightSeries.isEmpty {
                    Path { path in
                        for idx in rightSeries.indices {
                            let x = plotInset.leading + CGFloat(idx) * rightStep
                            let normalized = (rightSeries[idx] - minVal) / range
                            let y = plotInset.top + plotHeight - (CGFloat(normalized) * plotHeight)
                            if idx == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(Color(red: 0, green: 1, blue: 0.5), lineWidth: 2.5)
                }
                
                // Y-axis labels - positioned on left side
                VStack(alignment: .leading, spacing: 0) {
                    Text(formatValue(maxVal))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                    Spacer()
                    Text(formatValue((maxVal + minVal) / 2))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                    Text(formatValue(minVal))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                }
                .frame(width: 60, alignment: .trailing)
                .padding(.top, plotInset.top)
                .padding(.bottom, plotInset.bottom)
                .padding(.leading, 4)
                
                // X-axis labels - positioned at bottom
                VStack {
                    Spacer()
                    HStack {
                        Text("0%")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        Text("25%")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.6))
                        Spacer()
                        Text("50%")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                        Spacer()
                        Text("75%")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.6))
                        Spacer()
                        Text("100%")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.leading, plotInset.leading)
                    .padding(.trailing, plotInset.trailing)
                    .padding(.bottom, 8)
                    
                    // X-axis title
                    Text("Gait Cycle (%)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.bottom, 4)
                }
                
                // Y-axis title - rotated on the left
                VStack {
                    Text(unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .rotationEffect(.degrees(-90))
                        .fixedSize()
                    Spacer()
                }
                .frame(width: 20)
                .padding(.top, plotInset.top + 20)
            }
        }
    }
    
    private func formatValue(_ value: Double) -> String {
        switch unit {
        case "spm":
            return String(format: "%.0f spm", value)
        case "ms":
            return String(format: "%.0f ms", value)
        case "%":
            return String(format: "%.1f%%", value)
        case "°":
            return String(format: "%.0f°", value)
        case "body":
            return String(format: "%.2f× body", value)
        case "body/s":
            return String(format: "%.2f body/s", value)
        default:
            return String(format: "%.2f %@", value, unit)
        }
    }
}

// MARK: - Radar Chart View
struct RadarChartView: View {
    private let labels = ["Cadence", "Arms", "Posture", "Stride", "Knees", "Hips"]
    private let values: [CGFloat] = [0.85, 0.75, 0.9, 0.8, 0.65, 0.7] // Normalized 0-1
    
    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let radius = min(geometry.size.width, geometry.size.height) / 2 - 20
            
            ZStack {
                // Grid lines (3 levels)
                ForEach([1.0, 0.66, 0.33], id: \.self) { scale in
                    RadarPolygon(sides: 6, scale: scale)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                        .frame(width: radius * 2 * scale, height: radius * 2 * scale)
                }
                
                // Axis lines
                ForEach(0..<6, id: \.self) { index in
                    let angle = (CGFloat(index) / 6) * 2 * .pi - .pi / 2
                    Path { path in
                        path.move(to: center)
                        path.addLine(to: CGPoint(
                            x: center.x + cos(angle) * radius,
                            y: center.y + sin(angle) * radius
                        ))
                    }
                    .stroke(Color.white.opacity(0.04), lineWidth: 1)
                }
                
                // Data shape
                RadarDataShape(values: values, radius: radius, center: center)
                    .fill(AppTheme.accentColor.opacity(0.15))
                    .overlay(
                        RadarDataShape(values: values, radius: radius, center: center)
                            .stroke(AppTheme.accentColor, lineWidth: 1.5)
                    )
                
                // Labels
                ForEach(0..<6, id: \.self) { index in
                    let angle = (CGFloat(index) / 6) * 2 * .pi - .pi / 2
                    let labelRadius = radius + 15
                    Text(labels[index])
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.35))
                        .position(
                            x: center.x + cos(angle) * labelRadius,
                            y: center.y + sin(angle) * labelRadius
                        )
                }
            }
        }
    }
}

struct RadarPolygon: Shape {
    let sides: Int
    let scale: CGFloat
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 * scale
        
        for i in 0..<sides {
            let angle = (CGFloat(i) / CGFloat(sides)) * 2 * .pi - .pi / 2
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            if i == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}

struct RadarDataShape: Shape {
    let values: [CGFloat]
    let radius: CGFloat
    let center: CGPoint
    
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let actualCenter = CGPoint(x: rect.midX, y: rect.midY)
        
        for (index, value) in values.enumerated() {
            let angle = (CGFloat(index) / CGFloat(values.count)) * 2 * .pi - .pi / 2
            let r = radius * value
            let point = CGPoint(
                x: actualCenter.x + cos(angle) * r,
                y: actualCenter.y + sin(angle) * r
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Recent Analysis Row
struct RecentAnalysisRow: View {
    let date: String
    let score: String
    
    var body: some View {
        HStack {
            HStack(spacing: 16) {
                Text(date)
                    .font(.system(size: 14, weight: .light))
                    .foregroundColor(.white)
                
                Text(score)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppTheme.accentColor)
            }
            
            Spacer()
            
            Button(action: {}) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 18))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Instruction Row
struct InstructionRow: View {
    let imageName: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Actual image from assets
            Image(imageName)
                .resizable()
                .scaledToFill()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
            
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                
                Text(description)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
                    .lineSpacing(4)
            }
        }
    }
}

// MARK: - Section Header (clean simple)
struct AnalyzeSectionHeader: View {
    let title: String
    
    var body: some View {
        Text(title)
            .font(.system(size: 20, weight: .light))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
    }
}

// MARK: - Section Divider
struct AnalyzeSectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
    }
}

#Preview {
    AnalyzeView()
}

