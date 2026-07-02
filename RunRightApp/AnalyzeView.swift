//
//  AnalyzeView.swift
//  RunRightApp
//
//  Pixel-perfect match to HTML prototype with VideoProcessor backend

import SwiftUI

/// Int conversion that cannot trap on NaN or Inf from degenerate clips.
func analyzeSafeInt(_ v: Double, fallback: Int = 0) -> Int {
    v.isFinite ? Int(v.rounded()) : fallback
}
import PhotosUI
import AVKit
import AVFoundation
import UIKit
import UniformTypeIdentifiers
import QuartzCore
import Combine

private extension Font {
    static let analyzeHero: Font = .system(size: 50, weight: .black)
    static let analyzeSection: Font = .system(size: 15, weight: .black)
    static let analyzeButton: Font = .system(size: 18, weight: .heavy)
    static let analyzeBody: Font = .system(size: 14, weight: .regular)
    static let analyzeCaption: Font = .system(size: 13, weight: .regular)
    static let analyzeMetric: Font = .system(size: 18, weight: .black)
    static let analyzeMeta: Font = .system(size: 11, weight: .bold)
    static let analyzeTiny: Font = .system(size: 9, weight: .bold)
}

// MARK: - Analysis history (local, on-device)

/// One completed form analysis — the three component scores plus when it ran.
struct AnalysisRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let efficiency: Int?
    let power: Int?
    let impact: Int?

    init(id: UUID = UUID(), date: Date, efficiency: Int?, power: Int?, impact: Int?) {
        self.id = id
        self.date = date
        self.efficiency = efficiency
        self.power = power
        self.impact = impact
    }

    /// Average of the present component scores, or nil if none were measured.
    var overall: Int? {
        let vals = [efficiency, power, impact].compactMap { $0 }
        guard !vals.isEmpty else { return nil }
        return Int((Double(vals.reduce(0, +)) / Double(vals.count)).rounded())
    }
}

/// Persists recent form-analysis results locally so the Analyze dashboard's
/// RECENT card reflects real history rather than placeholder data.
final class AnalysisHistoryStore: ObservableObject {
    static let shared = AnalysisHistoryStore()

    @Published private(set) var records: [AnalysisRecord] = []

    private let key = "analysisHistory.v1"
    private let maxRecords = 20

    private init() { load() }

    /// Folder holding one raw-data CSV per analysis (keyed by record id).
    static var exportsDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("form_exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func csvURL(for id: UUID) -> URL {
        exportsDir.appendingPathComponent("\(id.uuidString).csv")
    }

    /// Returns the new record's id, or nil when the analysis was skipped.
    @discardableResult
    func add(efficiency: Int?, power: Int?, impact: Int?) -> UUID? {
        // Skip empties (e.g. framing too poor to score anything).
        guard efficiency != nil || power != nil || impact != nil else { return nil }
        let record = AnalysisRecord(date: Date(), efficiency: efficiency, power: power, impact: impact)
        records.insert(record, at: 0)
        if records.count > maxRecords { records = Array(records.prefix(maxRecords)) }
        save()
        pruneOrphanExports()
        return record.id
    }

    /// Delete CSVs whose record was evicted so raw exports never outlive history.
    private func pruneOrphanExports() {
        let keep = Set(records.map { "\($0.id.uuidString).csv" })
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Self.exportsDir.path) else { return }
        for f in files where f.hasSuffix(".csv") && !keep.contains(f) {
            try? fm.removeItem(at: Self.exportsDir.appendingPathComponent(f))
        }
    }

    /// Wipe history and every raw CSV export (sign out and account deletion).
    func clearAll() {
        records = []
        UserDefaults.standard.removeObject(forKey: key)
        try? FileManager.default.removeItem(at: Self.exportsDir)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([AnalysisRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

struct AnalyzeView: View {
    @StateObject private var processor = VideoProcessor()
    @ObservedObject private var history = AnalysisHistoryStore.shared
    @State private var selectedItem: PhotosPickerItem?
    @State private var selectedVideoURL: URL?
    @State private var showingInstructions = false
    @State private var replayPlayer: AVPlayer?
    @State private var isPreparingVideo = false
    @State private var showingPreview = false
    @State private var videoMode: VideoMode = .side  // Default to side view
    @State private var showingSettings = false
    @State private var showingCamera = false
    @State private var cameraUnavailableAlert = false
    @State private var showScorecard = false
    @State private var scorecardDragOffset: CGFloat = 0
    @State private var showDrills = false
    @State private var showScan = false
    @State private var showPaywall = false
    @State private var showAllHistory = false
    @State private var cachedFocusInsights: [CombinedInsight] = []
    @ObservedObject private var subscriptions = SubscriptionManager.shared
    @AppStorage("userBodyHeightMeters") private var userBodyHeightMeters: Double = 1.7  // Default 1.7m (average height)
    @AppStorage("treadmillDistanceMeters") private var treadmillDistanceMeters: Double = 2.0  // Default 2.0m
    @AppStorage("useImperialUnits") private var useImperialUnits: Bool = true  // Default to feet/inches
    @State private var heightFeet: Int = 5
    @State private var heightInches: Int = 7
    @State private var showingAnalyzeSnapshot = false
    @State private var analyzeSnapshotImage: UIImage?
    
    var body: some View {
        ZStack {
            AppTheme.bgColor.ignoresSafeArea()

            analyzeHomeScroll

            if showingInstructions {
                instructionsPopup
            }

            if showingSettings {
                settingsPopup
            }

            if isPreparingVideo || processor.isProcessing {
                loadingOverlay
            }

            if showScorecard {
                scorecardOverlay
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(30)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: showScorecard)
        .onChange(of: selectedItem) { _, newItem in
            Task {
                if let newItem = newItem {
                    await loadVideo(from: newItem)
                }
            }
        }
        // Record the analysis once it finishes so RECENT reflects real results.
        .onChange(of: processor.processedVideoURL) { _, url in
            guard let processedURL = url else { return }
            let newId = history.add(
                efficiency: computeEfficiencyScore(series: processor.metricSeries),
                power: computeSprintPowerScore(),
                impact: impactReading?.score
            )
            saveLatestScorecardForm(processedURL: processedURL)
            if let newId { persistRawDataCSV(for: newId) }
            refreshFocusInsights()
        }
        .sheet(isPresented: $showDrills) {
            DrillsView()
        }
        .sheet(isPresented: $showScan, onDismiss: { refreshFocusInsights() }) {
            ScanView()
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
        .sheet(isPresented: $showAllHistory) {
            AnalysisHistorySheet()
        }
        .fullScreenCover(isPresented: $showingPreview) {
            if let processedURL = processor.processedVideoURL {
                AnalyzePreviewView(
                    videoURL: processedURL,
                    poseEngineName: processor.poseEngineName,
                    metrics: processor.analysisMetrics,
                    series: processor.metricSeries,
                    userBodyHeightMeters: userBodyHeightMeters,
                    processor: processor,
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
        .fullScreenCover(isPresented: $showingCamera) {
            VideoCameraPicker(
                onVideoRecorded: { url in handleRecordedVideo(url) },
                onCancel: { showingCamera = false }
            )
            .ignoresSafeArea()
        }
        .alert("Camera Unavailable", isPresented: $cameraUnavailableAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Video recording requires a device with a camera.")
        }
        .sheet(isPresented: $showingAnalyzeSnapshot) {
            if let img = analyzeSnapshotImage {
                SnapshotView(image: img, onDismiss: { showingAnalyzeSnapshot = false })
            }
        }
    }

    private var scorecardOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { showScorecard = false }

            ScorecardShareScreen(onClose: { showScorecard = false })
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .offset(y: scorecardDragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            scorecardDragOffset = max(0, value.translation.height)
                        }
                        .onEnded { value in
                            if value.translation.height > 120 {
                                scorecardDragOffset = 0
                                showScorecard = false   // parent transition slides it down
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    scorecardDragOffset = 0
                                }
                            }
                        }
                )
        }
        .background(Color.clear)
    }

    private var analyzeHomeScroll: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                analyzeHeroHeader
                analyzeDashboardWidgets
                Spacer().frame(height: 32)
            }
        }
    }

    private var analyzeDashboardWidgets: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                analyzeNewRunWidgetCard
                analyzeScorecardCard
            }
            analyzeShoeHeatGridCard
            analyzeFormReport
            analyzeRecentFullCard
        }
        .padding(.horizontal, AppTheme.screenPadding)
        .padding(.top, 4)
    }

    /// Scorecard in its own separate gray box, to the right of the action card.
    private var analyzeScorecardCard: some View {
        Button(action: { showScorecard = true }) {
            VStack(spacing: 8) {
                VStack(spacing: -1) {
                    Text("SCORE")
                    Text("CARD")
                }
                .font(.analyzeButton)
                .foregroundColor(.white)
                Text("OPEN")
                    .font(.analyzeMeta)
                    .foregroundColor(AppTheme.formRed)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .analyzeHomeWidgetChrome(padding: 14)
        .frame(width: 118)
    }

    // MARK: - Scores (Efficiency / Power / Impact — uniform, on-theme)
    private var impactReading: ImpactResult? {
        guard let series = processor.metricSeries, let metrics = processor.analysisMetrics else { return nil }
        return impactResult(series: series, metrics: metrics, userBodyHeightMeters: userBodyHeightMeters)
    }

    // ── Form report: one honest grade + a prioritised FOCUS list (the worst
    // form cues, each with a concrete fix), fusing the skeleton analysis with the
    // shoe-wear gait read. Replaces the old Efficiency/Power/Impact vanity dials.
    @ViewBuilder private var analyzeFormReport: some View {
        if let series = processor.metricSeries, !series.formCueScores.isEmpty {
            let ranked = series.formCueScores.sorted { $0.score < $1.score }
            let grade = Int((series.formCueScores.map(\.score).reduce(0, +) / Double(series.formCueScores.count)).rounded())
            let insights = cachedFocusInsights.isEmpty
                ? FormGaitCrossReference.insights(buildFormGaitInputs(series: series))
                : cachedFocusInsights
            analyzeFormHeroCard(grade: grade, worst: ranked.first, metrics: processor.analysisMetrics)
            analyzeCombinedFocusCard(Array(insights.prefix(4)))
        } else {
            analyzeReportEmptyCard
        }
    }

    /// Recompute the fused FOCUS list once per data change instead of on every
    /// render (the insights hit UserDefaults and allocate fresh rows).
    private func refreshFocusInsights() {
        guard let series = processor.metricSeries, !series.formCueScores.isEmpty else {
            cachedFocusInsights = []
            return
        }
        cachedFocusInsights = FormGaitCrossReference.insights(buildFormGaitInputs(series: series))
    }

    /// Build the cross-reference engine's inputs from the video form cues + the
    /// latest shoe scan (gait type, strike, and per-zone wear intensity).
    private func buildFormGaitInputs(series: MetricSeries) -> FormGaitInputs {
        var scores: [FormCue: Double] = [:]
        for s in series.formCueScores { scores[s.cue] = s.score }

        let left = ScorecardDataStore.shared.loadWearZones(side: "left")
        let right = ScorecardDataStore.shared.loadWearZones(side: "right")
        let gaitType = ScorecardDataStore.shared.loadGaitType()
        let strike = ScorecardDataStore.shared.loadGaitStrike()
        let hasShoe = left != nil || right != nil || gaitType != nil || strike != nil

        let zones = ["bigToe", "lesserToes", "medialBall", "centralBall", "lateralBall",
                     "medialMidfoot", "lateralMidfoot", "medialHeel", "centralHeel", "lateralHeel"]
        var wear: [String: Int] = [:]
        for z in zones {
            let l = left.map { FormGaitCrossReference.intensity($0.color(for: z)) } ?? 0
            let r = right.map { FormGaitCrossReference.intensity($0.color(for: z)) } ?? 0
            wear[z] = max(l, r)
        }

        return FormGaitInputs(cueScores: scores, gaitType: gaitType, strikePattern: strike,
                              wear: wear, hasVideo: true, hasShoe: hasShoe)
    }

    /// FOCUS list — each item fuses form + shoe wear and carries a confidence
    /// badge (CONFIRMED when both sources agree, VIDEO / SHOE for a single source,
    /// RE-CHECK when they conflict).
    private func analyzeCombinedFocusCard(_ insights: [CombinedInsight]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("FOCUS")
                    .font(.analyzeSection)
                    .foregroundColor(.white)
                Text("FORM + SHOE")
                    .font(.analyzeMeta)
                    .foregroundColor(AppTheme.formRed.opacity(0.85))
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ForEach(Array(insights.enumerated()), id: \.element.id) { index, insight in
                if index > 0 {
                    Divider().background(Color.white.opacity(0.06)).padding(.horizontal, 18)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        corroborationBadge(insight.corroboration)
                        Text(insight.title)
                            .font(.analyzeBody.weight(.semibold))
                            .foregroundColor(.white)
                        Spacer(minLength: 0)
                    }
                    Text(insight.detail)
                        .font(.analyzeCaption)
                        .foregroundColor(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }

            Divider().background(Color.white.opacity(0.06)).padding(.horizontal, 18)
            Button(action: { showDrills = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "figure.strengthtraining.functional")
                        .font(.system(size: 11, weight: .bold))
                    Text("SEE DRILLS")
                        .font(.analyzeMeta)
                }
                .foregroundColor(AppTheme.formRed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, 4)
        .analyzeHomeWidgetChrome(padding: 0)
    }

    private func corroborationBadge(_ c: Corroboration) -> some View {
        let color = Color(hex: c.hex)
        return Text(c.label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
            .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
    }

    /// Hero: a single overall FORM grade ring + a plain-English verdict + the real
    /// supporting metrics (cadence / strike / vertical oscillation). Asymmetric.
    private func analyzeFormHeroCard(grade: Int, worst: FormCueScore?, metrics: AnalysisMetrics?) -> some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.10), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(grade, 0), 100)) / 100)
                    .stroke(AppTheme.formRed, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.6), value: grade)
                VStack(spacing: 1) {
                    Text("\(grade)")
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("FORM")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
            .frame(width: 104, height: 104)

            VStack(alignment: .leading, spacing: 12) {
                Text(formGrade(grade))
                    .font(.system(size: 40, weight: .heavy))
                    .foregroundColor(Color(hex: "#FF3B3B"))
                if let metrics {
                    HStack(spacing: 18) {
                        analyzeMetricChip("CAD", "\(Int(metrics.cadence.rounded()))")
                        analyzeMetricChip("STRIKE", String(metrics.footStrikePattern.uppercased().prefix(4)))
                        analyzeMetricChip("V.OSC", String(format: "%.1f", metrics.verticalOscillation))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .analyzeHomeWidgetChrome(padding: 18)
    }

    private func analyzeMetricChip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.analyzeMetric)
                .foregroundColor(.white)
            Text(label)
                .font(.analyzeTiny)
                .foregroundColor(.white.opacity(0.45))
        }
    }

    private var analyzeReportEmptyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FORM REPORT")
                .font(.analyzeSection)
                .foregroundColor(.white)
            Text("NO VIDEO YET")
                .font(.analyzeMeta)
                .foregroundColor(AppTheme.formRed.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .analyzeHomeWidgetChrome(padding: 18)
    }

    // MARK: Form-report helpers
    /// Single letter grade from the overall form score.
    private func formGrade(_ score: Int) -> String {
        switch score {
        case 93...:   return "A"
        case 90..<93: return "A-"
        case 87..<90: return "B+"
        case 83..<87: return "B"
        case 80..<83: return "B-"
        case 77..<80: return "C+"
        case 73..<77: return "C"
        case 70..<73: return "C-"
        case 60..<70: return "D"
        default:      return "F"
        }
    }

    // MARK: - Recent (full width)
    private var analyzeRecentFullCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RECENT")
                .font(.analyzeSection)
                .foregroundColor(.white)
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 10)

            let recent = Array(history.records.prefix(3))
            if recent.isEmpty {
                Text("No analyses yet.")
                    .font(.analyzeCaption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.78))
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
            } else {
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, record in
                    if index > 0 {
                        Divider().background(Color.white.opacity(0.06)).padding(.horizontal, 18)
                    }
                    recentFullRow(record)
                }
                .padding(.bottom, 4)

                if history.records.count > recent.count {
                    Divider().background(Color.white.opacity(0.06)).padding(.horizontal, 18)
                    Button(action: { subscriptions.isPremium ? (showAllHistory = true) : (showPaywall = true) }) {
                        HStack(spacing: 6) {
                            if !subscriptions.isPremium {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            Text("SEE ALL")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                        .foregroundColor(AppTheme.formRed)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .analyzeHomeWidgetChrome(padding: 0)
    }

    /// Persistent folder holding one raw-data CSV per analysis (keyed by record id),
    /// so every RECENT row keeps its own exportable data.
    private func csvFileURL(for id: UUID) -> URL {
        AnalysisHistoryStore.csvURL(for: id)
    }

    private func hasExport(for id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: csvFileURL(for: id).path)
    }

    /// Write the just-finished analysis's raw data to its own CSV file.
    private func persistRawDataCSV(for id: UUID) {
        guard let csv = analyzeRawDataCSVString() else { return }
        try? csv.write(to: csvFileURL(for: id), atomically: true, encoding: .utf8)
    }

    /// Raw per-frame time series + cue scores + summary as CSV text.
    private func analyzeRawDataCSVString() -> String? {
        guard let series = processor.metricSeries else { return nil }
        let cols: [(String, [Double])] = [
            ("cadence_spm", series.cadenceSeries),
            ("vertical_bounce", series.headBobbingYSeries),
            ("vertical_oscillation", series.verticalOscillationSeries),
            ("ground_contact_left", series.groundContactLeftSeries),
            ("ground_contact_right", series.groundContactRightSeries),
            ("stride_length", series.strideLengthSeries),
            ("hip_drop", series.hipDropSeries),
            ("knee_angle", series.kneeAngleSeries),
            ("knee_symmetry", series.kneeSymmetrySeries),
            ("gct_symmetry", series.gctSymmetrySeries)
        ]
        var lines: [String] = ["frame," + cols.map(\.0).joined(separator: ",")]
        let n = cols.map { $0.1.count }.max() ?? 0
        for idx in 0..<n {
            var row = "\(idx)"
            for (_, arr) in cols {
                if idx < arr.count, arr[idx].isFinite { row += "," + String(format: "%.4f", arr[idx]) }
                else { row += "," }
            }
            lines.append(row)
        }
        lines.append("")
        lines.append("cue,score")
        for s in series.formCueScores.sorted(by: { $0.cue.rawValue < $1.cue.rawValue }) {
            lines.append("\(s.cue.rawValue.replacingOccurrences(of: ",", with: ";")),\(analyzeSafeInt(s.score))")
        }
        if let m = processor.analysisMetrics {
            lines.append("")
            lines.append("summary,value")
            lines.append("cadence_spm,\(analyzeSafeInt(m.cadence))")
            lines.append("strike,\(m.footStrikePattern)")
            lines.append("vertical_oscillation,\(String(format: "%.2f", m.verticalOscillation))")
        }
        return lines.joined(separator: "\n")
    }

    private static let recentDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    private func recentFullRow(_ record: AnalysisRecord) -> some View {
        HStack(spacing: 12) {
            Text(Self.recentDateFormatter.string(from: record.date))
                .font(.analyzeCaption.weight(.medium))
                .foregroundColor(.white)
            Spacer()
            if hasExport(for: record.id) {
                ShareLink(item: csvFileURL(for: record.id)) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Data")
                            .font(.analyzeMeta)
                    }
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Text(record.overall.map(String.init) ?? "—")
                .font(.analyzeMetric)
                .foregroundColor(AppTheme.formRed)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var analyzeNewRunWidgetCard: some View {
        VStack(spacing: 18) {
            // Show the post-analysis actions as soon as results exist — the
            // processed video (for Snapshot/Download) may finish a moment later.
            if processor.metricSeries != nil {
                analyzePostAnalysisContent(processedURL: processor.processedVideoURL)
            } else {
                analyzeNewRunContent
            }

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
                    .foregroundColor(AppTheme.formRed)
                }
                .padding(.top, 4)
            }
        }
        .analyzeHomeWidgetChrome()
    }

    private var analyzeNewRunContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ANALYZE")
                .font(.analyzeSection)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)

            PhotosPicker(selection: $selectedItem, matching: .videos) {
                Text("UPLOAD")
                    .font(.analyzeButton)
                    .foregroundColor(AppTheme.onAccentPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(AppTheme.formRed)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.homeButtonCornerRadius, style: .continuous))
            }
            .buttonStyle(.plain)

            Button(action: {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    showingCamera = true
                } else {
                    cameraUnavailableAlert = true
                }
            }) {
                Text("RECORD")
                    .font(.analyzeButton)
                    .foregroundColor(.white.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.homeButtonCornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.homeButtonCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            HStack(spacing: 18) {
                Button(action: { showingInstructions = true }) {
                    Text("GUIDE")
                        .font(.analyzeMeta)
                        .foregroundColor(AppTheme.formRed)
                }
                .buttonStyle(.plain)
                Button(action: { subscriptions.isPremium ? (showScan = true) : (showPaywall = true) }) {
                    Text("SCAN SHOES")
                        .font(.analyzeMeta)
                        .foregroundColor(AppTheme.formRed)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var analyzeShoeHeatGridCard: some View {
        let leftZones = ScorecardDataStore.shared.loadWearZones(side: "left")
        let rightZones = ScorecardDataStore.shared.loadWearZones(side: "right")
        let gaitType = ScorecardDataStore.shared.loadGaitType()
        let strikePattern = ScorecardDataStore.shared.loadGaitStrike()
        let hasScan = leftZones != nil || rightZones != nil
        let health = analyzeCombinedShoeHealth(left: leftZones, right: rightZones)

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SHOE GRID")
                        .font(.analyzeSection)
                        .foregroundColor(.white)
                    if hasScan {
                        Text(analyzeShoeSummary(gaitType: gaitType, strikePattern: strikePattern))
                            .font(.analyzeMeta)
                            .foregroundColor(AppTheme.formRed.opacity(0.85))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Button(action: { subscriptions.isPremium ? (showScan = true) : (showPaywall = true) }) {
                    Text(hasScan ? "RESCAN" : "SCAN")
                        .font(.analyzeMeta)
                        .foregroundColor(AppTheme.formRed)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(AppTheme.formRed.opacity(0.14)))
                        .overlay(Capsule().stroke(AppTheme.formRed.opacity(0.42), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            HStack(alignment: .center, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    FootHeatmapView(isLeft: true, wearZones: leftZones, labelDesign: .default)
                    FootHeatmapView(isLeft: false, wearZones: rightZones, labelDesign: .default)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 12) {
                    analyzeShoeMetric(label: "GAIT", value: gaitType?.uppercased() ?? "--")
                    analyzeShoeMetric(label: "STRIKE", value: strikePattern?.uppercased() ?? "--")
                    analyzeShoeMetric(label: "HEALTH", value: health.map { "\($0)%" } ?? "--")
                }
                .frame(width: 86, alignment: .leading)
            }

            if !hasScan {
                Text("SCAN TO BEGIN")
                    .font(.analyzeMeta)
                    .foregroundColor(AppTheme.formRed)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)
            }
        }
        .analyzeHomeWidgetChrome(padding: 18)
    }

    private func analyzeShoeMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.analyzeMetric)
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(label)
                .font(.analyzeTiny)
                .foregroundColor(AppTheme.formRed.opacity(0.8))
        }
    }

    private func analyzeShoeSummary(gaitType: String?, strikePattern: String?) -> String {
        let gait = gaitType?.uppercased() ?? "GAIT READY"
        guard let strikePattern, !strikePattern.isEmpty else { return gait }
        return "\(gait) · \(strikePattern.uppercased()) STRIKE"
    }

    private func analyzeCombinedShoeHealth(left: WearZoneData?, right: WearZoneData?) -> Int? {
        let values = [left, right].compactMap(analyzeShoeHealthPercent)
        guard !values.isEmpty else { return nil }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    private func analyzeShoeHealthPercent(zones: WearZoneData?) -> Int? {
        guard let z = zones else { return nil }
        let scores = [
            analyzeWearScore(z.bigToe), analyzeWearScore(z.lesserToes),
            analyzeWearScore(z.medialBall), analyzeWearScore(z.centralBall), analyzeWearScore(z.lateralBall),
            analyzeWearScore(z.medialMidfoot), analyzeWearScore(z.lateralMidfoot),
            analyzeWearScore(z.medialHeel), analyzeWearScore(z.centralHeel), analyzeWearScore(z.lateralHeel)
        ]
        let avg = scores.reduce(0, +) / Double(scores.count)
        return Int((avg * 100).rounded())
    }

    private func analyzeWearScore(_ color: String) -> Double {
        switch color.lowercased() {
        case "green": return 1.0
        case "yellow": return 0.45
        case "orange": return 0.15
        case "red": return 0.0
        default: return 1.0
        }
    }

    private func analyzePostAnalysisContent(processedURL: URL?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ANALYSIS COMPLETE")
                .font(.analyzeSection)
                .foregroundColor(.white)

            // Act on this result (Snapshot/Download need the processed video).
            // The Scorecard lives in its own box to the right.
            if let processedURL {
                HStack(spacing: 10) {
                    Button(action: { captureAnalyzeSnapshot() }) { analyzeSecondaryButton("Snapshot") }
                        .buttonStyle(.plain)
                    ShareLink(item: processedURL) { analyzeSecondaryButton("Download") }
                        .buttonStyle(.plain)
                }
            }

            // … then a quiet text link to start over (matches SEE INSTRUCTIONS).
            Button(action: { resetProcessor() }) {
                Text("NEW ANALYSIS")
                    .font(.analyzeMeta)
                    .foregroundColor(AppTheme.formRed)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
        }
    }

    /// Plain text-only secondary button matching the icon-free Analyze dashboard.
    private func analyzeSecondaryButton(_ title: String) -> some View {
        Text(title)
            .font(.analyzeButton)
            .foregroundColor(.white.opacity(0.9))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.homeButtonCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.homeButtonCornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
    }

    /// Capture the skeleton-at-contact snapshot (same peak-stride frame the
    /// scorecard uses) and present it.
    private func captureAnalyzeSnapshot() {
        guard let url = processor.processedVideoURL, let series = processor.metricSeries else { return }
        Task {
            if let png = await scorecardSnapshotPNG(from: url, series: series),
               let img = UIImage(data: png) {
                await MainActor.run {
                    analyzeSnapshotImage = img
                    showingAnalyzeSnapshot = true
                }
            }
        }
    }

    // MARK: - Hero header (dashboard)
    private var analyzeHeroHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: -5) {
                Text("FORM")
                    .font(.analyzeHero)
                    .tracking(-1.5)
                    .foregroundColor(.white)
                Text("ANALYSIS")
                    .font(.analyzeHero)
                    .tracking(-1.5)
                    .foregroundColor(AppTheme.formRed)
            }
            Spacer(minLength: 8)
            Button(action: { showingSettings = true }) {
                Text("SETTINGS")
                    .font(.analyzeMeta)
                    .foregroundColor(AppTheme.formRed)
            }
            .buttonStyle(.plain)
            .padding(.top, 20)
        }
        .padding(.horizontal, AppTheme.screenPadding)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
    
    private func computeEfficiencyScore(series: MetricSeries?) -> Int? {
        guard let series, let bd = computeEfficiencyBreakdown(series: series) else { return nil }
        return bd.composite
    }
    
    private func computeSprintPowerScore() -> Int? {
        guard let series = processor.metricSeries, let metrics = processor.analysisMetrics else { return nil }
        return computeSprintPowerComposite(series: series, metrics: metrics, userBodyHeightMeters: userBodyHeightMeters)
    }

    private func saveLatestScorecardForm(processedURL: URL) {
        guard
            let series = processor.metricSeries,
            let metrics = processor.analysisMetrics,
            let efficiency = computeEfficiencyScore(series: series),
            let power = computeSprintPowerScore(),
            let impact = impactReading?.score,
            let breakdown = computeEfficiencyBreakdown(series: series)
        else { return }

        Task {
            let snapshotPNG = await scorecardSnapshotPNG(from: processedURL, series: series)
            // Canonical cadence: the same peak-based estimator as the results
            // headline so the scorecard, coach, and results screen agree.
            let actualDuration = ((try? await AVAsset(url: processedURL).load(.duration))?.seconds) ?? 0
            let footHip = !series.rightFootHipDistanceSeries.isEmpty
                ? series.rightFootHipDistanceSeries : series.leftFootHipDistanceSeries
            let fps = actualDuration > 0 && !footHip.isEmpty ? Double(footHip.count) / actualDuration : 30.0
            let peaks = AnalyzePreviewView.detectLocalMaxima(footHip, frameRate: fps)
            let canonicalCadence = peaks.count >= 2
                ? AnalyzePreviewView.calculateCadenceFromPeaks(peaks, frameRate: fps)
                : metrics.cadence
            let overall = Int((Double(efficiency + power + impact) / 3.0).rounded())
            let gctValues = [metrics.groundContactLeft, metrics.groundContactRight].filter { $0 > 0 }
            let avgGCT = gctValues.isEmpty ? nil : gctValues.reduce(0, +) / Double(gctValues.count)

            let rows: [StoredScorecardMetric] = [
                scorecardMetric(label: "CAD", value: "\(analyzeSafeInt(canonicalCadence))", optimal: "165-190", score: cadenceScore(canonicalCadence)),
                scorecardMetric(label: "TORSO", value: degreeText(series.torsoAngleMean), optimal: "5-10°", score: breakdown.torso.score),
                scorecardMetric(label: "SHIN", value: degreeText(abs(series.shankAngleAtContactSignedDeg)), optimal: "<8°", score: breakdown.shin.score),
                scorecardMetric(label: "KNEE", value: degreeText(series.kneeAngleMean), optimal: "150-170", score: kneeScore(series.kneeAngleMean)),
                scorecardMetric(label: "HIP", value: degreeText(series.hipAngleMean), optimal: "150-175", score: hipScore(series.hipAngleMean)),
                scorecardMetric(label: "ELBOW", value: degreeText(series.elbowAngleMean), optimal: "~90°", score: breakdown.elbow.score),
                scorecardMetric(label: "GCT", value: avgGCT.map { "\(Int($0.rounded()))" } ?? "--", optimal: "<250", score: avgGCT.map(groundContactScore) ?? 0),
                scorecardMetric(label: "STRIKE", value: metrics.footStrikePattern.uppercased().prefix(4).description, optimal: "MID", score: analyzeSafeInt(metrics.footStrikeConfidence * 100))
            ]

            let record = StoredScorecardForm(
                date: Date(),
                overall: overall,
                power: power,
                impact: impact,
                efficiency: efficiency,
                cadence: analyzeSafeInt(canonicalCadence),
                metrics: rows,
                snapshotPNG: snapshotPNG,
                bounce: series.headBobbingYSeries.filter { $0.isFinite },
                gct: {
                    let l = series.groundContactLeftSeries
                    let r = series.groundContactRightSeries
                    var out: [Double] = []
                    for i in 0..<max(l.count, r.count) {
                        if i < l.count { out.append(l[i]) }
                        if i < r.count { out.append(r[i]) }
                    }
                    return out.filter { $0.isFinite }
                }(),
                cadenceTrend: series.cadenceSeries.filter { $0.isFinite },
                cueScores: Dictionary(series.formCueScores
                    .filter { $0.score.isFinite }
                    .map { ($0.cue.rawValue, $0.score) },
                    uniquingKeysWith: { a, _ in a })
            )

            await MainActor.run {
                ScorecardDataStore.shared.save(record)
            }
        }
    }

    private func scorecardSnapshotPNG(from processedURL: URL, series: MetricSeries) async -> Data? {
        // Refine the heel-strike index to the true foot-landing frame, matching the
        // manual Snapshot button (raw peaks can sit a few frames off contact).
        let baseIndex = series.heelStrikeFrameIndices.first ?? 0
        let frameIndex = scorecardPeakStrideFrame(around: baseIndex)
        let totalFrames = max(series.rightFootHipDistanceSeries.count, series.leftFootHipDistanceSeries.count, 1)

        let asset = AVAsset(url: processedURL)
        // Map frame index → time using the ACTUAL processed-video duration (not the
        // analysis series duration, which can differ and shift the frame off contact).
        let assetDuration = (try? await asset.load(.duration))?.seconds ?? series.durationSeconds
        let duration = max(assetDuration, 0.1)
        let frameRate = Double(totalFrames) / duration
        let timestamp = Double(frameIndex) / max(frameRate, 1)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero   // exact frame
        generator.requestedTimeToleranceAfter = .zero

        do {
            let cgImage = try await generator.image(at: CMTime(seconds: timestamp, preferredTimescale: 600)).image
            return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.82)
        } catch {
            return nil
        }
    }

    /// Find the foot-FLAT contact frame near a detected strike: the frame where the
    /// foot is lowest (planted on the ground/belt) AND most directly under the hip —
    /// true mid-stance. This avoids the forward-reaching swing frame where the foot
    /// is still hovering before touchdown.
    private func scorecardPeakStrideFrame(around heelStrikeIndex: Int) -> Int {
        let isLeft = processor.selectedSide == .left
        let ankleJoint: PoseJoint = isLeft ? .leftAnkle : .rightAnkle
        let hipJoint: PoseJoint = isLeft ? .leftHip : .rightHip
        var bestIndex = heelStrikeIndex
        var bestScore = -Double.greatestFiniteMagnitude
        // Stance runs from just before the strike through mid-stance.
        for idx in max(0, heelStrikeIndex - 2)...(heelStrikeIndex + 10) {
            guard let frame = processor.getPoseFrame(at: idx),
                  let ankle = frame.points[ankleJoint],
                  let hip = frame.points[hipJoint] else { continue }
            // Larger Y = lower on screen (foot planted); penalise horizontal distance
            // from the hip so we land on the under-body mid-stance frame.
            let score = Double(ankle.y) - 0.6 * abs(Double(ankle.x - hip.x))
            if score > bestScore { bestScore = score; bestIndex = idx }
        }
        return bestIndex
    }

    private func scorecardMetric(label: String, value: String, optimal: String, score: Int) -> StoredScorecardMetric {
        StoredScorecardMetric(label: label, value: value, optimal: optimal, status: scoreStatus(score).rawValue)
    }

    private func scoreStatus(_ score: Int) -> FormStatus {
        switch score {
        case 80...100: return .good
        case 60..<80: return .warn
        default: return .bad
        }
    }

    private func degreeText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "--" }
        return "\(Int(value.rounded()))°"
    }

    private func cadenceScore(_ cadence: Double) -> Int {
        guard cadence > 0 else { return 0 }
        if cadence >= 165 && cadence <= 190 { return 92 }
        let distance = cadence < 165 ? 165 - cadence : cadence - 190
        return max(40, Int((92 - distance * 1.6).rounded()))
    }

    private func verticalOscillationScore(_ value: Double) -> Int {
        guard value > 0 else { return 0 }
        if value >= 6 && value <= 9 { return 90 }
        let distance = value < 6 ? 6 - value : value - 9
        return max(40, Int((90 - distance * 8).rounded()))
    }

    private func groundContactScore(_ milliseconds: Double) -> Int {
        guard milliseconds > 0 else { return 0 }
        if milliseconds <= 250 { return 90 }
        return max(40, Int((90 - (milliseconds - 250) * 0.25).rounded()))
    }

    private func kneeScore(_ angle: Double) -> Int {
        guard angle > 0 else { return 0 }
        if angle >= 150 && angle <= 170 { return 88 }
        let distance = angle < 150 ? 150 - angle : angle - 170
        return max(45, Int((88 - distance * 1.5).rounded()))
    }

    private func hipScore(_ angle: Double) -> Int {
        guard angle > 0 else { return 0 }
        if angle >= 150 && angle <= 175 { return 88 }
        let distance = angle < 150 ? 150 - angle : angle - 175
        return max(45, Int((88 - distance * 1.5).rounded()))
    }
    
    // MARK: - Instructions Popup
    // MARK: - Settings Popup
    private var settingsPopup: some View {
        ZStack {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture {
                    showingSettings = false
                }
            
            VStack(spacing: 24) {
                Text("Settings")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)
                
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Body Height")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                        
                        Spacer()
                        
                        // Unit toggle
                        Picker("Unit", selection: $useImperialUnits) {
                            Text("ft/in").tag(true)
                            Text("m").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 120)
                        .onChange(of: useImperialUnits) { newValue in
                            if newValue {
                                // Meters → feet/inches
                                let totalInches = userBodyHeightMeters / 0.0254
                                heightFeet = Int(totalInches) / 12
                                heightInches = Int(totalInches.rounded()) % 12
                            } else {
                                // Feet/inches → meters
                                userBodyHeightMeters = Double(heightFeet * 12 + heightInches) * 0.0254
                            }
                        }
                    }
                    
                    if useImperialUnits {
                        HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Picker("Feet", selection: $heightFeet) {
                                    ForEach(3...7, id: \.self) { ft in
                                        Text("\(ft)").tag(ft)
                                    }
                                }
                                .pickerStyle(.wheel)
                                .frame(width: 60, height: 100)
                                .clipped()
                                
                                Text("ft")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                            
                            HStack(spacing: 4) {
                                Picker("Inches", selection: $heightInches) {
                                    ForEach(0...11, id: \.self) { inch in
                                        Text("\(inch)").tag(inch)
                                    }
                                }
                                .pickerStyle(.wheel)
                                .frame(width: 60, height: 100)
                                .clipped()
                                
                                Text("in")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white.opacity(0.6))
                            }
                        }
                        .onChange(of: heightFeet) { _ in
                            userBodyHeightMeters = Double(heightFeet * 12 + heightInches) * 0.0254
                        }
                        .onChange(of: heightInches) { _ in
                            userBodyHeightMeters = Double(heightFeet * 12 + heightInches) * 0.0254
                        }
                        
                        Text("\(heightFeet)'\(heightInches)\" = \(String(format: "%.2f", userBodyHeightMeters)) m")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                    } else {
                        HStack {
                            TextField("Height (meters)", value: $userBodyHeightMeters, format: .number)
                                .keyboardType(.decimalPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                            
                            Text("m")
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.6))
                                .frame(width: 30)
                        }
                        
                        Text("Enter your height in meters (e.g., 1.75 for 175 cm)")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .padding()
                .background(Color.white.opacity(0.05))
                .cornerRadius(12)
                
                VStack(alignment: .leading, spacing: 16) {
                    Text("Treadmill Distance")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                    
                    HStack {
                        TextField("Distance (meters)", value: $treadmillDistanceMeters, format: .number)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                        
                        Text("m")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.6))
                            .frame(width: 30)
                    }
                    
                    Text("Distance from camera to treadmill center")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding()
                .background(Color.white.opacity(0.05))
                .cornerRadius(12)
                
                Button(action: { showingSettings = false }) {
                    Text("Done")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppTheme.onAccentPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AppTheme.formRed)
                        .cornerRadius(12)
                }
            }
            .padding(24)
            .background(AppTheme.bgColor)
            .cornerRadius(20)
            .padding(.horizontal, 40)
            .onAppear {
                // Initialize feet/inches pickers from stored meters value
                let totalInches = userBodyHeightMeters / 0.0254
                heightFeet = Int(totalInches) / 12
                heightInches = Int(totalInches.rounded()) % 12
            }
        }
    }
    
    // MARK: - Unit Conversion
    
    /// Convert body-height-normalized series to real-world units
    private func convertToRealUnits(series: [Double], bodyHeightMeters: Double) -> (String, [Double]) {
        guard bodyHeightMeters > 0 else { return ("bh", series) }
        
        if useImperialUnits {
            // Convert to inches: value * bodyHeightMeters * 39.3701
            let converted = series.map { $0.isNaN ? Double.nan : $0 * bodyHeightMeters * 39.3701 }
            return ("in", converted)
        } else {
            // Convert to centimeters: value * bodyHeightMeters * 100
            let converted = series.map { $0.isNaN ? Double.nan : $0 * bodyHeightMeters * 100 }
            return ("cm", converted)
        }
    }
    
    /// Convert pixel-based series to real-world units using the body height scale factor
    /// scaleFactor = userHeightMeters / bodyHeightPixels
    private func convertPixelsToRealUnits(series: [Double], bodyHeightPixels: Double, bodyHeightMeters: Double) -> (String, [Double]) {
        guard bodyHeightPixels > 0, bodyHeightMeters > 0 else { return ("px", series) }
        
        let metersPerPixel = bodyHeightMeters / bodyHeightPixels
        
        if useImperialUnits {
            // Convert pixels → inches
            let inchesPerPixel = metersPerPixel * 39.3701
            let converted = series.map { $0.isNaN ? Double.nan : $0 * inchesPerPixel }
            return ("in", converted)
        } else {
            // Convert pixels → centimeters
            let cmPerPixel = metersPerPixel * 100
            let converted = series.map { $0.isNaN ? Double.nan : $0 * cmPerPixel }
            return ("cm", converted)
        }
    }
    
    /// Convert a single pixel value to real-world units string
    private func pixelToRealString(_ pixelValue: Double, bodyHeightPixels: Double, bodyHeightMeters: Double) -> String {
        guard bodyHeightPixels > 0, bodyHeightMeters > 0 else {
            return String(format: "%.1f px", pixelValue)
        }
        let metersPerPixel = bodyHeightMeters / bodyHeightPixels
        if useImperialUnits {
            let inches = pixelValue * metersPerPixel * 39.3701
            return String(format: "%.1f in", inches)
        } else {
            let cm = pixelValue * metersPerPixel * 100
            return String(format: "%.1f cm", cm)
        }
    }
    
    private var instructionsPopup: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture { showingInstructions = false }

            VStack(spacing: 22) {
                HStack {
                    Text("HOW TO RECORD")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: { showingInstructions = false }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }

                // Side-on-treadmill schematic
                HStack(spacing: 16) {
                    VStack(spacing: 5) {
                        Image(systemName: "iphone")
                            .font(.system(size: 30))
                            .foregroundColor(AppTheme.formRed)
                        Text("CAMERA")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white.opacity(0.3))
                    VStack(spacing: 5) {
                        Image(systemName: "figure.run")
                            .font(.system(size: 42))
                            .foregroundColor(.white)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.3))
                            .frame(width: 72, height: 3)
                        Text("TREADMILL")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.04)))

                // Steps
                VStack(alignment: .leading, spacing: 14) {
                    instructionLine(icon: "figure.stand", text: "Stand side on, full body in frame")
                    instructionLine(icon: "ruler", text: "Camera at hip height, about 3 m away")
                    instructionLine(icon: "clock", text: "Record 10–15 seconds of running")
                    instructionLine(icon: "speedometer", text: "Shoot in 60 fps (Slo Mo) for accurate Power")
                }

                // How it works
                Text("We track your joints frame-by-frame to measure your stride, posture, landing impact, and power.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(width: UIScreen.main.bounds.width * 0.88)
            .background(RoundedRectangle(cornerRadius: 22).fill(Color(hex: "#161618")))
        }
    }

    private func instructionLine(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppTheme.formRed)
                .frame(width: 22)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
            Spacer(minLength: 0)
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
                try data.write(to: tempURL, options: [.atomic, .completeFileProtection])
                
                await MainActor.run {
                    selectedVideoURL = tempURL
                }
                await runAnalysis(with: tempURL)
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

    private func handleRecordedVideo(_ url: URL) {
        showingCamera = false
        isPreparingVideo = true
        Task {
            do {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mov")
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    try FileManager.default.removeItem(at: tempURL)
                }
                try FileManager.default.copyItem(at: url, to: tempURL)
                await MainActor.run {
                    selectedVideoURL = tempURL
                }
                await runAnalysis(with: tempURL)
            } catch {
                await MainActor.run {
                    processor.error = "Failed to save recorded video: \(error.localizedDescription)"
                    isPreparingVideo = false
                }
            }
        }
    }
    
    private func runAnalysis(with url: URL) async {
        let shouldRun = await MainActor.run { () -> Bool in
            guard !processor.isProcessing else { return false }
            processor.videoMode = .side
            processor.error = nil
            return true
        }
        guard shouldRun else {
            await MainActor.run { isPreparingVideo = false }
            return
        }

        await processor.processVideo(url: url)

        await MainActor.run {
            isPreparingVideo = false
            if let processedURL = processor.processedVideoURL {
                replayPlayer = AVPlayer(url: processedURL)
            }
            // No separate results screen — the analysis lands back on the tab,
            // which now carries the form report + all the action buttons.
        }
    }
    
    private func resetProcessor() {
        selectedItem = nil
        selectedVideoURL = nil
        processor.processedVideoURL = nil
        processor.metricSeries = nil      // clear results so the card returns to Upload/Record
        processor.analysisMetrics = nil
        processor.error = nil
        processor.selectedSide = nil
        processor.progress = 0
        isPreparingVideo = false
        showingPreview = false
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.92)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.15), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: min(max(processor.progress, 0), 1))
                        .stroke(
                            AppTheme.formRed,
                            style: StrokeStyle(lineWidth: 6, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Text("\(Int((processor.progress * 100).rounded()))%")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .monospacedDigit()
                }
                .frame(width: 88, height: 88)
                
                Text(loadingStatusMessage)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
            }
        }
    }
    
    private var loadingStatusMessage: String {
        if processor.isProcessing {
            if processor.progress >= 0.90 {
                return "Computing metrics..."
            }
            return "Analyzing form..."
        }
        return "Preparing video..."
    }
}

// MARK: - Shared Playhead Controller
// High-performance playhead controller using CADisplayLink (iOS equivalent of requestAnimationFrame)
// Updates at 60fps without triggering SwiftUI state changes or graph re-renders
class PlayheadController: ObservableObject {
    private var displayLink: CADisplayLink?
    private weak var player: AVPlayer?
    private var analysisStartTime: Double = 0
    private var durationSeconds: Double = 0
    
    // Direct layer references for zero-latency updates
    private var cursorLayers: [WeakCursorLayer] = []
    
    // Current playhead position (0.0 to 1.0) - updated directly without SwiftUI
    @Published private(set) var playheadPosition: Double = 0
    
    // Current time in seconds
    private(set) var currentTime: Double = 0
    
    init() {}
    
    func start(player: AVPlayer, analysisStartTime: Double, durationSeconds: Double) {
        self.player = player
        self.analysisStartTime = analysisStartTime
        self.durationSeconds = durationSeconds
        
        // Stop any existing display link
        stop()
        
        // Create CADisplayLink for 60fps updates
        displayLink = CADisplayLink(target: self, selector: #selector(updatePlayhead))
        displayLink?.preferredFramesPerSecond = 60
        displayLink?.add(to: .main, forMode: .common)
    }
    
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
    
    @objc private func updatePlayhead() {
        guard let player = player, player.rate > 0, durationSeconds > 0 else { return }
        
        // Get current time directly from player (no state updates)
        let playerTime = player.currentTime().seconds
        currentTime = playerTime
        
        // Calculate playhead position (0.0 to 1.0)
        let relativeTime = max(0, playerTime - analysisStartTime)
        let position = min(max(relativeTime / durationSeconds, 0), 1)
        
        // Update all cursor layers directly (no SwiftUI redraws)
        updateCursorLayers(position: position)
    }
    
    func registerCursorLayer(_ layer: CALayer, scrollableWidth: CGFloat, plotInsetLeading: CGFloat, plotInsetTrailing: CGFloat) {
        let weakRef = WeakCursorLayer(
            layer: layer,
            scrollableWidth: scrollableWidth,
            plotInsetLeading: plotInsetLeading,
            plotInsetTrailing: plotInsetTrailing
        )
        cursorLayers.append(weakRef)
        // Clean up any nil references
        cursorLayers = cursorLayers.filter { $0.layer != nil }
    }
    
    private func updateCursorLayers(position: Double) {
        // Direct CALayer updates - no SwiftUI, no state, no redraws
        for weakRef in cursorLayers {
            guard let layer = weakRef.layer else { continue }
            
            let plotWidth = weakRef.scrollableWidth - weakRef.plotInsetLeading - weakRef.plotInsetTrailing
            let cursorX = weakRef.plotInsetLeading + plotWidth * CGFloat(position)
            
            // Direct layer frame update with no animations
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setAnimationDuration(0)
            var frame = layer.frame
            frame.origin.x = cursorX - 1.25
            layer.frame = frame
            CATransaction.commit()
        }
    }
    
    deinit {
        stop()
    }
}

// Weak reference wrapper for cursor layers
private class WeakCursorLayer {
    weak var layer: CALayer?
    let scrollableWidth: CGFloat
    let plotInsetLeading: CGFloat
    let plotInsetTrailing: CGFloat
    
    init(layer: CALayer, scrollableWidth: CGFloat, plotInsetLeading: CGFloat, plotInsetTrailing: CGFloat) {
        self.layer = layer
        self.scrollableWidth = scrollableWidth
        self.plotInsetLeading = plotInsetLeading
        self.plotInsetTrailing = plotInsetTrailing
    }
}

// MARK: - Preview Action Buttons

private struct AnalyzePrimaryButtonLabel: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundColor(AppTheme.onAccentPrimary)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(AppTheme.formRed)
        .cornerRadius(AppTheme.buttonCornerRadius)
    }
}

private struct AnalyzeSecondaryButtonLabel: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundColor(.white.opacity(0.85))
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(AppTheme.cardBg)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.buttonCornerRadius)
                .stroke(AppTheme.subtleBorder, lineWidth: 1)
        )
        .cornerRadius(AppTheme.buttonCornerRadius)
    }
}

private struct AnalyzeActionChip: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
            Text(title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(.white.opacity(0.7))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(AppTheme.cardBg)
        .overlay(
            Capsule()
                .stroke(AppTheme.subtleBorder, lineWidth: 1)
        )
        .clipShape(Capsule())
    }
}

private struct AnalyzePlainButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(.plain)
    }
}

private struct AnalyzeShareButton: View {
    let item: URL
    let icon: String
    let title: String

    var body: some View {
        ShareLink(item: item) {
            AnalyzeSecondaryButtonLabel(icon: icon, title: title)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Full Screen Preview

private enum AnalysisResultsTab: String, CaseIterable {
    case efficiency
    case power
}

struct AnalyzePreviewView: View {
    let videoURL: URL
    let poseEngineName: String
    let metrics: AnalysisMetrics?
    let series: MetricSeries?
    let userBodyHeightMeters: Double
    let processor: VideoProcessor
    let onClose: () -> Void
    let onNewAnalysis: () -> Void
    
    @AppStorage("useImperialUnits") private var useImperialUnits: Bool = true
    @State private var player: AVPlayer
    @StateObject private var playheadController = PlayheadController()
    @State private var timeObserver: Any?
    @State private var assetDurationSeconds: Double?
    @State private var showingSnapshot = false
    @State private var showScorecard = false
    @State private var scorecardDragOffset: CGFloat = 0
    @State private var snapshotImage: UIImage?
    @State private var csvExportURL: URL?
    @State private var resultsTab: AnalysisResultsTab = .efficiency
    
    init(
        videoURL: URL,
        poseEngineName: String,
        metrics: AnalysisMetrics?,
        series: MetricSeries?,
        userBodyHeightMeters: Double,
        processor: VideoProcessor,
        onClose: @escaping () -> Void,
        onNewAnalysis: @escaping () -> Void
    ) {
        self.videoURL = videoURL
        self.poseEngineName = poseEngineName
        self.metrics = metrics
        self.series = series
        self.userBodyHeightMeters = userBodyHeightMeters
        self.processor = processor
        self.onClose = onClose
        self.onNewAnalysis = onNewAnalysis
        _player = State(initialValue: AVPlayer(url: videoURL))
    }
    
    var body: some View {
        ZStack {
            AppTheme.bgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                previewHeader

                VideoPlayer(player: player)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
                    .padding(4)
                    .background(AppTheme.cardBg)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius + 2, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius + 2, style: .continuous)
                            .stroke(AppTheme.subtleBorder, lineWidth: 1)
                    )
                    .padding(.horizontal, AppTheme.screenPadding)
                    .padding(.bottom, 12)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        if let series = series {
                            let actualVideoDuration: Double = {
                                if let assetDurationSeconds = assetDurationSeconds, assetDurationSeconds > 0 {
                                    return assetDurationSeconds
                                }
                                if let duration = player.currentItem?.duration,
                                   duration.isValid && !duration.isIndefinite {
                                    return duration.seconds
                                }
                                let estimatedFrameRate = 30.0
                                let footHipSeries = !series.rightFootHipDistanceSeries.isEmpty
                                    ? series.rightFootHipDistanceSeries
                                    : series.leftFootHipDistanceSeries
                                return Double(footHipSeries.count) / estimatedFrameRate
                            }()

                            let footHipSeries = !series.rightFootHipDistanceSeries.isEmpty
                                ? series.rightFootHipDistanceSeries
                                : series.leftFootHipDistanceSeries

                            let actualFrameRate = actualVideoDuration > 0 && !footHipSeries.isEmpty
                                ? Double(footHipSeries.count) / actualVideoDuration
                                : 30.0

                            let localMaxima = Self.detectLocalMaxima(footHipSeries, frameRate: actualFrameRate)

                            let cadence = localMaxima.count >= 2
                                ? Self.calculateCadenceFromPeaks(localMaxima, frameRate: actualFrameRate)
                                : calculateCadenceFromFootHipDistance(
                                    footHipSeries,
                                    duration: actualVideoDuration,
                                    frameRate: actualFrameRate,
                                    cadenceSeries: series.cadenceSeries
                                )

                            HStack(spacing: 24) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("CADENCE")
                                        .font(.system(size: 10, weight: .heavy))
                                        .tracking(1.5)
                                        .foregroundColor(.white.opacity(0.35))
                                    Text("\(Int(cadence.rounded())) spm")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundColor(.white)
                                    Text("both feet")
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.4))
                                }

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("DURATION")
                                        .font(.system(size: 10, weight: .heavy))
                                        .tracking(1.5)
                                        .foregroundColor(.white.opacity(0.35))
                                    Text(String(format: "%.1f s", actualVideoDuration))
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundColor(.white)
                                }

                                Spacer()
                            }
                            .padding(.horizontal, AppTheme.screenPadding)
                            .padding(.top, 8)
                            .padding(.bottom, 12)

                            let (footHipUnit, footHipConverted) = convertPixelsToRealUnits(
                                series: footHipSeries,
                                bodyHeightPixels: series.bodyHeightPixels,
                                bodyHeightMeters: userBodyHeightMeters
                            )

                            GraphCard(
                                title: "Consistency",
                                series: footHipConverted,
                                unit: footHipUnit,
                                durationSeconds: actualVideoDuration,
                                events: [],
                                info: "Horizontal distance between foot and hip. Peaks indicate heel strike, troughs indicate toe-off. Values in \(footHipUnit == "in" ? "inches" : footHipUnit == "cm" ? "centimeters" : "pixels").",
                                playheadController: nil
                            )
                            .padding(.bottom, 12)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("FORM FOCUS")
                                    .font(.system(size: 10, weight: .heavy))
                                    .tracking(2)
                                    .foregroundColor(.white.opacity(0.35))
                                Picker("Form focus", selection: $resultsTab) {
                                    Text("Efficiency").tag(AnalysisResultsTab.efficiency)
                                    Text("Power").tag(AnalysisResultsTab.power)
                                }
                                .pickerStyle(.segmented)
                            }
                            .padding(.horizontal, AppTheme.screenPadding)
                            .padding(.bottom, 12)

                            let shinCue = series.formCueScores.first(where: { $0.cue == .shinVertical })
                            let perpendicularityData = decodePerpendicularityData(shinCue?.std ?? 0.0)
                            let footYSeries = !series.rightFootYTimeSeries.isEmpty
                                ? series.rightFootYTimeSeries
                                : series.leftFootYTimeSeries
                            let overstrideInfo = overstrideAssessment(
                                formCueScores: series.formCueScores,
                                footHipSeries: footHipSeries,
                                peaks: localMaxima,
                                frameRate: actualFrameRate,
                                hipYSeries: series.hipMovementYSeries,
                                footYSeries: footYSeries,
                                analysisStartTime: series.analysisStartTime,
                                videoDuration: actualVideoDuration,
                                shinSampleCount: perpendicularityData.sampleCount
                            )
                            let shinClassification = classifyShinStride(angle: overstrideInfo.shinAngle > 0.1 ? overstrideInfo.shinAngle : nil)
                            let shinStyle = styleForClassification(shinClassification)

                            let torsoAngle = series.torsoAngleMean
                            let torsoClassification = classifyTorsoAngle(angle: torsoAngle >= 0.1 ? torsoAngle : nil)
                            let torsoStyle = styleForTorsoClassification(torsoClassification)

                            let gazeAngle = series.headAngleMean
                            let gazeClassification = classifyHeadAngle(angle: gazeAngle >= 0.1 ? gazeAngle : nil)
                            let gazeStyle = styleForHeadClassification(gazeClassification)

                            let elbowAngle = series.elbowAngleMean
                            let elbowClassification = classifyElbowAngle(angle: elbowAngle > 0 ? elbowAngle : nil)
                            let elbowStyle = styleForElbowClassification(elbowClassification)

                            let footPlacementCue = series.formCueScores.first(where: { $0.cue == .footPlacement })
                            let footPlacementAngle = footPlacementCue?.rawValue
                            let footPlacementClassification = classifyFootPlacement(angle: footPlacementAngle)
                            let footPlacementTip = tipForFootPlacementClassification(footPlacementClassification)

                            Group {
                                switch resultsTab {
                                case .efficiency:
                                    VStack(spacing: 10) {
                                        SuggestionCard(
                                            metricName: "Stride",
                                            tip: shinStyle.tip,
                                            color: shinStyle.color,
                                            score: shinClassification.score
                                        )
                                        SuggestionCard(
                                            metricName: "Torso",
                                            tip: torsoStyle.tip,
                                            color: torsoStyle.color,
                                            score: torsoClassification.score
                                        )
                                        SuggestionCard(
                                            metricName: "Gaze",
                                            tip: gazeStyle.tip,
                                            color: gazeStyle.color,
                                            score: gazeClassification.score
                                        )
                                        SuggestionCard(
                                            metricName: "Arm Form",
                                            tip: elbowStyle.tip,
                                            color: elbowStyle.color,
                                            score: elbowClassification.score
                                        )
                                        FootPlacementCard(
                                            label: footPlacementClassification.label,
                                            tip: footPlacementTip
                                        )
                                    }
                                case .power:
                                    sprintSuggestionCards(series: series, metrics: metrics)
                                }
                            }
                            .padding(.horizontal, AppTheme.screenPadding)
                            .padding(.bottom, 12)
                        }

                        Spacer().frame(height: 40)
                    }
                }
            }

            if showScorecard {
                previewScorecardOverlay
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(40)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: showScorecard)
        .onAppear {
            if assetDurationSeconds == nil {
                Task {
                    let asset = AVAsset(url: videoURL)
                    if let duration = try? await asset.load(.duration), duration.isValid {
                        await MainActor.run {
                            assetDurationSeconds = duration.seconds
                        }
                    }
                }
            }
            // Start high-performance playhead controller using CADisplayLink (60fps)
            let analysisStart = series?.analysisStartTime ?? 0
            let duration = series?.durationSeconds ?? 0
            playheadController.start(
                player: player,
                analysisStartTime: analysisStart,
                durationSeconds: duration
            )
            // Generate HTML table export (.html) for phone-friendly scrolling
            if csvExportURL == nil, let series = series {
                csvExportURL = generateCSVExport(metrics: metrics, series: series, videoDuration: duration)
            }
        }
        .onDisappear {
            // Stop playhead controller
            playheadController.stop()
        }
        .sheet(isPresented: $showingSnapshot) {
            if let snapshot = snapshotImage {
                SnapshotView(image: snapshot, onDismiss: { showingSnapshot = false })
            }
        }
    }

    private var previewScorecardOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .onTapGesture { showScorecard = false }

            ScorecardShareScreen(onClose: { showScorecard = false })
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .offset(y: scorecardDragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            scorecardDragOffset = max(0, value.translation.height)
                        }
                        .onEnded { value in
                            if value.translation.height > 120 {
                                scorecardDragOffset = 0
                                showScorecard = false   // parent transition slides it down
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                                    scorecardDragOffset = 0
                                }
                            }
                        }
                )
        }
        .background(Color.clear)
    }

    private var previewHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(10)
                        .background(Color.white.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text("Analysis Results")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                Color.clear.frame(width: 36, height: 36)
            }
            .padding(.horizontal, AppTheme.screenPadding)
            .padding(.top, 12)

            AnalyzeActionChip(icon: "figure.run", title: previewEngineChipLabel)

            previewActionStrip
        }
        .padding(.bottom, 10)
        .background(AppTheme.bgColor)
    }

    private var previewEngineChipLabel: String {
        if let side = processor.selectedSide {
            let sideLabel = side == .right ? "Right side" : "Left side"
            return "\(sideLabel) · \(poseEngineName)"
        }
        return poseEngineName
    }

    private var previewActionStrip: some View {
        VStack(spacing: 10) {
            Button(action: { showScorecard = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.portrait.on.rectangle.portrait.fill")
                    Text("Scorecard")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(AppTheme.accentColor)
                .cornerRadius(16)
            }

            HStack(spacing: 10) {
                if let series = series, let firstStrikeIndex = series.heelStrikeFrameIndices.first {
                    AnalyzePlainButton(action: { captureSnapshot(at: findPeakStrideFrame(around: firstStrikeIndex)) }) {
                        AnalyzePrimaryButtonLabel(icon: "camera.fill", title: "Snapshot")
                    }
                }
                AnalyzePlainButton(action: onNewAnalysis) {
                    AnalyzePrimaryButtonLabel(icon: "plus.circle.fill", title: "New Analysis")
                }
            }

            HStack(spacing: 10) {
                AnalyzeShareButton(item: videoURL, icon: "arrow.down.circle", title: "Download Video")

                if let url = csvExportURL {
                    AnalyzeShareButton(item: url, icon: "tablecells", title: "Export Data")
                } else {
                    AnalyzeSecondaryButtonLabel(icon: "tablecells", title: "Preparing…")
                        .opacity(0.45)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(.horizontal, AppTheme.screenPadding)
        .padding(.top, 12)
    }
    
    // MARK: - Snapshot Functions
    
    private func findPeakStrideFrame(around heelStrikeIndex: Int) -> Int {
        let isLeft = processor.selectedSide == .left
        let kneeJoint: PoseJoint = isLeft ? .leftKnee : .rightKnee
        let ankleJoint: PoseJoint = isLeft ? .leftAnkle : .rightAnkle
        
        var bestIndex = heelStrikeIndex
        var bestAngle: Double = -1
        
        let lo = max(0, heelStrikeIndex - 3)
        let hi = heelStrikeIndex + 3
        
        for idx in lo...hi {
            guard let frame = processor.getPoseFrame(at: idx),
                  let knee = frame.points[kneeJoint],
                  let ankle = frame.points[ankleJoint] else { continue }
            let dx = Double(knee.x - ankle.x)
            let dy = Double(knee.y - ankle.y)
            let len = hypot(dx, dy)
            guard len > 0 else { continue }
            let dot = (dx * 0 + dy * (-1)) / len // dot with up (0,-1)
            let angle = abs(acos(max(-1, min(1, dot))) * 180 / .pi)
            if angle > bestAngle {
                bestAngle = angle
                bestIndex = idx
            }
        }
        return bestIndex
    }
    
    private func captureSnapshot(at frameIndex: Int) {
        guard let series = series,
              let poseFrame = processor.getPoseFrame(at: frameIndex) else {
            return
        }
        
        Task {
            // Calculate timestamp from frame index
            // Use the actual video duration and frame count to estimate frame rate
            let frameRate: Double = {
                if let assetDuration = assetDurationSeconds, assetDuration > 0 {
                    let totalFrames = max(series.rightFootHipDistanceSeries.count, series.leftFootHipDistanceSeries.count)
                    if totalFrames > 0 {
                        return Double(totalFrames) / assetDuration
                    }
                }
                return 30.0 // Fallback to 30 fps
            }()
            
            let timestamp = Double(frameIndex) / frameRate
            
            // Extract frame from video
            let frameImage = await extractFrame(at: CMTime(seconds: timestamp, preferredTimescale: 600), from: videoURL)
            
            // Render skeleton on the extracted frame; fall back to the raw frame so
            // the popup is never blank/white.
            if let frameImage = frameImage {
                let snapshot = renderSkeleton(on: frameImage, poseFrame: poseFrame, frameIndex: frameIndex, series: series)
                await MainActor.run {
                    snapshotImage = snapshot ?? frameImage
                    showingSnapshot = true
                }
            }
        }
    }

    private func extractFrame(at time: CMTime, from videoURL: URL) async -> UIImage? {
        let asset = AVAsset(url: videoURL)
        let imageGenerator = AVAssetImageGenerator(asset: asset)
        // A small tolerance lets the generator return the nearest frame instead of
        // failing (zero tolerance often throws and left the popup blank/white).
        imageGenerator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        imageGenerator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        imageGenerator.appliesPreferredTrackTransform = true
        
        do {
            let cgImage = try await imageGenerator.image(at: time).image
            return UIImage(cgImage: cgImage)
        } catch {
            debugLog("Failed to extract frame: \(error)")
            return nil
        }
    }
    
    private func renderSkeleton(on image: UIImage, poseFrame: PoseFrame, frameIndex: Int, series: MetricSeries) -> UIImage? {
        let size = image.size
        let connections: [(PoseJoint, PoseJoint)] = [
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
        
        // Near/right side + center in cyan, far/left in white (matches the video overlay).
        let skeletonRed = UIColor(red: 0, green: 0.90, blue: 1, alpha: 1)   // #00E5FF cyan
        func jointColor(for joint: PoseJoint) -> UIColor {
            switch joint {
            case .nose, .neck:
                return .white
            default:
                if joint.isLeft { return .white }
                return skeletonRed
            }
        }

        func connectionColor(for connection: (PoseJoint, PoseJoint)) -> UIColor {
            if (connection.0.isLeft || connection.1.isLeft),
               !(connection.0.isRight || connection.1.isRight) {
                return .white
            }
            return skeletonRed
        }
        
        let renderer = UIGraphicsImageRenderer(size: size)
        
        return renderer.image { context in
            // Draw original image
            image.draw(in: CGRect(origin: .zero, size: size))
            
            let cgContext = context.cgContext
            let points = poseFrame.points
            
            // Draw skeleton if we have points
            if !points.isEmpty {
                // Draw connections
                cgContext.setLineWidth(7.0)
                cgContext.setLineCap(.round)
                
                for connection in connections {
                    guard let start = points[connection.0], let end = points[connection.1] else { continue }
                    let color = connectionColor(for: connection)
                    cgContext.setStrokeColor(color.cgColor)
                    cgContext.move(to: start)
                    cgContext.addLine(to: end)
                    cgContext.strokePath()
                }
                
                // Draw joints
                for (jointName, point) in points {
                    let color = jointColor(for: jointName)
                    cgContext.setFillColor(color.cgColor)
                    
                    let radius: CGFloat = 8.0
                    cgContext.fillEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                    
                    cgContext.setStrokeColor(UIColor.white.cgColor)
                    cgContext.setLineWidth(2.0)
                    cgContext.strokeEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                }
                
                func drawAngleAnnotation(angleString: String, label: String, at jointPoint: CGPoint, color: UIColor, offset: CGPoint) {
                    let angleFontSize: CGFloat = max(17, size.width * 0.022)
                    let labelFontSize: CGFloat = max(11, size.width * 0.014)
                    let angleAttrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.boldSystemFont(ofSize: angleFontSize),
                        .foregroundColor: color
                    ]
                    let labelAttrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: labelFontSize, weight: .medium),
                        .foregroundColor: UIColor.white.withAlphaComponent(0.95)
                    ]
                    let angleNs = angleString as NSString
                    let labelNs = label as NSString
                    let angleSize = angleNs.size(withAttributes: angleAttrs)
                    let labelSize = labelNs.size(withAttributes: labelAttrs)
                    let lineSpacing: CGFloat = 2
                    let padding: CGFloat = 6
                    let totalWidth = max(angleSize.width, labelSize.width) + padding * 2
                    let totalHeight = angleSize.height + lineSpacing + labelSize.height + padding * 2
                    let origin = CGPoint(
                        x: jointPoint.x + offset.x - totalWidth / 2,
                        y: jointPoint.y + offset.y - totalHeight / 2
                    )
                    let blockRect = CGRect(origin: origin, size: CGSize(width: totalWidth, height: totalHeight))
                    cgContext.saveGState()
                    let bgPath = UIBezierPath(roundedRect: blockRect, cornerRadius: 6)
                    cgContext.setFillColor(UIColor.black.withAlphaComponent(0.75).cgColor)
                    cgContext.addPath(bgPath.cgPath)
                    cgContext.fillPath()
                    cgContext.restoreGState()
                    var y = origin.y + padding
                    angleNs.draw(at: CGPoint(x: origin.x + padding, y: y), withAttributes: angleAttrs)
                    y += angleSize.height + lineSpacing
                    labelNs.draw(at: CGPoint(x: origin.x + padding, y: y), withAttributes: labelAttrs)
                }
                
                func bandColor(for band: Any) -> UIColor {
                    switch band {
                    case let s as ShinStrideBand:
                        switch s {
                        case .goodStride: return .systemGreen
                        case .mildOverstride, .understride: return .systemYellow
                        case .moderateOverstride: return .systemOrange
                        case .severeOverstride: return .systemRed
                        case .unknown: return .gray
                        }
                    case let t as TorsoAngleBand:
                        switch t {
                        case .optimal, .good: return .systemGreen
                        case .tooUpright: return .systemYellow
                        case .moderateLean: return .systemOrange
                        case .excessive: return .systemRed
                        case .unknown: return .gray
                        }
                    case let h as HeadAngleBand:
                        switch h {
                        case .lookingAhead: return .systemGreen
                        case .slightDownward: return .systemYellow
                        case .moderateDownward: return .systemOrange
                        case .excessive: return .systemRed
                        case .unknown: return .gray
                        }
                    case let e as ElbowAngleBand:
                        switch e {
                        case .optimal, .good: return .systemGreen
                        case .tooTight: return .systemYellow
                        case .slightlyOpen: return .systemOrange
                        case .tooStraight: return .systemRed
                        case .unknown: return .gray
                        }
                    default: return .gray
                    }
                }
                
                let isLeft = processor.selectedSide == .left
                
                // Interior angle at vertex b between segments b→a and b→c
                func angleBetweenVectors(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
                    let ba = CGVector(dx: a.x - b.x, dy: a.y - b.y)
                    let bc = CGVector(dx: c.x - b.x, dy: c.y - b.y)
                    let dot = ba.dx * bc.dx + ba.dy * bc.dy
                    let mag = hypot(ba.dx, ba.dy) * hypot(bc.dx, bc.dy)
                    guard mag > 0 else { return 0 }
                    let cosVal = max(-1.0, min(1.0, Double(dot) / Double(mag)))
                    return acos(cosVal) * 180 / .pi
                }
                
                // Draw a dashed reference line + colored arc showing the measured angle.
                // Angles are in screen-space atan2 (Y-down): atan2(dy_screen, dx).
                func drawAngleArc(center: CGPoint, refAngle: CGFloat, measuredAngle: CGFloat, arcRadius: CGFloat, color: UIColor, refLength: CGFloat = 50) {
                    cgContext.saveGState()
                    
                    // Dashed reference line
                    let refEnd = CGPoint(
                        x: center.x + cos(refAngle) * refLength,
                        y: center.y + sin(refAngle) * refLength
                    )
                    cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.5).cgColor)
                    cgContext.setLineWidth(1.5)
                    cgContext.setLineDash(phase: 0, lengths: [4, 4])
                    cgContext.move(to: center)
                    cgContext.addLine(to: refEnd)
                    cgContext.strokePath()
                    cgContext.setLineDash(phase: 0, lengths: [])
                    
                    // Shorter arc between refAngle and measuredAngle
                    var diff = measuredAngle - refAngle
                    while diff > .pi { diff -= 2 * .pi }
                    while diff < -.pi { diff += 2 * .pi }
                    // In UIKit flipped coords: clockwise:true = counter-clockwise on screen
                    let cw = diff < 0
                    cgContext.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
                    cgContext.setLineWidth(2.5)
                    cgContext.addArc(center: center, radius: arcRadius, startAngle: refAngle, endAngle: measuredAngle, clockwise: cw)
                    cgContext.strokePath()
                    
                    cgContext.restoreGState()
                }
                
                // Elbow arc (no reference line — the arm segments are the reference)
                func drawElbowArc(center: CGPoint, angle1: CGFloat, angle2: CGFloat, arcRadius: CGFloat, color: UIColor) {
                    cgContext.saveGState()
                    var diff = angle2 - angle1
                    while diff > .pi { diff -= 2 * .pi }
                    while diff < -.pi { diff += 2 * .pi }
                    let cw = diff < 0
                    cgContext.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
                    cgContext.setLineWidth(2.5)
                    cgContext.addArc(center: center, radius: arcRadius, startAngle: angle1, endAngle: angle2, clockwise: cw)
                    cgContext.strokePath()
                    cgContext.restoreGState()
                }
                
                // ===== SHIN ANGLE (recomputed: deviation from vertical) =====
                let kneeJoint: PoseJoint = isLeft ? .leftKnee : .rightKnee
                let ankleJoint: PoseJoint = isLeft ? .leftAnkle : .rightAnkle
                if let knee = points[kneeJoint], let ankle = points[ankleJoint] {
                    let shinVec = CGPoint(x: knee.x - ankle.x, y: knee.y - ankle.y)
                    let shinLen = hypot(Double(shinVec.x), Double(shinVec.y))
                    let shinAngle: Double = {
                        guard shinLen > 0 else { return 0 }
                        let norm = CGPoint(x: shinVec.x / CGFloat(shinLen), y: shinVec.y / CGFloat(shinLen))
                        let dot = Double(norm.x * 0 + norm.y * (-1))
                        return abs(acos(max(-1, min(1, dot))) * 180 / .pi)
                    }()
                    let cls = classifyShinStride(angle: shinAngle)
                    let color = bandColor(for: cls.band)
                    
                    let verticalAngle: CGFloat = -.pi / 2 // straight up in screen-space atan2
                    let shinScreenAngle = atan2(knee.y - ankle.y, knee.x - ankle.x)
                    drawAngleArc(center: ankle, refAngle: verticalAngle, measuredAngle: shinScreenAngle, arcRadius: 30, color: color)
                    
                    drawAngleAnnotation(angleString: String(format: "%.1f°", shinAngle), label: "Shin Tilt · \(cls.label)", at: knee, color: color, offset: CGPoint(x: isLeft ? -80 : 80, y: 0))
                }
                
                // ===== KNEE ANGLE (hip-knee-ankle interior angle) =====
                let hipForKnee: PoseJoint = isLeft ? .leftHip : .rightHip
                if let hipPt = points[hipForKnee], let kneePt = points[kneeJoint], let anklePt = points[ankleJoint] {
                    let kneeAngle = angleBetweenVectors(hipPt, kneePt, anklePt)
                    let kneeColor: UIColor = kneeAngle >= 155 ? .systemGreen : (kneeAngle >= 140 ? .systemYellow : .systemOrange)
                    
                    let thighAngle = atan2(hipPt.y - kneePt.y, hipPt.x - kneePt.x)
                    let shinAngleAtKnee = atan2(anklePt.y - kneePt.y, anklePt.x - kneePt.x)
                    drawElbowArc(center: kneePt, angle1: thighAngle, angle2: shinAngleAtKnee, arcRadius: 28, color: kneeColor)
                    
                    drawAngleAnnotation(angleString: String(format: "%.0f°", kneeAngle), label: "Knee Angle", at: kneePt, color: kneeColor, offset: CGPoint(x: isLeft ? 80 : -80, y: 0))
                }
                
                // ===== TORSO ANGLE (recomputed from shoulder/hip points) =====
                let shoulderJoint: PoseJoint = isLeft ? .leftShoulder : .rightShoulder
                let hipJoint: PoseJoint = isLeft ? .leftHip : .rightHip
                
                // Prefer bilateral midpoints when both sides are available
                let torsoShoulder: CGPoint? = {
                    if let ls = points[.leftShoulder], let rs = points[.rightShoulder] {
                        return CGPoint(x: (ls.x + rs.x) / 2, y: (ls.y + rs.y) / 2)
                    }
                    return points[shoulderJoint]
                }()
                let torsoHip: CGPoint? = {
                    if let lh = points[.leftHip], let rh = points[.rightHip] {
                        return CGPoint(x: (lh.x + rh.x) / 2, y: (lh.y + rh.y) / 2)
                    }
                    return points[hipJoint]
                }()
                
                if let shoulder = torsoShoulder, let hip = torsoHip {
                    let vec = CGPoint(x: shoulder.x - hip.x, y: shoulder.y - hip.y)
                    let torsoAngle = abs(atan2(Double(vec.x), Double(-vec.y)) * 180 / .pi)
                    let cls = classifyTorsoAngle(angle: torsoAngle)
                    let color = bandColor(for: cls.band)
                    
                    let verticalAngle: CGFloat = -.pi / 2
                    let torsoScreenAngle = atan2(shoulder.y - hip.y, shoulder.x - hip.x)
                    let arcCenter = points[hipJoint] ?? hip
                    drawAngleArc(center: arcCenter, refAngle: verticalAngle, measuredAngle: torsoScreenAngle, arcRadius: 35, color: color)
                    
                    drawAngleAnnotation(angleString: String(format: "%.1f°", torsoAngle), label: "Trunk Lean · \(cls.label)", at: arcCenter, color: color, offset: CGPoint(x: isLeft ? -90 : 90, y: -20))
                }
                
                // ===== ELBOW ANGLE (recomputed from shoulder/elbow/wrist points) =====
                let elbowJoint: PoseJoint = isLeft ? .leftElbow : .rightElbow
                let shoulderForElbow: PoseJoint = isLeft ? .leftShoulder : .rightShoulder
                let wristJoint: PoseJoint = isLeft ? .leftWrist : .rightWrist
                if let s = points[shoulderForElbow], let e = points[elbowJoint], let w = points[wristJoint] {
                    let elbowAngle = angleBetweenVectors(s, e, w)
                    let cls = classifyElbowAngle(angle: elbowAngle)
                    let color = bandColor(for: cls.band)
                    
                    let armAngle = atan2(s.y - e.y, s.x - e.x)
                    let forearmAngle = atan2(w.y - e.y, w.x - e.x)
                    drawElbowArc(center: e, angle1: armAngle, angle2: forearmAngle, arcRadius: 25, color: color)
                    
                    drawAngleAnnotation(angleString: String(format: "%.0f°", elbowAngle), label: "Elbow Angle · \(cls.label)", at: e, color: color, offset: CGPoint(x: isLeft ? -80 : 80, y: -25))
                }
                
                // ===== GAZE ANGLE (recomputed from ear/nose — raw, no baseline correction) =====
                let earJoint: PoseJoint = isLeft ? .leftEar : .rightEar
                if let ear = points[earJoint], let nose = points[.nose] {
                    let dx = Double(nose.x - ear.x)
                    let dy = Double(nose.y - ear.y)
                    let gazeAngle: Double = {
                        guard abs(dx) > 1.0 else { return 0.0 }
                        return abs(atan2(dy, abs(dx)) * 180 / .pi)
                    }()
                    let cls = classifyHeadAngle(angle: gazeAngle)
                    let color = bandColor(for: cls.band)
                    
                    let horizAngle: CGFloat = dx > 0 ? 0 : .pi // horizontal toward nose
                    let noseScreenAngle = atan2(nose.y - ear.y, nose.x - ear.x)
                    drawAngleArc(center: ear, refAngle: horizAngle, measuredAngle: noseScreenAngle, arcRadius: 25, color: color, refLength: 40)
                    
                    drawAngleAnnotation(angleString: String(format: "%.1f°", gazeAngle), label: "Head Tilt · \(cls.label)", at: ear, color: color, offset: CGPoint(x: isLeft ? -70 : 70, y: -30))
                }
            }
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
        // Note: playbackTime removed - cursor now driven by playheadController
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
        
        return LazyVStack(alignment: .leading, spacing: 18) {
            // Overall Form Score
            if let series = series {
                let formScore = calculateFormScore(series: series, metrics: metrics)
                FormScoreView(score: formScore)
                    .padding(.bottom, 8)
            }
            
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
                    title: "Knee Flexion: Gait Cycle",
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
                    title: "Knee Flexion: Time Series",
                    leftSeries: series?.leftKneeAngleTimeSeries ?? [],
                    rightSeries: series?.rightKneeAngleTimeSeries ?? [],
                    unit: "°",
                    durationSeconds: duration,
                    playheadController: playheadController,
                    isEstimate: true,
                    events: eventMarkers,
                    info: "Knee flexion angle over the full video duration. Cursor syncs with video playback."
                )
                
                // Hip Flexion
                GaitCycleGraphCard(
                    title: "Hip Flexion: Gait Cycle",
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
                    title: "Hip Flexion: Time Series",
                    leftSeries: series?.leftHipAngleTimeSeries ?? [],
                    rightSeries: series?.rightHipAngleTimeSeries ?? [],
                    unit: "°",
                    durationSeconds: duration,
                    playheadController: playheadController,
                    isEstimate: true,
                    events: eventMarkers,
                    info: "Hip flexion angle over the full video duration. Cursor syncs with video playback."
                )
                
                // Ankle Dorsiflexion
                GaitCycleGraphCard(
                    title: "Ankle Dorsiflexion: Gait Cycle",
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
                    title: "Ankle Dorsiflexion: Time Series",
                    leftSeries: series?.leftAnkleAngleTimeSeries ?? [],
                    rightSeries: series?.rightAnkleAngleTimeSeries ?? [],
                    unit: "°",
                    durationSeconds: duration,
                    playheadController: playheadController,
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
            
            // Movement analysis graphs - always show these
            // Convert to real-world units if user has entered their height
            let (footPosUnit, footPosSeries) = convertToRealUnits(
                series: series?.rightFootYTimeSeries ?? [],
                bodyHeightMeters: userBodyHeightMeters
            )
            GraphCard(
                title: "Foot Position (Right)",
                series: footPosSeries,
                unit: footPosUnit,
                durationSeconds: duration,
                events: eventMarkers,
                info: "Right foot vertical position relative to mean. Shows foot clearance and ground contact phases.",
                playheadController: playheadController
            )
            
            GraphCard(
                title: "Foot Velocity (Y Direction)",
                series: (series?.leftFootVelTimeSeries ?? []) + (series?.rightFootVelTimeSeries ?? []),
                unit: "m/s",
                durationSeconds: duration,
                events: eventMarkers,
                info: "Vertical foot velocity over time. Positive values indicate upward movement, negative values indicate downward movement.",
                playheadController: playheadController
            )
            
            let (hipUnit, hipSeries) = convertToRealUnits(
                series: series?.hipMovementYSeries ?? [],
                bodyHeightMeters: userBodyHeightMeters
            )
            GraphCard(
                title: "Hip Movement (Vertical)",
                series: hipSeries,
                unit: hipUnit,
                durationSeconds: duration,
                events: eventMarkers,
                info: "Hip vertical position relative to mean. Shows vertical oscillation and stability.",
                playheadController: playheadController
            )
            
            let (headUnit, headSeries) = convertToRealUnits(
                series: series?.headBobbingYSeries ?? [],
                bodyHeightMeters: userBodyHeightMeters
            )
            GraphCard(
                title: "Head Bobbing (Vertical)",
                series: headSeries,
                unit: headUnit,
                durationSeconds: duration,
                events: eventMarkers,
                info: "Head vertical position relative to mean. Excessive bobbing indicates inefficient running form.",
                playheadController: playheadController
            )
            
            let (armUnit, armSeries) = convertToRealUnits(
                series: series?.armMovementXSeries ?? [],
                bodyHeightMeters: userBodyHeightMeters
            )
            GraphCard(
                title: "Arm Movement (Horizontal)",
                series: armSeries,
                unit: armUnit,
                durationSeconds: duration,
                events: eventMarkers,
                info: "Arm swing horizontal position relative to mean. Shows arm swing symmetry and range.",
                playheadController: playheadController
            )
        }
    }
    
    // MARK: - Unit Conversion Helper
    
    /// Convert body-height-normalized series to real-world units
    private func convertToRealUnits(series: [Double], bodyHeightMeters: Double) -> (String, [Double]) {
        guard bodyHeightMeters > 0 else { return ("bh", series) }
        // Convert to centimeters (always metric for movement graphs)
        let converted = series.map { $0.isNaN ? Double.nan : $0 * bodyHeightMeters * 100 }
        return ("cm", converted)
    }
    
    /// Convert pixel-based series to real-world units
    private func convertPixelsToRealUnits(series: [Double], bodyHeightPixels: Double, bodyHeightMeters: Double) -> (String, [Double]) {
        guard bodyHeightPixels > 0, bodyHeightMeters > 0 else { return ("px", series) }
        let metersPerPixel = bodyHeightMeters / bodyHeightPixels
        
        if useImperialUnits {
            let inchesPerPixel = metersPerPixel * 39.3701
            let converted = series.map { $0.isNaN ? Double.nan : $0 * inchesPerPixel }
            return ("in", converted)
        } else {
            let cmPerPixel = metersPerPixel * 100
            let converted = series.map { $0.isNaN ? Double.nan : $0 * cmPerPixel }
            return ("cm", converted)
        }
    }
    
    /// Max sample count across series exported in TABLE 6 (split from array literal to help the type checker).
    private func csvExportMaxFrameCount(_ series: MetricSeries) -> Int {
        var m = 0
        m = max(m, series.leftFootHipDistanceSeries.count)
        m = max(m, series.rightFootHipDistanceSeries.count)
        m = max(m, series.leftKneeAngleTimeSeries.count)
        m = max(m, series.rightKneeAngleTimeSeries.count)
        m = max(m, series.leftHipAngleTimeSeries.count)
        m = max(m, series.rightHipAngleTimeSeries.count)
        m = max(m, series.leftAnkleAngleTimeSeries.count)
        m = max(m, series.rightAnkleAngleTimeSeries.count)
        m = max(m, series.leftFootYTimeSeries.count)
        m = max(m, series.rightFootYTimeSeries.count)
        m = max(m, series.leftFootVelTimeSeries.count)
        m = max(m, series.rightFootVelTimeSeries.count)
        m = max(m, series.hipMovementYSeries.count)
        m = max(m, series.headBobbingYSeries.count)
        m = max(m, series.armMovementXSeries.count)
        m = max(m, series.footVelocityXSeries.count)
        m = max(m, series.cadenceSeries.count)
        m = max(m, series.groundContactLeftSeries.count)
        m = max(m, series.groundContactRightSeries.count)
        m = max(m, series.verticalOscillationSeries.count)
        m = max(m, series.hipDropSeries.count)
        m = max(m, series.perFrameTorsoAngles.count)
        m = max(m, series.perFrameGazeAngles.count)
        m = max(m, series.perFrameElbowAngles.count)
        return m
    }
    
    /// Holds TABLE 6 column presence flags (keeps `generateCSVExport` small for the type checker).
    private struct CSVTable6Columns {
        let hasLeftFootHip: Bool
        let hasRightFootHip: Bool
        let hasLeftKnee: Bool
        let hasRightKnee: Bool
        let hasLeftHip: Bool
        let hasRightHip: Bool
        let hasLeftAnkle: Bool
        let hasRightAnkle: Bool
        let hasLeftFootY: Bool
        let hasRightFootY: Bool
        let hasLeftFootVel: Bool
        let hasRightFootVel: Bool
        let hasHipY: Bool
        let hasHeadY: Bool
        let hasArmX: Bool
        let hasFootVelX: Bool
        let hasCadence: Bool
        let hasGctL: Bool
        let hasGctR: Bool
        let hasVertOsc: Bool
        let hasHipDrop: Bool
        let hasTorsoPF: Bool
        let hasGazePF: Bool
        let hasElbowPF: Bool
    }
    
    private func csvExportCollectPerFrameRows(
        series: MetricSeries,
        maxFrames: Int,
        frameRate: Double,
        distFactor: Double,
        cols: CSVTable6Columns
    ) -> [[String]] {
        func val(_ arr: [Double], _ i: Int) -> String {
            guard i < arr.count else { return "" }
            let v = arr[i]
            return v.isNaN ? "" : String(format: "%.6g", v)
        }
        func valPx(_ arr: [Double], _ i: Int) -> String {
            guard i < arr.count else { return "" }
            let v = arr[i]
            guard !v.isNaN else { return "" }
            return distFactor > 0 ? String(format: "%.4f", v * distFactor) : String(format: "%.4f", v)
        }
        var allRows: [[String]] = []
        for i in 0..<maxFrames {
            var row: [String] = []
            row.append("\(i)")
            row.append(String(format: "%.6f", Double(i) / frameRate))
            if cols.hasLeftFootHip { row.append(valPx(series.leftFootHipDistanceSeries, i)) }
            if cols.hasRightFootHip { row.append(valPx(series.rightFootHipDistanceSeries, i)) }
            if cols.hasLeftKnee { row.append(val(series.leftKneeAngleTimeSeries, i)) }
            if cols.hasRightKnee { row.append(val(series.rightKneeAngleTimeSeries, i)) }
            if cols.hasLeftHip { row.append(val(series.leftHipAngleTimeSeries, i)) }
            if cols.hasRightHip { row.append(val(series.rightHipAngleTimeSeries, i)) }
            if cols.hasLeftAnkle { row.append(val(series.leftAnkleAngleTimeSeries, i)) }
            if cols.hasRightAnkle { row.append(val(series.rightAnkleAngleTimeSeries, i)) }
            if cols.hasLeftFootY { row.append(val(series.leftFootYTimeSeries, i)) }
            if cols.hasRightFootY { row.append(val(series.rightFootYTimeSeries, i)) }
            if cols.hasLeftFootVel { row.append(val(series.leftFootVelTimeSeries, i)) }
            if cols.hasRightFootVel { row.append(val(series.rightFootVelTimeSeries, i)) }
            if cols.hasHipY { row.append(val(series.hipMovementYSeries, i)) }
            if cols.hasHeadY { row.append(val(series.headBobbingYSeries, i)) }
            if cols.hasArmX { row.append(val(series.armMovementXSeries, i)) }
            if cols.hasFootVelX { row.append(val(series.footVelocityXSeries, i)) }
            if cols.hasCadence { row.append(val(series.cadenceSeries, i)) }
            if cols.hasGctL { row.append(val(series.groundContactLeftSeries, i)) }
            if cols.hasGctR { row.append(val(series.groundContactRightSeries, i)) }
            if cols.hasVertOsc { row.append(val(series.verticalOscillationSeries, i)) }
            if cols.hasHipDrop { row.append(val(series.hipDropSeries, i)) }
            if cols.hasTorsoPF { row.append(val(series.perFrameTorsoAngles, i)) }
            if cols.hasGazePF { row.append(val(series.perFrameGazeAngles, i)) }
            if cols.hasElbowPF { row.append(val(series.perFrameElbowAngles, i)) }
            allRows.append(row)
        }
        return allRows
    }
    
    private func exportHtmlEscape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    
    /// Real `<table>` export; use `allowHorizontalScroll` for many columns (e.g. per-frame series) so phones can pan sideways.
    private func exportHtmlTable(
        heading: String,
        subheading: String? = nil,
        headers: [String],
        rows: [[String]],
        allowHorizontalScroll: Bool = false
    ) -> String {
        let colCount = headers.count
        guard colCount > 0 else {
            return "<section><h2>\(exportHtmlEscape(heading))</h2><p class=\"muted\">(empty)</p></section>\n"
        }
        let headerCells = headers.map { "<th>\(exportHtmlEscape($0))</th>" }.joined()
        var bodyRows = ""
        for row in rows {
            var r = row
            while r.count < colCount { r.append("") }
            if r.count > colCount { r = Array(r.prefix(colCount)) }
            bodyRows += "<tr>" + r.map { "<td>\(exportHtmlEscape($0))</td>" }.joined() + "</tr>\n"
        }
        let sub = subheading.map { "<p class=\"hint\">\(exportHtmlEscape($0))</p>\n" } ?? ""
        let wrapClass = allowHorizontalScroll ? "tblwrap tblwrap-scroll" : "tblwrap"
        return """
        <section>
        <h2>\(exportHtmlEscape(heading))</h2>
        \(sub)<div class="\(wrapClass)">
        <table>
        <thead><tr>\(headerCells)</tr></thead>
        <tbody>\(bodyRows)</tbody>
        </table>
        </div>
        </section>
        
        """
    }
    
    private func exportHtmlDocument(title: String, intro: String, sections: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <meta name="color-scheme" content="dark light">
        <title>\(exportHtmlEscape(title))</title>
        <style>
          :root { color-scheme: dark light; }
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; margin: 0; padding: 16px; padding-bottom: max(28px, env(safe-area-inset-bottom)); background: #000; color: #f5f5f7; font-size: 16px; line-height: 1.4; -webkit-text-size-adjust: 100%; }
          @media (prefers-color-scheme: light) {
            body { background: #f2f2f7; color: #1c1c1e; }
            .tblwrap { border-color: #c6c6c8 !important; }
            th, td { border-color: #c6c6c8 !important; }
            th { background: #e5e5ea !important; }
            tr:nth-child(even) td { background: #fafafa; }
          }
          h1 { font-size: 1.4rem; font-weight: 650; margin: 0 0 10px; letter-spacing: -0.02em; }
          .intro { color: #98989d; font-size: 0.92rem; margin: 0 0 8px; max-width: 36rem; }
          @media (prefers-color-scheme: light) { .intro { color: #636366; } }
          h2 { font-size: 1.08rem; font-weight: 600; margin: 22px 0 8px; color: #c8ff7a; }
          @media (prefers-color-scheme: light) { h2 { color: #3d5c00; } }
          .hint { font-size: 0.82rem; color: #8e8e93; margin: 0 0 10px; max-width: 36rem; }
          @media (prefers-color-scheme: light) { .hint { color: #636366; } }
          .muted { color: #8e8e93; }
          .tblwrap { margin: 0 0 12px; border-radius: 12px; border: 1px solid #3a3a3c; overflow: hidden; }
          .tblwrap-scroll { overflow-x: auto; overflow-y: hidden; -webkit-overflow-scrolling: touch; overscroll-behavior-x: contain; }
          .tblwrap-scroll table { width: max-content; min-width: 100%; }
          table { width: 100%; border-collapse: collapse; font-size: 13px; }
          th, td { border: 1px solid #48484a; padding: 8px 10px; text-align: left; vertical-align: top; word-break: break-word; hyphens: auto; }
          th { background: #2c2c2e; font-weight: 600; }
          tr:nth-child(even) td { background: #141414; }
        </style>
        </head>
        <body>
        <h1>\(exportHtmlEscape(title))</h1>
        <p class="intro">\(exportHtmlEscape(intro))</p>
        \(sections)
        </body>
        </html>
        """
    }
    
    // MARK: - Export (HTML tables, phone-friendly)
    
    /// Single `.html` file: bordered tables, pinch/zoom and horizontal scroll for wide data. Open in Safari or Quick Look.
    private func generateCSVExport(metrics: AnalysisMetrics?, series: MetricSeries, videoDuration: Double) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let exportURL = tempDir.appendingPathComponent("form_analysis_\(Int(Date().timeIntervalSince1970)).html")
        
        func statsForSeries(_ arr: [Double]) -> (count: Int, mean: Double, std: Double, minV: Double, maxV: Double) {
            let v = arr.filter { $0.isFinite && !$0.isNaN }
            guard !v.isEmpty else { return (0, 0, 0, 0, 0) }
            let mean = v.reduce(0, +) / Double(v.count)
            let minV = v.min() ?? 0
            let maxV = v.max() ?? 0
            let variance = v.count > 1
                ? v.reduce(0) { $0 + pow($1 - mean, 2) } / Double(v.count - 1)
                : 0
            return (v.count, mean, sqrt(variance), minV, maxV)
        }
        
        let metersPerPixel = series.bodyHeightPixels > 0 ? userBodyHeightMeters / series.bodyHeightPixels : 0
        let distUnit = useImperialUnits ? "in" : "cm"
        let distFactor = useImperialUnits ? metersPerPixel * 39.3701 : metersPerPixel * 100
        
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        
        var sections = ""
        sections += exportHtmlTable(
            heading: "Notes",
            headers: ["Topic", "Detail"],
            rows: [
                ["Generated (UTC)", isoFormatter.string(from: Date())],
                ["Analysis", "Efficiency + power (unified); same pass as in the app"],
                ["Power score", "Combines landing quality, support timing, leg spring, drive & flight ROM, posture, and arm counterbalance — same weighting as the in-app Power dial."],
                ["Foot–hip distance unit", "\(distUnit) (from height & body scale)"],
                ["bh", "Fraction of body height (normalized)"],
                ["Per-frame time", "Seconds from start of analyzed segment (same window as in-app graphs)"]
            ]
        )
        
        let table1Rows: [[String]] = [
            ["Analyzed segment duration", String(format: "%.3f", videoDuration), "seconds", "Trimmed analysis window"],
            ["Analysis start offset (video)", String(format: "%.3f", series.analysisStartTime), "seconds", "Time into original clip"],
            ["User body height", String(format: "%.3f", userBodyHeightMeters), "meters", ""],
            ["Estimated body height (pixels)", String(format: "%.2f", series.bodyHeightPixels), "pixels", "Pixel→real distance"],
            ["Scale (meters per pixel)", String(format: "%.6f", series.bodyHeightPixels > 0 ? userBodyHeightMeters / series.bodyHeightPixels : 0), "m/px", ""]
        ]
        sections += exportHtmlTable(
            heading: "Table 1 — Session and calibration",
            headers: ["Field", "Value", "Unit", "Notes"],
            rows: table1Rows
        )
        
        let scoreByCue: [FormCue: FormCueScore] = Dictionary(uniqueKeysWithValues: series.formCueScores.map { ($0.cue, $0) })
        var table2Rows: [[String]] = []
        for cue in FormCue.allCases {
            if let s = scoreByCue[cue] {
                let note = cue == .shinVertical
                    ? "Std may be app-encoded; use Mean for shin context"
                    : ""
                table2Rows.append([
                    cue.rawValue,
                    String(format: "%.1f", s.score),
                    String(format: "%.6g", s.mean),
                    String(format: "%.6g", s.std),
                    String(format: "%.6g", s.rawValue),
                    note
                ])
            } else {
                table2Rows.append([cue.rawValue, "", "", "", "", ""])
            }
        }
        sections += exportHtmlTable(
            heading: "Table 2 — Form cue scores (0–100)",
            headers: ["Cue", "Score", "Mean", "StdDev/enc.", "Raw", "Notes"],
            rows: table2Rows
        )
        
        // ── TABLE 3: Classifications & composite scores ──
        let effBD = computeEfficiencyBreakdown(series: series)
        let shinCue = series.formCueScores.first(where: { $0.cue == .shinVertical })
        let shinAngle = shinCue?.mean ?? 0
        let shinClassification = effBD?.shin ?? classifyShinStride(angle: shinAngle > 0.1 ? shinAngle : nil)
        let torsoAngle = series.torsoAngleMean
        let torsoClassification = effBD?.torso ?? classifyTorsoAngle(angle: torsoAngle >= 0.1 ? torsoAngle : nil)
        let gazeAngle = series.headAngleMean
        let gazeClassification = effBD?.gaze ?? classifyHeadAngle(angle: gazeAngle >= 0.1 ? gazeAngle : nil)
        let elbowAngle = series.elbowAngleMean
        let elbowClassification = effBD?.elbow ?? classifyElbowAngle(angle: elbowAngle > 0 ? elbowAngle : nil)
        let footPlacementCue = series.formCueScores.first(where: { $0.cue == .footPlacement })
        let footPlacementAngle = footPlacementCue?.rawValue ?? 0
        let footPlacementClassification = classifyFootPlacement(angle: abs(footPlacementAngle) > 0.1 ? footPlacementAngle : nil)
        let efficiencyScore = effBD?.averageDouble ?? Double(shinClassification.score + torsoClassification.score + gazeClassification.score + elbowClassification.score) / 4.0
        
        let sprintBreakdown: SprintPowerBreakdown? = metrics.map { computeSprintPowerBreakdown(series: series, metrics: $0, userBodyHeightMeters: userBodyHeightMeters) }
        let sprintPowerWeighted = sprintBreakdown?.composite
        
        let footNote = "Positive deg: heel lower than forefoot (image coords); ~0 midfoot"
        let table3Rows: [[String]] = [
            ["Stride / shin at contact", String(format: "%.2f", shinAngle), "deg", shinClassification.label, "\(shinClassification.score)", "Shin vs vertical at contact"],
            ["Torso lean", String(format: "%.2f", torsoAngle), "deg", torsoClassification.label, "\(torsoClassification.score)", "Mean trunk lean vs vertical"],
            ["Gaze / head tilt", String(format: "%.2f", gazeAngle), "deg", gazeClassification.label, "\(gazeClassification.score)", "Mean gaze vs baseline"],
            ["Arm form (elbow)", String(format: "%.2f", elbowAngle), "deg", elbowClassification.label, "\(elbowClassification.score)", "Mean elbow interior angle"],
            ["Foot placement", String(format: "%.2f", footPlacementAngle), "deg", footPlacementClassification.label, "", footNote],
            ["Running efficiency (4-metric avg)", String(format: "%.1f", efficiencyScore), "/100", "", "", "Same four classifiers as Efficiency dial (computeEfficiencyBreakdown)"],
            ["Sprint power (weighted composite)", sprintPowerWeighted.map { String($0) } ?? "—", "/100", "", "", "Landing quality, support timing, leg spring, drive & flight ROM, posture, and arm counterbalance"],
            ["Heel-strike frame indices", series.heelStrikeFrameIndices.map { String($0) }.joined(separator: "; "), "frames", "", "", "Contact snapshot indices"]
        ]
        sections += exportHtmlTable(
            heading: "Table 3 — Movement classifications and composite scores",
            headers: ["Category", "Primary", "Unit", "Label", "Score", "Explanation"],
            rows: table3Rows
        )
        
        var sprintRows: [[String]] = []
        if let bd = sprintBreakdown {
            sprintRows.append([bd.groundStrike.category, bd.groundStrike.label, "\(bd.groundStrike.score)", bd.groundStrike.tip])
            sprintRows.append([bd.supportTiming.category, bd.supportTiming.label, "\(bd.supportTiming.score)", bd.supportTiming.tip])
            sprintRows.append([bd.legSpring.category, bd.legSpring.label, "\(bd.legSpring.score)", bd.legSpring.tip])
            sprintRows.append([bd.driveAndFlight.category, bd.driveAndFlight.label, "\(bd.driveAndFlight.score)", bd.driveAndFlight.tip])
            sprintRows.append([bd.posture.category, bd.posture.label, "\(bd.posture.score)", bd.posture.tip])
            sprintRows.append([bd.armCounterbalance.category, bd.armCounterbalance.label, "\(bd.armCounterbalance.score)", bd.armCounterbalance.tip])
            sprintRows.append(["Power (weighted composite)", "", "\(bd.composite)", "Same weighting as in-app Power dial; height from Settings scales leg-spring proxy"])
        } else {
            let gsExport = classifySprintGroundStrike(angle: abs(footPlacementAngle) > 0.1 ? footPlacementAngle : nil)
            sprintRows.append([gsExport.category, gsExport.label, "\(gsExport.score)", gsExport.tip])
            let postureExport = classifySprintTorsoLean(angle: torsoAngle >= 0.1 ? torsoAngle : nil)
            sprintRows.append([postureExport.category, postureExport.label, "\(postureExport.score)", postureExport.tip])
        }
        sections += exportHtmlTable(
            heading: "Power breakdown (physics-aligned)",
            headers: ["Metric", "Label", "Score", "Tip"],
            rows: sprintRows
        )
        
        var table4Rows: [[String]] = []
        if let m = metrics {
            table4Rows = [
                ["Cadence (computed)", String(format: "%.2f", m.cadence), "spm"],
                ["Stride length (mean)", String(format: "%.4f", m.strideLength), "× body height"],
                ["Ground contact time left", String(format: "%.1f ± %.0f", m.groundContactLeft, m.groundContactUncertaintyMs), "ms"],
                ["Ground contact time right", String(format: "%.1f ± %.0f", m.groundContactRight, m.groundContactUncertaintyMs), "ms"],
                ["Vertical oscillation", String(format: "%.2f", m.verticalOscillation), "percent"],
                ["Symmetry score", String(format: "%.2f", m.symmetryScore), "percent"],
                ["Trunk lean (summary)", String(format: "%.2f", m.trunkLean), "deg"],
                ["Head stability", String(format: "%.2f", m.headStability), "percent"],
                ["Hip drop", String(format: "%.2f", m.hipDrop), "percent"],
                ["Knee flexion range L", String(format: "%.1f", m.kneeFlexionRangeLeft), "deg"],
                ["Knee flexion range R", String(format: "%.1f", m.kneeFlexionRangeRight), "deg"],
                ["Hip extension range L", String(format: "%.1f", m.hipExtensionRangeLeft), "deg"],
                ["Hip extension range R", String(format: "%.1f", m.hipExtensionRangeRight), "deg"],
                ["Ankle dorsiflexion L", String(format: "%.1f", m.ankleDorsiRangeLeft), "deg"],
                ["Ankle dorsiflexion R", String(format: "%.1f", m.ankleDorsiRangeRight), "deg"],
                ["Elbow range L", String(format: "%.1f", m.elbowRangeLeft), "deg"],
                ["Elbow range R", String(format: "%.1f", m.elbowRangeRight), "deg"],
                ["Foot strike pattern", m.footStrikePattern, "label"],
                ["Foot strike confidence", String(format: "%.0f", m.footStrikeConfidence * 100), "percent"],
                ["Capture frame rate", String(format: "%.0f", m.captureFrameRate), "fps"],
                ["Arm swing symmetry", String(format: "%.2f", m.armSwingSymmetry), "percent"]
            ]
        } else {
            table4Rows = [["(no aggregate metrics available)", "", ""]]
        }
        sections += exportHtmlTable(
            heading: "Table 4 — Gait summary (video-wide aggregates)",
            headers: ["Metric", "Value", "Unit"],
            rows: table4Rows
        )
        
        var table5Rows: [[String]] = []
        func addStatsRow(_ name: String, _ arr: [Double], _ unit: String) {
            let st = statsForSeries(arr)
            guard st.count > 0 else { return }
            table5Rows.append([
                name,
                "\(st.count)",
                String(format: "%.6g", st.mean),
                String(format: "%.6g", st.std),
                String(format: "%.6g", st.minV),
                String(format: "%.6g", st.maxV),
                unit
            ])
        }
        addStatsRow("Left foot–hip horizontal distance", series.leftFootHipDistanceSeries.map { $0 * distFactor }, distUnit)
        addStatsRow("Right foot–hip horizontal distance", series.rightFootHipDistanceSeries.map { $0 * distFactor }, distUnit)
        addStatsRow("Left foot vertical velocity (norm)", series.leftFootVelTimeSeries, "body_heights/s")
        addStatsRow("Right foot vertical velocity (norm)", series.rightFootVelTimeSeries, "body_heights/s")
        addStatsRow("Cadence (rolling)", series.cadenceSeries, "spm")
        addStatsRow("Ground contact left (rolling)", series.groundContactLeftSeries, "ms")
        addStatsRow("Ground contact right (rolling)", series.groundContactRightSeries, "ms")
        addStatsRow("Left knee angle", series.leftKneeAngleTimeSeries, "deg")
        addStatsRow("Right knee angle", series.rightKneeAngleTimeSeries, "deg")
        addStatsRow("Left hip angle", series.leftHipAngleTimeSeries, "deg")
        addStatsRow("Right hip angle", series.rightHipAngleTimeSeries, "deg")
        addStatsRow("Left ankle angle", series.leftAnkleAngleTimeSeries, "deg")
        addStatsRow("Right ankle angle", series.rightAnkleAngleTimeSeries, "deg")
        addStatsRow("Left foot Y (normalized)", series.leftFootYTimeSeries, "bh")
        addStatsRow("Right foot Y (normalized)", series.rightFootYTimeSeries, "bh")
        addStatsRow("Hip Y (normalized)", series.hipMovementYSeries, "bh")
        addStatsRow("Head Y (normalized)", series.headBobbingYSeries, "bh")
        addStatsRow("Arm X (normalized)", series.armMovementXSeries, "bh")
        addStatsRow("Foot velocity X (combined)", series.footVelocityXSeries, "norm")
        addStatsRow("Vertical oscillation (rolling)", series.verticalOscillationSeries, "percent")
        addStatsRow("Hip drop (rolling)", series.hipDropSeries, "percent")
        addStatsRow("Torso angle (per frame)", series.perFrameTorsoAngles, "deg")
        addStatsRow("Gaze angle (per frame)", series.perFrameGazeAngles, "deg")
        addStatsRow("Elbow angle (per frame)", series.perFrameElbowAngles, "deg")
        sections += exportHtmlTable(
            heading: "Table 5 — Time-series summary (valid samples only)",
            headers: ["Series", "Count", "Mean", "StdDev", "Min", "Max", "Unit"],
            rows: table5Rows
        )
        
        let maxFrames = csvExportMaxFrameCount(series)
        guard maxFrames > 0 else {
            let html = exportHtmlDocument(
                title: "Form analysis export",
                intro: "Open in Safari or Preview. Tables use your system light/dark appearance.",
                sections: sections
            )
            do {
                try html.write(to: exportURL, atomically: true, encoding: String.Encoding.utf8)
                return exportURL
            } catch {
                return nil
            }
        }
        
        let frameRate = videoDuration > 0 ? Double(maxFrames) / videoDuration : 30.0
        
        var headers = ["Frame index", "Time in segment (s)"]
        
        let hasLeftFootHip = !series.leftFootHipDistanceSeries.isEmpty
        let hasRightFootHip = !series.rightFootHipDistanceSeries.isEmpty
        if hasLeftFootHip { headers.append("Left foot–hip distance (\(distUnit))") }
        if hasRightFootHip { headers.append("Right foot–hip distance (\(distUnit))") }
        
        let hasLeftKnee = !series.leftKneeAngleTimeSeries.isEmpty
        let hasRightKnee = !series.rightKneeAngleTimeSeries.isEmpty
        if hasLeftKnee { headers.append("Left knee angle (deg)") }
        if hasRightKnee { headers.append("Right knee angle (deg)") }
        
        let hasLeftHip = !series.leftHipAngleTimeSeries.isEmpty
        let hasRightHip = !series.rightHipAngleTimeSeries.isEmpty
        if hasLeftHip { headers.append("Left hip angle (deg)") }
        if hasRightHip { headers.append("Right hip angle (deg)") }
        
        let hasLeftAnkle = !series.leftAnkleAngleTimeSeries.isEmpty
        let hasRightAnkle = !series.rightAnkleAngleTimeSeries.isEmpty
        if hasLeftAnkle { headers.append("Left ankle angle (deg)") }
        if hasRightAnkle { headers.append("Right ankle angle (deg)") }
        
        let hasLeftFootY = !series.leftFootYTimeSeries.isEmpty
        let hasRightFootY = !series.rightFootYTimeSeries.isEmpty
        if hasLeftFootY { headers.append("Left foot Y (bh)") }
        if hasRightFootY { headers.append("Right foot Y (bh)") }
        
        let hasLeftFootVel = !series.leftFootVelTimeSeries.isEmpty
        let hasRightFootVel = !series.rightFootVelTimeSeries.isEmpty
        if hasLeftFootVel { headers.append("Left foot vertical vel (bh/s)") }
        if hasRightFootVel { headers.append("Right foot vertical vel (bh/s)") }
        
        let hasHipY = !series.hipMovementYSeries.isEmpty
        let hasHeadY = !series.headBobbingYSeries.isEmpty
        let hasArmX = !series.armMovementXSeries.isEmpty
        let hasFootVelX = !series.footVelocityXSeries.isEmpty
        if hasHipY { headers.append("Hip Y (bh)") }
        if hasHeadY { headers.append("Head Y (bh)") }
        if hasArmX { headers.append("Arm X (bh)") }
        if hasFootVelX { headers.append("Foot vel X (combined)") }
        
        let hasCadence = !series.cadenceSeries.isEmpty
        let hasGctL = !series.groundContactLeftSeries.isEmpty
        let hasGctR = !series.groundContactRightSeries.isEmpty
        if hasCadence { headers.append("Cadence (spm)") }
        if hasGctL { headers.append("Ground contact left (ms)") }
        if hasGctR { headers.append("Ground contact right (ms)") }
        
        let hasVertOsc = !series.verticalOscillationSeries.isEmpty
        let hasHipDrop = !series.hipDropSeries.isEmpty
        if hasVertOsc { headers.append("Vertical oscillation (%)") }
        if hasHipDrop { headers.append("Hip drop (%)") }
        
        let hasTorsoPF = !series.perFrameTorsoAngles.isEmpty
        let hasGazePF = !series.perFrameGazeAngles.isEmpty
        let hasElbowPF = !series.perFrameElbowAngles.isEmpty
        if hasTorsoPF { headers.append("Torso angle (deg)") }
        if hasGazePF { headers.append("Gaze angle (deg)") }
        if hasElbowPF { headers.append("Elbow angle (deg)") }
        
        let table6Cols = CSVTable6Columns(
            hasLeftFootHip: hasLeftFootHip,
            hasRightFootHip: hasRightFootHip,
            hasLeftKnee: hasLeftKnee,
            hasRightKnee: hasRightKnee,
            hasLeftHip: hasLeftHip,
            hasRightHip: hasRightHip,
            hasLeftAnkle: hasLeftAnkle,
            hasRightAnkle: hasRightAnkle,
            hasLeftFootY: hasLeftFootY,
            hasRightFootY: hasRightFootY,
            hasLeftFootVel: hasLeftFootVel,
            hasRightFootVel: hasRightFootVel,
            hasHipY: hasHipY,
            hasHeadY: hasHeadY,
            hasArmX: hasArmX,
            hasFootVelX: hasFootVelX,
            hasCadence: hasCadence,
            hasGctL: hasGctL,
            hasGctR: hasGctR,
            hasVertOsc: hasVertOsc,
            hasHipDrop: hasHipDrop,
            hasTorsoPF: hasTorsoPF,
            hasGazePF: hasGazePF,
            hasElbowPF: hasElbowPF
        )
        let table6Rows = csvExportCollectPerFrameRows(
            series: series,
            maxFrames: maxFrames,
            frameRate: frameRate,
            distFactor: distFactor,
            cols: table6Cols
        )
        sections += exportHtmlTable(
            heading: "Table 6 — Per-frame time series",
            subheading: "Swipe sideways on this table to see every column. Pinch to zoom if needed.",
            headers: headers,
            rows: table6Rows,
            allowHorizontalScroll: true
        )
        
        let html = exportHtmlDocument(
            title: "Form analysis export",
            intro: "Open in Safari or Preview. Tables use your system light/dark appearance.",
            sections: sections
        )
        do {
            try html.write(to: exportURL, atomically: true, encoding: String.Encoding.utf8)
            return exportURL
        } catch {
            debugLog("Failed to write analysis export: \(error)")
            return nil
        }
    }
    
    // MARK: - Scoring Helper Functions
    private func coefficientOfVariation(_ values: [Double]) -> Double {
        let validValues = values.filter { !$0.isNaN && $0.isFinite }
        guard validValues.count > 1 else { return 0 }
        
        let mean = validValues.reduce(0, +) / Double(validValues.count)
        guard mean != 0 else { return 0 }
        
        let variance = validValues.reduce(0) { $0 + pow($1 - mean, 2) } / Double(validValues.count - 1)
        let std = sqrt(variance)
        return std / abs(mean)
    }
    
    private func meanAbsoluteDeviation(_ values: [Double], from target: Double = 0) -> Double {
        let validValues = values.filter { !$0.isNaN && $0.isFinite }
        guard !validValues.isEmpty else { return 0 }
        
        let deviations = validValues.map { abs($0 - target) }
        return deviations.reduce(0, +) / Double(deviations.count)
    }
    
    private func cvToScore(_ cv: Double, maxCV: Double = 0.5) -> Double {
        // Lower CV = higher score
        // More lenient: use square root curve for gentler penalty
        // CV of 0 = 100, CV of maxCV = ~30 (instead of 0)
        let clampedCV = min(cv, maxCV)
        let normalized = clampedCV / maxCV
        // Square root curve: more forgiving for higher variation
        let score = 100 * (1 - sqrt(normalized) * 0.7)  // 0.7 factor makes it more lenient
        return max(0, min(100, score))
    }
    
    private func madToScore(_ mad: Double, maxMAD: Double = 20) -> Double {
        // Lower MAD = higher score
        // More lenient: use square root curve for gentler penalty
        // MAD of 0 = 100, MAD of maxMAD = ~30 (instead of 0)
        let clampedMAD = min(mad, maxMAD)
        let normalized = clampedMAD / maxMAD
        // Square root curve: more forgiving for higher deviation
        let score = 100 * (1 - sqrt(normalized) * 0.7)  // 0.7 factor makes it more lenient
        return max(0, min(100, score))
    }
    
    // MARK: - Form Score Calculation
    // Detect all local maxima (peaks) in a signal with sub-frame accuracy.
    // Returns fractional frame indices refined via parabolic interpolation.
    static fileprivate func detectLocalMaxima(_ series: [Double], frameRate: Double) -> [Double] {
        // Internal bookkeeping uses integer indices; final output is refined doubles.
        var intPeaks: [Int] = []
        let minSpacingFrames = max(1, Int(frameRate * 0.2)) // 0.2s minimum spacing to avoid noise
        
        // First pass: detect all local maxima at integer resolution
        for i in 1..<(series.count - 1) {
            if series[i].isNaN { continue }
            
            // Local maximum: strictly greater than both neighbors
            // Also check wider neighborhood to avoid detecting noise
            let isLocalMax = series[i] > series[i-1] &&
                            series[i] > series[i+1] &&
                            (i < 2 || series[i] > series[i-2]) &&
                            (i >= series.count - 2 || series[i] > series[i+2])
            
            if isLocalMax {
                if intPeaks.isEmpty || (i - intPeaks.last!) >= minSpacingFrames {
                    intPeaks.append(i)
                } else {
                    // If peaks are too close, keep the higher one
                    let lastPeakIndex = intPeaks.last!
                    if series[i] > series[lastPeakIndex] {
                        intPeaks[intPeaks.count - 1] = i
                    }
                }
            }
        }
        
        // Second pass: refine each peak with parabolic (quadratic) interpolation
        // for sub-frame accuracy.  offset = 0.5*(y[i-1]-y[i+1]) / (y[i-1]-2*y[i]+y[i+1])
        var refinedPeaks: [Double] = []
        for i in intPeaks {
            guard i > 0, i < series.count - 1,
                  !series[i-1].isNaN, !series[i].isNaN, !series[i+1].isNaN else {
                refinedPeaks.append(Double(i))
                continue
            }
            let denom = series[i-1] - 2.0 * series[i] + series[i+1]
            if abs(denom) > 1e-12 {
                let offset = 0.5 * (series[i-1] - series[i+1]) / denom
                // Clamp offset to ±0.5 so we stay within this frame's neighbourhood
                let clampedOffset = max(-0.5, min(0.5, offset))
                refinedPeaks.append(Double(i) + clampedOffset)
            } else {
                refinedPeaks.append(Double(i))
            }
        }
        
        return refinedPeaks
    }
    
    // Calculate cadence from first peak to last peak (inclusive).
    // Accepts fractional (sub-frame) peak indices from parabolic interpolation.
    // N peaks produce N-1 step intervals for one foot.
    // Multiply by 2 to get both-feet SPM (right-foot graph only captures half the steps).
    static fileprivate func calculateCadenceFromPeaks(_ peaks: [Double], frameRate: Double) -> Double {
        guard peaks.count >= 2, frameRate > 0 else { return 0 }
        
        // Use sub-frame first/last positions for precise timing
        let firstPeak = peaks.first!
        let lastPeak = peaks.last!
        
        // Time elapsed using fractional indices
        let timeElapsed = (lastPeak - firstPeak) / frameRate
        
        guard timeElapsed > 0 else { return 0 }
        
        // N peaks = N-1 step intervals for one foot
        let intervals = Double(peaks.count - 1)
        
        // Single-foot cadence, then ×2 for both feet
        let cadence = (intervals / timeElapsed) * 60.0 * 2.0
        
        // Upper cap only – no lower clamp
        return min(300, cadence)
    }
    
    // MARK: - Overstride / Shin Angle Assessment
    //
    // Shin-angle model for this app (average-runner calibration):
    //   • Understride: too vertical at contact
    //   • Good Stride: middle range at contact
    //   • Overstride: too far forward at contact
    // All UI labels and scores below now use the same classifier from VideoProcessor.
    
    /// Return type for the overstride assessment.
    struct OverstrideResult {
        let shinAngle: Double   // degrees from vertical (positive = forward lean)
        let label: String       // e.g. "Optimal", "Mild Overstride"
        let color: Color        // green → red
        let tip: String         // short coaching cue
    }
    
    /// Assess stride quality from:
    ///  1. The shin-vertical angle already computed by VideoProcessor (primary).
    ///  2. The foot-to-hip distance peak amplitudes as a cross-check (secondary).
    private func overstrideAssessment(
        formCueScores: [FormCueScore],
        footHipSeries: [Double],
        peaks: [Double],           // fractional indices from parabolic interp
        frameRate: Double,
        hipYSeries: [Double],      // trimmed hip Y position
        footYSeries: [Double],     // trimmed foot Y position
        analysisStartTime: Double, // offset between untrimmed & trimmed series
        videoDuration: Double,
        shinSampleCount: Int
    ) -> OverstrideResult {
        
        // ── 1. Primary: shin angle from VideoProcessor ──
        // VideoProcessor now computes this at foot-to-hip peaks (not gait cycles).
        let shinCue = formCueScores.first(where: { $0.cue == .shinVertical })
        let primaryShinAngle = shinCue?.mean
        
        // ── 2. Secondary: geometric angle from foot-to-hip peak amplitudes ──
        // If the primary angle is 0 (no data), estimate from the graph data.
        // At each peak, horizontal_distance comes from footHipSeries (untrimmed, px).
        // Vertical leg length comes from hipYSeries - footYSeries (both trimmed).
        // We offset the peak index by analysisStartTime to align into trimmed space.
        var geometricAngles: [Double] = []
        if !peaks.isEmpty && !hipYSeries.isEmpty && !footYSeries.isEmpty {
            // footHipSeries is untrimmed; hipYSeries/footYSeries are trimmed.
            // The trimmed series start at analysisStartTime.
            // Frame index mapping: trimmedIdx = untrimmedIdx - startOffset
            let untrimmedFrameCount = footHipSeries.count
            let trimmedFrameCount  = min(hipYSeries.count, footYSeries.count)
            guard untrimmedFrameCount > 0 && trimmedFrameCount > 0 else {
                // fall through to primary
                return verdictForAngle(primaryShinAngle, sampleCount: shinSampleCount)
            }
            // Estimate how many frames correspond to analysisStartTime
            let startOffset = Int((analysisStartTime / videoDuration) * Double(untrimmedFrameCount))
            
            for fractionalIdx in peaks {
                let untrimmedIdx = Int(fractionalIdx.rounded())
                guard untrimmedIdx >= 0, untrimmedIdx < untrimmedFrameCount else { continue }
                
                // Horizontal overstride distance (px)
                let hDist = footHipSeries[untrimmedIdx]
                guard !hDist.isNaN && hDist.isFinite else { continue }
                
                // Map to trimmed index
                let trimmedIdx = untrimmedIdx - startOffset
                guard trimmedIdx >= 0, trimmedIdx < trimmedFrameCount else { continue }
                
                let hipY  = hipYSeries[trimmedIdx]
                let footY = footYSeries[trimmedIdx]
                guard !hipY.isNaN && !footY.isNaN else { continue }
                
                // Vertical leg length (in screen coords Y increases downward,
                // foot Y > hip Y for a standing person)
                let vDist = abs(footY - hipY)
                guard vDist > 1 else { continue } // avoid division by near-zero
                
                // atan2(horizontal, vertical) → angle from vertical
                let angleDeg = atan2(abs(hDist), vDist) * 180.0 / .pi
                geometricAngles.append(angleDeg)
            }
        }
        
        let geometricAngle: Double = geometricAngles.isEmpty
            ? 0
            : geometricAngles.reduce(0, +) / Double(geometricAngles.count)
        
        // ── 3. Pick the best available angle ──
        let effectiveAngle: Double?
        if let primary = primaryShinAngle, primary >= 0.1 {
            effectiveAngle = primary
        } else if geometricAngle > 0.1 {
            effectiveAngle = geometricAngle
        } else {
            effectiveAngle = nil
        }
        
        return verdictForAngle(effectiveAngle, sampleCount: shinSampleCount)
    }
    
    /// Decode perpendicularity + evidence data from encoded std field.
    /// New format: std = actualStd*1_000_000 + perpendicularityPercentage*10_000 + perpendicularCount*100 + sampleCount
    /// Legacy format: std = actualStd*10_000 + perpendicularityPercentage*100 + perpendicularCount
    private func decodePerpendicularityData(_ encodedStd: Double) -> (actualStd: Double, percentage: Double, count: Int, sampleCount: Int) {
        if encodedStd >= 100000 {
            let sampleCount = Int(encodedStd.truncatingRemainder(dividingBy: 100))
            let perpendicularCount = Int((encodedStd / 100).truncatingRemainder(dividingBy: 100))
            let percentage = (encodedStd / 10000).truncatingRemainder(dividingBy: 100)
            let actualStd = (encodedStd - encodedStd.truncatingRemainder(dividingBy: 1_000_000)) / 1_000_000.0
            return (actualStd, percentage, perpendicularCount, sampleCount)
        }
        
        // Legacy fallback
        let perpendicularCount = Int(encodedStd.truncatingRemainder(dividingBy: 100))
        let percentage = (encodedStd.truncatingRemainder(dividingBy: 10000) - Double(perpendicularCount)) / 100.0
        let actualStd = (encodedStd - encodedStd.truncatingRemainder(dividingBy: 10000)) / 10000.0
        return (actualStd, percentage, perpendicularCount, 0)
    }
    
    /// Calculate the displayed shin-angle quality using the canonical classifier from VideoProcessor.
    private func calculateGoodShinAngleScore(_ angle: Double) -> (score: Int, label: String, color: Color, tip: String) {
        let classification = classifyShinStride(angle: angle >= 0.1 ? angle : nil)
        let style = styleForClassification(classification)
        return (classification.score, classification.label, style.color, style.tip)
    }
    
    // MARK: - Sprint Suggestion Cards
    
    @ViewBuilder
    private func sprintSuggestionCards(series: MetricSeries, metrics: AnalysisMetrics?) -> some View {
        VStack(spacing: 10) {
            if let m = metrics {
                let bd = computeSprintPowerBreakdown(series: series, metrics: m, userBodyHeightMeters: userBodyHeightMeters)
                SprintMetricCard(cls: bd.groundStrike)
                SprintMetricCard(cls: bd.supportTiming)
                SprintMetricCard(cls: bd.legSpring)
                SprintMetricCard(cls: bd.driveAndFlight)
                SprintMetricCard(cls: bd.posture)
                SprintMetricCard(cls: bd.armCounterbalance)
            } else {
                let footCue = series.formCueScores.first(where: { $0.cue == .footPlacement })
                let footAngle = footCue.flatMap { abs($0.rawValue) > 0.1 ? $0.rawValue : nil }
                SprintMetricCard(cls: classifySprintGroundStrike(angle: footAngle))
                SprintMetricCard(cls: classifySprintTorsoLean(angle: series.torsoAngleMean >= 0.1 ? series.torsoAngleMean : nil))
            }
        }
    }
    
    private func styleForClassification(_ classification: ShinStrideClassification) -> (color: Color, tip: String) {
        switch classification.band {
        case .unknown:
            return (.gray, "Not enough data to measure stride. Record from the side with a clear view of your full leg from hip to foot.")
        case .understride:
            return (.yellow, "You're cutting your stride short and landing with your foot too far underneath you, which kills momentum and wastes energy. On relaxed strides, let your legs open up naturally without forcing length.")
        case .goodStride:
            return (.green, "Your foot lands right underneath you, keeping braking low and helping you flow forward efficiently. This is the pattern most coaches want for smooth, economical running.")
        case .mildOverstride:
            return (.yellow, "Your foot lands slightly ahead of your hips, adding a small brake each step. Think quick, light steps and pull your foot back before it touches down so you land closer under your body.")
        case .moderateOverstride:
            return (.orange, "You're landing well ahead of your body, which acts like a brake on every step. Run in place briefly, then drift forward without changing where your feet land, and notice how much smoother that feels.")
        case .severeOverstride:
            return (.red, "Heavy overstride raises injury risk and slams the brakes each step. Shorten your stride, think quick and light, and aim to land with your foot closer under your hips.")
        }
    }
    
    private func styleForTorsoClassification(_ classification: TorsoAngleClassification) -> (color: Color, tip: String) {
        switch classification.band {
        case .unknown:
            return (.gray, "Not enough data to measure torso lean. Make sure your shoulders and hips are visible in the footage.")
        case .tooUpright:
            return (.orange, "Running bolt upright fights gravity instead of using it. Lean slightly from the ankles, not the waist, and let gravity help pull you forward without hunching.")
        case .optimal:
            return (.green, "Your torso has a gentle forward lean that lets gravity help carry you forward without straining your back. This is a strong, sustainable posture for distance running.")
        case .good:
            return (.green, "Strong posture. Your torso position is solid and your lean is doing its job, helping you move forward without folding or sitting back.")
        case .moderateLean:
            return (.yellow, "You're leaning too far forward, which loads your lower back and hamstrings over longer runs. Run tall through the top of your head while keeping a gentle lean from the ankles.")
        case .excessive:
            return (.orange, "You're hinging at the waist instead of the ankles, which restricts breathing and overloads your lower back. Stand taller, lightly brace your core, and let the lean come from the whole body line.")
        }
    }
    
    private func styleForHeadClassification(_ classification: HeadAngleClassification) -> (color: Color, tip: String) {
        switch classification.band {
        case .unknown:
            return (.gray, "Not enough data to measure gaze. Make sure your head is clearly visible in the recording.")
        case .lookingAhead:
            return (.green, "Eyes forward, chin neutral. This keeps your neck aligned and your airway open, which helps breathing and balance even when you get tired.")
        case .slightDownward:
            return (.yellow, "Your gaze is drifting down, which often happens as fatigue sets in. Pick a fixed point down the road and hold your eyes there. Your posture usually follows where you look.")
        case .moderateDownward:
            return (.orange, "Looking down pulls your shoulders forward and tightens your neck, which collapses your chest and makes breathing harder. Imagine balancing something light on your head while you run.")
        case .excessive:
            return (.red, "Looking at your feet triggers poor posture from your neck down to your hips. It restricts breathing and adds tension through your upper body. Practice running with your chin level and eyes ahead.")
        }
    }
    
    private func styleForElbowClassification(_ classification: ElbowAngleClassification) -> (color: Color, tip: String) {
        switch classification.band {
        case .unknown:
            return (.gray, "Not enough data to measure arm form. Make sure your arms are visible in the footage.")
        case .tooTight:
            return (.orange, "Your arms are clamped too tight, and tension creeps into your shoulders and neck. Keep your hands relaxed, elbows softly bent, and let the swing come from the shoulder without squeezing.")
        case .good:
            return (.green, "Strong arm form. A slightly more relaxed bend would make your swing even more efficient, but you're already moving well with your legs instead of fighting them.")
        case .optimal:
            return (.green, "Relaxed, compact arm swing with a comfortable elbow bend. Your arms are working with your legs, not against them, which keeps rotation down and saves energy.")
        case .slightlyOpen:
            return (.yellow, "Your elbows are opening up, making your swing less compact and costing a little energy each stride. Drive your elbows straight back, not out to the sides or across your body.")
        case .tooStraight:
            return (.orange, "Straight arms swing slowly and pull your torso side to side. Keep a relaxed bend, hands loose near your waistband, and drive the elbows straight back behind you.")
        }
    }

    private func tipForFootPlacementClassification(_ classification: FootPlacementClassification) -> String {
        switch classification.band {
        case .unknown:
            return "Not enough data to classify landing type. Make sure your feet are visible at the moment of ground contact."
        case .midfoot:
            return "You tend to land on the middle of the foot. Impact spreads across the whole foot, which many runners find smooth and balanced for steady pacing."
        case .mildHeelStrike:
            return "You touch down with a slight heel lead before the rest of the foot comes down. This is common at relaxed paces and feels natural for many distance runners."
        case .mildForefoot:
            return "You land slightly up on the forefoot, with the heel following soon after. Many runners use this pattern when they pick up the pace or run on their toes."
        case .heelStrike:
            return "You land heel-first with a clear lead on the back of the foot. This pattern is widely used in distance running and can feel stable and familiar on easy days."
        case .forefootStrike:
            return "You land prominently on the forefoot, often with the heel lifting or touching lightly after. Sprinters and up-tempo runners commonly land this way."
        }
    }

    /// Map a shin angle (degrees from vertical) to a labelled verdict.
    private func verdictForAngle(_ effectiveAngle: Double?, sampleCount _: Int) -> OverstrideResult {
        // Trust VideoProcessor median shin when present; do not gate on contact count (dial/cue already use it).
        let reliableAngle: Double? = {
            guard let angle = effectiveAngle, angle.isFinite, angle >= 0.1 else {
                return nil
            }
            return angle
        }()
        let classification = classifyShinStride(angle: reliableAngle)
        let style = styleForClassification(classification)
        return OverstrideResult(
            shinAngle: reliableAngle ?? 0,
            label: classification.label,
            color: style.color,
            tip: style.tip
        )
    }
    
    // Calculate cadence from foot-to-hip distance signal by detecting peaks (heel strikes)
    // Falls back to using the pre-calculated cadenceSeries if peak detection fails
    private func calculateCadenceFromFootHipDistance(_ series: [Double], duration: Double, frameRate: Double, cadenceSeries: [Double]? = nil) -> Double {
        guard !series.isEmpty, duration > 0, frameRate > 0 else {
            // Fallback to cadenceSeries if available
            if let cadenceSeries = cadenceSeries, !cadenceSeries.isEmpty {
                let validCadence = cadenceSeries.filter { !$0.isNaN && $0.isFinite && $0 > 0 }
                if !validCadence.isEmpty {
                    return validCadence.reduce(0, +) / Double(validCadence.count)
                }
            }
            return 0
        }
        
        // Detect peaks (heel strikes) in the signal with adaptive thresholds
        func detectPeaks(_ signal: [Double], minSpacing: Double, peakThreshold: Double) -> [Int] {
            var peaks: [Int] = []
            
            let validValues = signal.filter { !$0.isNaN && $0.isFinite }
            guard !validValues.isEmpty else { return [] }
            let minVal = validValues.min() ?? 0
            let maxVal = validValues.max() ?? 0
            let range = maxVal - minVal
            guard range > 0 else { return [] }
            
            // Use percentile-based threshold for more robust detection
            let sortedValid = validValues.sorted()
            let median = sortedValid[sortedValid.count / 2]
            let p75 = sortedValid[Int(Double(sortedValid.count) * 0.75)]
            let adaptiveThreshold = max(0.5, min(0.8, (p75 - minVal) / range))
            
            let normalized = signal.map { range > 0 ? ($0 - minVal) / range : 0.0 }
            let minSpacingFrames = max(1, Int(minSpacing * frameRate))
            
            for i in 1..<(signal.count - 1) {
                if signal[i].isNaN { continue }
                
                // Local maximum (peak) - check for clear peak with sufficient prominence
                let isLocalMax = signal[i] > signal[i-1] && signal[i] > signal[i+1]
                let prominence = normalized[i] >= max(peakThreshold, adaptiveThreshold)
                
                if isLocalMax && prominence {
                    if peaks.isEmpty || (i - peaks.last!) >= minSpacingFrames {
                        peaks.append(i)
                    }
                }
            }
            
            return peaks
        }
        
        // Try multiple threshold levels for robustness
        var allPeaks: [Int] = []
        for threshold in [0.6, 0.65, 0.7, 0.75] {
            let peaks = detectPeaks(series, minSpacing: 0.3, peakThreshold: threshold)
            if peaks.count >= 2 {
                allPeaks = peaks
                break
            }
        }
        
        // If still no peaks, use simpler local maxima detection
        if allPeaks.count < 2 {
            var simplePeaks: [Int] = []
            let minSpacingFrames = max(1, Int(frameRate * 0.25)) // 0.25s minimum spacing
            
            for i in 1..<(series.count - 1) {
                if !series[i].isNaN && series[i] > series[i-1] && series[i] > series[i+1] {
                    // Check prominence: peak should be above median
                    let validValues = series.filter { !$0.isNaN && $0.isFinite }
                    if !validValues.isEmpty {
                        let median = validValues.sorted()[validValues.count / 2]
                        if series[i] > median {
                            if simplePeaks.isEmpty || (i - simplePeaks.last!) >= minSpacingFrames {
                                simplePeaks.append(i)
                            }
                        }
                    }
                }
            }
            allPeaks = simplePeaks
        }
        
        // Calculate cadence from detected peaks
        var graphBasedCadence: Double? = nil
        
        if allPeaks.count >= 2 {
            // Calculate average time between peaks (step time)
            let times = allPeaks.map { Double($0) / frameRate }
            var intervals: [Double] = []
            for i in 1..<times.count {
                let interval = times[i] - times[i-1]
                // Filter out unrealistic intervals (too short or too long)
                // For running: step time should be 0.3-0.5s (120-200 spm per leg, 240-400 total)
                // But we're looking at one leg, so 0.3-0.5s is reasonable
                if interval >= 0.25 && interval <= 0.8 {
                    intervals.append(interval)
                }
            }
            
            if !intervals.isEmpty {
                // Use median for robustness against outliers
                let sortedIntervals = intervals.sorted()
                let medianStepTime = sortedIntervals[sortedIntervals.count / 2]
                let cadenceFromIntervals = medianStepTime > 0 ? (60.0 / medianStepTime) * 2 : 0
                
                // Alternative: use first-to-last peak timing (N-1 intervals, ×2 for both feet)
                let peakTimeSpan = (Double(allPeaks.last! - allPeaks.first!) / frameRate)
                let cadenceFromCount = peakTimeSpan > 0
                    ? (Double(allPeaks.count - 1) / peakTimeSpan) * 60.0 * 2.0
                    : 0.0
                
                // Use the median of both methods for stability
                let calculatedCadence = (cadenceFromIntervals + cadenceFromCount) / 2.0
                
                // Validate range (80-250 spm) - realistic running cadence
                if calculatedCadence >= 80 && calculatedCadence <= 250 {
                    graphBasedCadence = calculatedCadence
                }
            } else if allPeaks.count >= 2 {
                // Even if intervals are filtered out, use first-to-last peak timing
                let peakTimeSpan = Double(allPeaks.last! - allPeaks.first!) / frameRate
                let cadenceFromCount = peakTimeSpan > 0
                    ? (Double(allPeaks.count - 1) / peakTimeSpan) * 60.0 * 2.0
                    : 0.0
                if cadenceFromCount >= 80 && cadenceFromCount <= 250 {
                    graphBasedCadence = cadenceFromCount
                }
            }
        } else if allPeaks.count > 0 {
            // Even with just 1 peak, we can estimate
            let estimatedCadence = (Double(allPeaks.count) / duration) * 60 * 2
            if estimatedCadence >= 80 && estimatedCadence <= 250 {
                graphBasedCadence = estimatedCadence
            }
        }
        
        // If graph-based calculation succeeded, use it
        if let graphCadence = graphBasedCadence {
            return graphCadence
        }
        
        // Fallback: use pre-calculated cadenceSeries if peak detection fails
        if let cadenceSeries = cadenceSeries, !cadenceSeries.isEmpty {
            let validCadence = cadenceSeries.filter { !$0.isNaN && $0.isFinite && $0 > 0 && $0 >= 80 && $0 <= 250 }
            if !validCadence.isEmpty {
                // Use median for robustness (more stable than mean)
                let sorted = validCadence.sorted()
                let medianCadence = sorted[sorted.count / 2]
                
                // Also check mean to ensure consistency
                let meanCadence = validCadence.reduce(0, +) / Double(validCadence.count)
                
                // If mean and median are close, use mean (more representative)
                // Otherwise use median (more robust to outliers)
                if abs(medianCadence - meanCadence) < 10 {
                    return meanCadence
                } else {
                    return medianCadence
                }
            }
        }
        
        // Last resort: return 0 (should not happen with valid data)
        return 0
    }
    
    private func calculateFormScore(series: MetricSeries, metrics: AnalysisMetrics?) -> FormScore {
        // Helper function to get form cue score
        func getCueScore(_ cue: FormCue) -> Double {
            series.formCueScores.first(where: { $0.cue == cue })?.score ?? 50.0
        }
        
        // Head Alignment Category: eyes forward, head stability
        let eyesForwardScore = getCueScore(.eyesForward)
        // Use head bobbing variation as additional indicator (less variation = better alignment)
        let headBobbingCV = coefficientOfVariation(series.headBobbingYSeries)
        let headStabilityScore = cvToScore(headBobbingCV, maxCV: 0.8)
        // Weight eyesForward more heavily (70/30 split)
        let headAlignment = eyesForwardScore * 0.7 + headStabilityScore * 0.3
        
        // Posture Category: trunk angle, elbow angle, vertical oscillation
        // Trunk angle: optimal range is 5-15° (forward lean)
        let trunkLeanCue = series.formCueScores.first(where: { $0.cue == .tallPosture })
        let trunkLeanMean = trunkLeanCue?.mean ?? (metrics?.trunkLean ?? 0)
        let trunkAngleScore: Double
        if trunkLeanMean >= 5 && trunkLeanMean <= 15 {
            // In optimal range: 95-100 based on how centered
            let center = 10.0
            let distanceFromCenter = abs(trunkLeanMean - center)
            trunkAngleScore = 100 - (distanceFromCenter * 1.0) // Max 5 point deduction from center
        } else if trunkLeanMean >= 3 && trunkLeanMean < 5 {
            // Just below optimal: 85-94
            trunkAngleScore = 85 + (trunkLeanMean - 3) * 4.5
        } else if trunkLeanMean > 15 && trunkLeanMean <= 20 {
            // Just above optimal: 85-94
            trunkAngleScore = 100 - (trunkLeanMean - 15) * 3.0
        } else if trunkLeanMean >= 0 && trunkLeanMean < 3 {
            // Too upright: 70-84
            trunkAngleScore = 70 + (trunkLeanMean - 0) * 5.0
        } else if trunkLeanMean > 20 && trunkLeanMean <= 25 {
            // Too forward: 70-84
            trunkAngleScore = 100 - (trunkLeanMean - 15) * 3.0
        } else {
            // Far from optimal: score decreases more sharply
            if trunkLeanMean < 0 {
                trunkAngleScore = max(0, 70 - abs(trunkLeanMean) * 2.0)
            } else {
                trunkAngleScore = max(0, 70 - (trunkLeanMean - 25) * 2.0)
            }
        }
        
        // Elbow angle: optimal range is 80-100°
        let elbowCue = series.formCueScores.first(where: { $0.cue == .elbows })
        let elbowMean = elbowCue?.mean ?? 90.0 // Default to 90 if not available
        let elbowAngleScore: Double
        if elbowMean >= 80 && elbowMean <= 100 {
            // In optimal range: 95-100 based on how centered
            let center = 90.0
            let distanceFromCenter = abs(elbowMean - center)
            elbowAngleScore = 100 - (distanceFromCenter * 0.25) // Max 5 point deduction from center
        } else if elbowMean >= 70 && elbowMean < 80 {
            // Just below optimal: 85-94
            elbowAngleScore = 85 + (elbowMean - 70) * 0.9
        } else if elbowMean > 100 && elbowMean <= 110 {
            // Just above optimal: 85-94
            elbowAngleScore = 100 - (elbowMean - 100) * 1.5
        } else if elbowMean >= 60 && elbowMean < 70 {
            // Too closed: 70-84
            elbowAngleScore = 70 + (elbowMean - 60) * 1.5
        } else if elbowMean > 110 && elbowMean <= 120 {
            // Too open: 70-84
            elbowAngleScore = 100 - (elbowMean - 100) * 1.5
        } else {
            // Far from optimal: score decreases more sharply
            if elbowMean < 60 {
                elbowAngleScore = max(0, 70 - (60 - elbowMean) * 1.0)
            } else {
                elbowAngleScore = max(0, 70 - (elbowMean - 120) * 1.0)
            }
        }
        
        // Lower vertical oscillation = better posture (inverse relationship)
        let voCV = coefficientOfVariation(series.verticalOscillationSeries)
        let voScore = cvToScore(voCV, maxCV: 0.8)
        // Also check if vertical oscillation values are low (absolute, not just variation)
        let voValidValues = series.verticalOscillationSeries.filter { !$0.isNaN && $0.isFinite }
        let voMean = voValidValues.isEmpty ? 0 : voValidValues.reduce(0, +) / Double(voValidValues.count)
        // Lower is better for VO (optimal < 6%), score based on that
        let voAbsoluteScore = voMean <= 6 ? 100 : max(0, 100 - (voMean - 6) * 10)
        
        // Weight: trunk angle (40%), elbow angle (30%), vertical oscillation (30%)
        let posture = trunkAngleScore * 0.4 + elbowAngleScore * 0.3 + voAbsoluteScore * 0.3
        
        // Shin vertical: same rubric as Efficiency dial / shin FormCueScore (classifyShinStride).
        let shinCue = series.formCueScores.first(where: { $0.cue == .shinVertical })
        let shinAngle = shinCue?.mean ?? 0.0
        let shinVerticalScore = Double(classifyShinStride(angle: shinAngle > 0.1 ? shinAngle : nil).score)
        
        let quietFeetScore = getCueScore(.quietFeet)
        let footUnderCOMScore = getCueScore(.footUnderCOM)
        
        // Efficiency Category: cadence optimal range, vertical oscillation (movement economy)
        // Calculate mean cadence and score based on optimal range (170-180 spm)
        let cadenceValidValues = series.cadenceSeries.filter { !$0.isNaN && $0.isFinite && $0 > 0 }
        let meanCadence = cadenceValidValues.isEmpty ? 0 : cadenceValidValues.reduce(0, +) / Double(cadenceValidValues.count)
        
        // Score cadence: optimal range is 170-180 spm
        // 95+ score only if in optimal range
        let cadenceScore: Double
        if meanCadence >= 170 && meanCadence <= 180 {
            // In optimal range: 95-100 based on how centered
            let center = 175.0
            let distanceFromCenter = abs(meanCadence - center)
            cadenceScore = 100 - (distanceFromCenter * 1.0) // Max 5 point deduction from center
        } else if meanCadence >= 165 && meanCadence < 170 {
            // Just below optimal: 85-94
            cadenceScore = 85 + (meanCadence - 165) * 1.8
        } else if meanCadence > 180 && meanCadence <= 190 {
            // Just above optimal: 85-94
            cadenceScore = 100 - (meanCadence - 180) * 1.5
        } else if meanCadence >= 160 && meanCadence < 165 {
            // Below optimal: 70-84
            cadenceScore = 70 + (meanCadence - 160) * 3.0
        } else if meanCadence > 190 && meanCadence <= 200 {
            // Above optimal: 70-84
            cadenceScore = 100 - (meanCadence - 180) * 1.5
        } else if meanCadence > 0 {
            // Far from optimal: score decreases more sharply
            if meanCadence < 160 {
                cadenceScore = max(0, 70 - (160 - meanCadence) * 2.0)
            } else {
                cadenceScore = max(0, 70 - (meanCadence - 200) * 2.0)
            }
        } else {
            cadenceScore = 50.0 // Default if no valid cadence data
        }
        
        // Lower vertical oscillation = more efficient
        let efficiency = (cadenceScore + voAbsoluteScore) / 2.0
        
        // Overall Score: average of all six categories
        let overall = (headAlignment + posture + shinVerticalScore + quietFeetScore + footUnderCOMScore + efficiency) / 6.0
        
        return FormScore(
            overall: overall,
            headAlignment: headAlignment,
            posture: posture,
            shinVertical: shinVerticalScore,
            quietFeet: quietFeetScore,
            footUnderCOM: footUnderCOMScore,
            efficiency: efficiency
        )
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
                .foregroundColor(AppTheme.formRed.opacity(0.9))
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
                        .foregroundColor(AppTheme.formRed)
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
    static let cadence = "How many steps you take each minute. For most runners, 170–180 spm is the sweet spot. Quicker, lighter steps soften the impact on your body and help keep injuries away."
    static let groundContact = "How long your foot stays on the ground with each step. Faster runners usually spend 180–250ms down there. If yours is longer, you may be reaching your foot too far out in front (overstriding)."
    static let verticalOscillation = "How much you bounce up and down as you run. Less bounce means more efficiency, and elite runners stay under 6%. Extra bounce just burns energy that could be moving you forward."
    static let symmetry = "How evenly your left and right sides move. You're aiming for 95% or higher. If the two sides don't match up, it can hint at a muscle imbalance or favoring one side after an injury."
    static let trunkLean = "How far your upper body leans forward as you run. A lean of 5–15° is ideal. Standing too upright wastes effort, while leaning too far forward strains your lower back."
    static let hipDrop = "How much your hips tilt to one side when a foot is off the ground. Try to keep this under 5%. A big drop usually means the muscles on the outside of your hips could use some strengthening."
    static let armSwing = "How evenly your arms swing. Ideally they mirror each other. If one arm moves differently, it can point to tight muscles or your sides not working together smoothly."
    static let kneeFlexion = "How much your knee bends through each stride. While your foot is on the ground, running usually calls for 40–60° of bend, and even more as your leg swings through."
    static let hipExtension = "How far your leg drives back behind you as your foot leaves the ground. The more freely your hip opens up here, the more powerful and efficient each stride feels."
    static let elbowRange = "How big your arm swing is. Let your arms swing naturally with your elbows bent around 90°. Swinging them too far just wastes energy."
    
    static let graphCadence = "Your step rate across the whole video. A smooth line means you're holding a steady rhythm. Sudden dips are either a tracking glitch or a real change in your pace."
    static let graphGCT = "How long each foot stays on the ground, with left in cyan and right in green. When the two lines sit close together, your sides are well balanced. Spikes mean a harder-than-usual landing."
    static let graphVerticalOsc = "How much you bounce up and down over time. A steady line means a smooth, even stride. Tall peaks tend to show up when you're tiring or the ground changes."
    static let graphKneeAngle = "How much your knee bends throughout the video. The regular waves follow your natural stride. Flat spots mean the camera briefly lost track of your knee."
    static let graphHipDrop = "The difference in tilt between your left and right hip. Each peak lines up with the moment a foot is planted on the ground."
    
    static let gaitKnee = "Your knee angle across one full stride, scaled from 0–100%. The shaded part is when your foot is on the ground. Compare the left and right lines to check your balance."
    static let gaitHip = "How your hip opens and closes through one full stride. It opens up the most right as your foot pushes off, near the 60% mark. Compare left and right to see if both legs drive evenly."
    static let gaitAnkle = "How your ankle flexes through one full stride. Positive means toes pulled up, negative means toes pointed down. This flex is what gives you power when you push off."
    static let gaitFootY = "How high your foot lifts through one full stride, scaled to your body size. The peaks show how much room your foot has off the ground as your leg swings forward."
    static let gaitFootVel = "How fast your foot moves compared to your hips. The moments the line crosses zero mark when your heel lands and when your toes leave the ground."
}

private enum FormCueTips {
    static let tips: [FormCue: String] = [
        .shinVertical: "This measures how vertical your shin is the moment your foot hits the ground. A near-vertical shin (within about 5° of straight up) means you're landing under your body rather than reaching out in front of it. When the shin angles too far forward, each step acts like a brake, so you lose speed and put extra stress on your knees and shins. Elite marathoners consistently land with the shin close to vertical.",
        .quietFeet: "This tracks how much your foot is decelerating at contact, essentially how hard you're slamming on the brakes with each step. Quieter landings (values under 0.08) mean less wasted energy and lower impact forces through your joints. If you can hear your footsteps clearly, you're probably landing harder than you need to. Think about placing your feet rather than stomping them.",
        .tallPosture: "This measures the forward lean of your torso from the ankles. The sweet spot is roughly 4–10°, enough lean to let gravity pull you forward but not so much that you're hunching. Leaning from the waist instead of the ankles is one of the most common mistakes recreational runners make, and it compresses the diaphragm, limiting how deeply you can breathe.",
        .shortQuickSteps: "Cadence is your step rate in steps per minute. Most efficient distance runners land between 175–195 spm. A higher cadence naturally shortens your stride, which reduces impact and lowers injury risk. You don't need to force it, since even a 5% bump can make a noticeable difference. Try running to a metronome app for a few minutes to recalibrate.",
        .footUnderCOM: "This measures how far ahead of your hips your foot lands. Values near zero mean the foot is touching down right under your center of mass, which eliminates braking forces. When the foot lands ahead (values above 0.06), you're essentially putting on the brakes thousands of times per run. Shortening your stride and increasing your cadence are the fastest ways to fix this.",
        .elbows: "This measures the bend at your elbow during your arm swing. The ideal range is roughly 80–100°, close to a right angle. When the arms are too straight they swing like heavy pendulums, pulling your torso side to side. When they're too tight, tension creeps into your shoulders and neck. Your hands should pass lightly near your waistband, never crossing the centerline of your body.",
        .hipsStable: "Hip drop measures how much one hip dips below the other during single-leg stance. Anything under 4% is solid. Excessive hip drop usually points to weak glutes, specifically the gluteus medius, which is a common contributor to IT band syndrome and knee pain. Single-leg bridges, clamshells, and lateral band walks are the go-to exercises to strengthen this area.",
        .eyesForward: "This tracks how far your head tilts downward from a neutral, eyes-forward position. Keeping your gaze within about 5° of horizontal keeps your cervical spine aligned, your airway open, and your whole postural chain in check. When the head drops, it pulls the shoulders forward and collapses the chest, reducing both breathing efficiency and balance. Pick a point 15–20 meters ahead and hold your gaze there.",
        .footPlacement: "This measures the angle of your foot at the moment of ground contact. A flat landing (within about 8° of neutral) indicates a midfoot strike, which spreads impact across the whole foot and reduces stress on any single structure. Positive angles mean heel-first contact, which sends a sharp impact spike up through the leg. Negative angles mean a forefoot-heavy landing, which can overwork the calves and Achilles tendon over longer distances."
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

private struct FormScore {
    let overall: Double  // 0-100
    let headAlignment: Double  // 0-100
    let posture: Double  // 0-100
    let shinVertical: Double  // 0-100
    let quietFeet: Double  // 0-100
    let footUnderCOM: Double  // 0-100
    let efficiency: Double  // 0-100 (vertical oscillation, cadence consistency)
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

private struct FormScoreView: View {
    let score: FormScore
    
    private var scoreColor: Color {
        switch score.overall {
        case 80...100:
            return .green
        case 60..<80:
            return .yellow
        case 40..<60:
            return .orange
        default:
            return .red
        }
    }
    
    private var scoreLabel: String {
        switch score.overall {
        case 80...100:
            return "Excellent"
        case 60..<80:
            return "Good"
        case 40..<60:
            return "Fair"
        default:
            return "Needs Improvement"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Overall Score Section
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Overall Form Score")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                    
                    Spacer()
                    
                    Text(scoreLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(scoreColor.opacity(0.8))
                }
                
                HStack(alignment: .bottom, spacing: 12) {
                    Text(String(format: "%.0f", score.overall))
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(.white)
                    
                    Text("/ 100")
                        .font(.system(size: 20, weight: .regular))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.bottom, 4)
                    
                    Spacer()
                }
                
                // Overall Progress Bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        // Background
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 16)
                        
                        // Progress fill
                        RoundedRectangle(cornerRadius: 8)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        scoreColor.opacity(0.6),
                                        scoreColor.opacity(0.9)
                                    ]),
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: geo.size.width * CGFloat(score.overall / 100), height: 16)
                    }
                }
                .frame(height: 16)
            }
            .padding(16)
            .background(Color.white.opacity(0.04))
            .cornerRadius(12)
            
            // Category Breakdown
            VStack(alignment: .leading, spacing: 12) {
                Text("Category Breakdown")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                
                VStack(spacing: 10) {
                    CategoryScoreRow(
                        title: "Head Alignment",
                        score: score.headAlignment,
                        description: "Eyes forward (70%), head stability (30%)"
                    )
                    
                    CategoryScoreRow(
                        title: "Posture",
                        score: score.posture,
                        description: "Trunk angle 5-15° (40%), elbow angle 80-100° (30%), vertical oscillation (30%)"
                    )
                    
                    CategoryScoreRow(
                        title: "Shin Vertical",
                        score: score.shinVertical,
                        description: "Shin angle at landing"
                    )
                    
                    CategoryScoreRow(
                        title: "Quiet Feet",
                        score: score.quietFeet,
                        description: "Landing impact and noise"
                    )
                    
                    CategoryScoreRow(
                        title: "Foot Under COM",
                        score: score.footUnderCOM,
                        description: "Foot placement relative to center of mass"
                    )
                    
                    CategoryScoreRow(
                        title: "Efficiency",
                        score: score.efficiency,
                        description: "Cadence 170-180 spm (50%), vertical oscillation <6% (50%)"
                    )
                }
            }
            .padding(16)
            .background(Color.white.opacity(0.04))
            .cornerRadius(12)
        }
        .padding(.horizontal, 20)
    }
}

private struct CategoryScoreRow: View {
    let title: String
    let score: Double
    let description: String
    
    private var scoreColor: Color {
        switch score {
        case 80...100:
            return .green
        case 60..<80:
            return .yellow
        case 40..<60:
            return .orange
        default:
            return .red
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                
                Spacer()
                
                Text(String(format: "%.0f", score))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
            }
            
            Text(description)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.5))
            
            // Mini progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 6)
                    
                    // Progress fill
                    RoundedRectangle(cornerRadius: 4)
                        .fill(scoreColor.opacity(0.8))
                        .frame(width: geo.size.width * CGFloat(score / 100), height: 6)
                }
            }
            .frame(height: 6)
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
    var playheadController: PlayheadController? = nil  // Shared playhead controller for cursor updates
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
            
            if series.isEmpty {
                Text("No data")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(height: 360)
            } else {
                // Graph content - no cursor, no scrolling
                SparklineView(
                    series: series,
                    color: AppTheme.formRed,
                    unit: unit,
                    durationSeconds: durationSeconds,
                    referenceBands: referenceBands,
                    events: events,
                    playbackTime: nil,
                    analysisStartTime: 0,
                    player: nil
                )
                .drawingGroup()  // Cache the graph rendering
                .frame(height: 360)
                .padding(.vertical, 8)
            }
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
    let playheadController: PlayheadController?
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
                            playheadController: playheadController,
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
    let playheadController: PlayheadController?
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
            // Get cursor position from playhead controller (0.0 to 1.0)
            let cursorPercent = playheadController?.playheadPosition ?? 0
            
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
    var playbackTime: Double? = nil  // For cursor display
    var analysisStartTime: Double = 0  // Analysis start offset
    var player: AVPlayer? = nil  // Player for direct cursor updates
    
        var body: some View {
        GeometryReader { geo in
            // Filter out NaN and invalid values
            let validValues = series.filter { !$0.isNaN && $0.isFinite }
            let values = validValues.isEmpty ? [0.0, 0.0] : (validValues.count == 1 ? [validValues[0], validValues[0]] : validValues)
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
                
                // Video-synced cursor - simple Path for smooth rendering
                if let playbackTime = playbackTime, totalSeconds > 0 {
                    let relativeTime = max(0, playbackTime - analysisStartTime)
                    let cursorPercent = min(max(relativeTime / totalSeconds, 0), 1)
                    let cursorX = plotInset.leading + plotWidth * CGFloat(cursorPercent)
                    
                    Path { path in
                        path.move(to: CGPoint(x: cursorX, y: plotInset.top))
                        path.addLine(to: CGPoint(x: cursorX, y: plotInset.top + plotHeight))
                    }
                    .stroke(Color.white, lineWidth: 2.5)
                    .opacity(0.9)
                    .allowsHitTesting(false)  // Don't block scrolling
                }
                
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


// MARK: - Recent Analysis Row
struct RecentAnalysisRow: View {
    let date: String
    let score: String
    
    var body: some View {
        let rowShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(date)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                Text(score)
                    .font(.body.weight(.semibold))
                    .foregroundColor(AppTheme.formRed)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Button(action: {}) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(.white.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.05))
        .clipShape(rowShape)
        .overlay {
            rowShape.stroke(Color.white.opacity(0.07), lineWidth: 1)
        }
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

// MARK: - Gauge Dial

struct GaugeDial: View {
    let score: Int
    let color: Color

    private let arcDegrees: Double = 180
    private var normalizedScore: Double {
        min(max(Double(score), 0), 100) / 100.0
    }

    private var filledEndAngle: Double {
        180 + normalizedScore * 180
    }

    var body: some View {
        ZStack {
            arcTrackBackground
            arcTrackFilled
            scoreLabel
        }
        .frame(width: 64, height: 44)
    }

    private var arcTrackBackground: some View {
        GaugeArcShape(startAngle: 180, endAngle: 360)
            .stroke(
                Color.white.opacity(0.15),
                style: StrokeStyle(lineWidth: 5, lineCap: .round)
            )
            .frame(width: 56, height: 28)
    }

    private var arcTrackFilled: some View {
        Group {
            if filledEndAngle > 180 {
                GaugeArcShape(startAngle: 180, endAngle: filledEndAngle)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                Color(hex: "#FF3B30"),
                                Color(hex: "#FF9500"),
                                Color(hex: "#FFD700"),
                                Color(hex: "#34C759")
                            ]),
                            center: .bottom,
                            startAngle: .degrees(180),
                            endAngle: .degrees(360)
                        ),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
            }
        }
        .frame(width: 56, height: 28)
    }

    private var scoreLabel: some View {
        Text("\(score)")
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.4))
            .cornerRadius(4)
            .offset(y: 10)
    }
}

private struct GaugeArcShape: Shape {
    var startAngle: Double = 180
    var endAngle: Double = 360

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.maxY),
            radius: rect.width / 2,
            startAngle: .degrees(startAngle),
            endAngle: .degrees(endAngle),
            clockwise: false
        )
        return path
    }
}

// MARK: - Running Efficiency Dial (large)

struct RunningEfficiencyDial: View {
    let score: Int?  // nil = no analysis yet

    private var displayScore: Int { score ?? 0 }
    private var normalizedScore: Double {
        guard let s = score else { return 0 }
        return min(max(Double(s), 0), 100) / 100.0
    }
    private var filledEndAngle: Double {
        180 + normalizedScore * 180
    }
    private var scoreColor: Color {
        guard let s = score else { return .gray }
        switch s {
        case 80...100: return .green
        case 60..<80: return .yellow
        case 40..<60: return .orange
        default: return .red
        }
    }
    private var scoreLabel: String {
        guard let s = score else { return "No Data" }
        switch s {
        case 80...100: return "Excellent"
        case 60..<80: return "Good"
        case 40..<60: return "Fair"
        default: return "Needs Work"
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Background arc
                GaugeArcShape(startAngle: 180, endAngle: 360)
                    .stroke(
                        Color.white.opacity(0.12),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .frame(width: 160, height: 80)

                // Filled arc
                if score != nil && filledEndAngle > 180 {
                    GaugeArcShape(startAngle: 180, endAngle: filledEndAngle)
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    Color(hex: "#FF3B30"),
                                    Color(hex: "#FF9500"),
                                    Color(hex: "#FFD700"),
                                    Color(hex: "#34C759")
                                ]),
                                center: .bottom,
                                startAngle: .degrees(180),
                                endAngle: .degrees(360)
                            ),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round)
                        )
                        .frame(width: 160, height: 80)
                }

                // Score text
                VStack(spacing: 2) {
                    if let s = score {
                        Text("\(s)")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    } else {
                        Text("--")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.35))
                    }
                }
                .offset(y: 20)
            }
            .frame(width: 160, height: 100)

            Text(scoreLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(scoreColor.opacity(0.9))
        }
    }
}

struct SprintPowerDial: View {
    let score: Int?
    
    private var displayScore: Int { score ?? 0 }
    private var normalizedScore: Double {
        guard let s = score else { return 0 }
        return min(max(Double(s), 0), 100) / 100.0
    }
    private var filledEndAngle: Double { 180 + normalizedScore * 180 }
    private var scoreColor: Color {
        guard let s = score else { return .gray }
        switch s {
        case 85...100: return Color(hex: "#34C759")
        case 70..<85: return AppTheme.formRed
        case 55..<70: return .orange
        default: return .red
        }
    }
    private var scoreLabel: String {
        guard let s = score else { return "No Data" }
        switch s {
        case 85...100: return "Explosive"
        case 70..<85: return "Strong"
        case 55..<70: return "Developing"
        default: return "Needs Work"
        }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                GaugeArcShape(startAngle: 180, endAngle: 360)
                    .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .frame(width: 160, height: 80)
                
                if score != nil && filledEndAngle > 180 {
                    GaugeArcShape(startAngle: 180, endAngle: filledEndAngle)
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    Color(hex: "#FF3B30"),
                                    Color(hex: "#FF9500"),
                                    AppTheme.formRed,
                                    Color(hex: "#34C759")
                                ]),
                                center: .bottom,
                                startAngle: .degrees(180),
                                endAngle: .degrees(360)
                            ),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round)
                        )
                        .frame(width: 160, height: 80)
                }
                
                VStack(spacing: 2) {
                    if let s = score {
                        Text("\(s)")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                    } else {
                        Text("--")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.35))
                    }
                }
                .offset(y: 20)
            }
            .frame(width: 160, height: 100)
            
            Text(scoreLabel)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(scoreColor.opacity(0.9))
        }
    }
}

// MARK: - Suggestion Card

struct SuggestionCard: View {
    let metricName: String
    let tip: String
    let color: Color
    let score: Int

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(color)
                        .frame(width: 10, height: 10)
                    Text(metricName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                }
                Text(tip)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            GaugeDial(score: score, color: color)
                .padding(.top, 2)
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
        .cornerRadius(10)
    }
}

// MARK: - Sprint Metric Card

struct SprintMetricCard: View {
    let cls: SprintClassification
    var detail: String? = nil
    
    private var color: Color {
        switch cls.score {
        case 80...100: return .green
        case 65..<80: return AppTheme.formRed
        case 50..<65: return .orange
        default: return .red
        }
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 10, height: 10)
                    Text(cls.category)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                    Text(cls.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.15))
                        .cornerRadius(4)
                    if let d = detail {
                        Text(d)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                Text(cls.tip)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            GaugeDial(score: cls.score, color: color)
                .padding(.top, 2)
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
        .cornerRadius(10)
    }
}

// MARK: - Foot Placement Card (label only, no score dial)

struct FootPlacementCard: View {
    let label: String
    let tip: String

    private var accentColor: Color {
        label == "Unknown" ? .gray : AppTheme.formRed.opacity(0.75)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accentColor)
                    .frame(width: 10, height: 10)
                Text("Foot Placement")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Spacer(minLength: 0)
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(accentColor.opacity(0.18))
                    .cornerRadius(8)
            }
            Text(tip)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.white.opacity(0.08))
        .cornerRadius(10)
    }
}

// MARK: - Snapshot View

struct SnapshotView: View {
    let image: UIImage
    let onDismiss: () -> Void
    
    var body: some View {
        NavigationView {
            ZStack {
                AppTheme.bgColor.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 20) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .cornerRadius(12)
                            .padding(.horizontal, 20)
                            .padding(.top, 20)
                        
                        Text("Skeleton at Contact Point")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                            .padding(.horizontal, 20)
                        
                        Text("This snapshot shows your running form at the moment of heel strike (ground contact).")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .foregroundColor(.white)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let imageData = image.pngData() {
                        ShareLink(item: imageData, preview: SharePreview("Skeleton Snapshot")) {
                            Image(systemName: "square.and.arrow.up")
                                .foregroundColor(.white)
                        }
                    }
                }
            }
        }
    }
}


// MARK: - Analyze dashboard widget chrome (iOS-style)
private extension View {
    func analyzeHomeWidgetChrome(padding: CGFloat = 20) -> some View {
        return self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appRaisedSurface(fill: AppTheme.cardBg, cornerRadius: AppTheme.homeWidgetCornerRadius)
    }
}

// MARK: - Video Camera Picker
struct VideoCameraPicker: UIViewControllerRepresentable {
    let onVideoRecorded: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        picker.videoQuality = .typeHigh
        picker.videoMaximumDuration = 30
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onVideoRecorded: onVideoRecorded, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onVideoRecorded: (URL) -> Void
        let onCancel: () -> Void

        init(onVideoRecorded: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onVideoRecorded = onVideoRecorded
            self.onCancel = onCancel
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let url = info[.mediaURL] as? URL {
                onVideoRecorded(url)
            } else {
                onCancel()
            }
        }
    }
}

#Preview {
    AnalyzeView()
}

// MARK: - DisplayLink Helper for Smooth Cursor Updates
private class DisplayLinkTarget: NSObject {
    let callback: () -> Void
    
    init(callback: @escaping () -> Void) {
        self.callback = callback
        super.init()
    }
    
    @objc func update() {
        callback()
    }
}

// MARK: - Cursor Overlay View using UIKit/Core Animation
// Simple cursor that updates from playbackTime prop
private struct CursorOverlayView: UIViewRepresentable {
    let playbackTime: Double?
    let analysisStartTime: Double
    let durationSeconds: Double
    let plotInset: EdgeInsets
    let plotWidth: CGFloat
    let plotHeight: CGFloat
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false  // Don't block scrolling
        view.isHidden = false
        
        // Create cursor layer
        let cursorLayer = CALayer()
        cursorLayer.backgroundColor = UIColor.white.withAlphaComponent(0.9).cgColor
        cursorLayer.frame = CGRect(x: 0, y: plotInset.top, width: 2.5, height: plotHeight)
        view.layer.addSublayer(cursorLayer)
        context.coordinator.cursorLayer = cursorLayer
        
        // Set initial position
        if let playbackTime = playbackTime {
            updateCursorPosition(cursorLayer: cursorLayer, playbackTime: playbackTime)
        }
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        guard let cursorLayer = context.coordinator.cursorLayer,
              let playbackTime = playbackTime else { return }
        
        // Update position directly - no transaction, no animation
        updateCursorPosition(cursorLayer: cursorLayer, playbackTime: playbackTime)
    }
    
    private func updateCursorPosition(cursorLayer: CALayer, playbackTime: Double) {
        guard durationSeconds > 0 else { return }
        let relativeTime = max(0, playbackTime - analysisStartTime)
        let cursorPercent = min(max(relativeTime / durationSeconds, 0), 1)
        let cursorX = plotInset.leading + plotWidth * CGFloat(cursorPercent)
        
        // Direct frame update - minimal overhead
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var frame = cursorLayer.frame
        frame.origin.x = cursorX - 1.25
        cursorLayer.frame = frame
        CATransaction.commit()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var cursorLayer: CALayer?
    }
}

// MARK: - Playhead Cursor View
// Lightweight cursor view that subscribes to shared PlayheadController
// Uses direct CALayer updates at 60fps without triggering SwiftUI redraws
private struct PlayheadCursorView: UIViewRepresentable {
    let playheadController: PlayheadController
    let scrollableWidth: CGFloat
    let height: CGFloat
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        
        let cursorLayer = CALayer()
        cursorLayer.backgroundColor = UIColor.white.withAlphaComponent(0.9).cgColor
        cursorLayer.frame = CGRect(x: 0, y: 24, width: 2.5, height: height - 74)
        view.layer.addSublayer(cursorLayer)
        
        // Register this layer with the playhead controller for direct updates
        let plotInsetLeading: CGFloat = 70
        let plotInsetTrailing: CGFloat = 16
        playheadController.registerCursorLayer(
            cursorLayer,
            scrollableWidth: scrollableWidth,
            plotInsetLeading: plotInsetLeading,
            plotInsetTrailing: plotInsetTrailing
        )
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // No-op: updates happen directly via PlayheadController's CADisplayLink
        // This view never triggers SwiftUI redraws
    }
    
    static func dismantleUIView(_ uiView: UIView, coordinator: ()) {
        // Cleanup handled by PlayheadController's weak references
    }
}












































  


// MARK: - Full history (premium)

/// Premium sheet listing every stored analysis with its raw-data export.
private struct AnalysisHistorySheet: View {
    @ObservedObject private var history = AnalysisHistoryStore.shared

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    var body: some View {
        ZStack {
            AppTheme.bgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("HISTORY")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.top, 24)
                        .padding(.bottom, 6)
                    Text("Every analysis on this device, newest first.")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 14)

                    ForEach(Array(history.records.enumerated()), id: \.element.id) { index, record in
                        if index > 0 {
                            Divider().background(Color.white.opacity(0.06)).padding(.horizontal, 20)
                        }
                        row(record)
                    }
                    Spacer(minLength: 24)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(AppTheme.bgColor)
    }

    private func row(_ record: AnalysisRecord) -> some View {
        HStack(spacing: 12) {
            Text(Self.dateFormatter.string(from: record.date))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
            Spacer()
            let csv = AnalysisHistoryStore.csvURL(for: record.id)
            if FileManager.default.fileExists(atPath: csv.path) {
                ShareLink(item: csv) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Data")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Text(record.overall.map(String.init) ?? "--")
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundColor(AppTheme.formRed)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
