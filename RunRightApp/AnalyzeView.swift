//
//  AnalyzeView.swift
//  RunRightApp
//
//  Pixel-perfect match to HTML prototype with VideoProcessor backend

import SwiftUI
import FirebaseAuth
import ImageIO

/// Decode a downsampled thumbnail straight from encoded image data via ImageIO,
/// instead of decoding the full-resolution snapshot just to draw a tiny cell.
/// This cuts CPU + memory when the history list renders rows on scroll.
func downsampledThumbnail(_ data: Data, maxPixel: CGFloat) -> UIImage? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else { return nil }
    return UIImage(cgImage: cg)
}

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
    static let analyzeSection: Font = AppTheme.sectionTitleFont   // one title size everywhere
    static let analyzeButton: Font = AppTheme.bodySemibold(17)
    static let analyzeBody: Font = AppTheme.body(14)
    static let analyzeCaption: Font = AppTheme.body(13)
    static let analyzeMetric: Font = AppTheme.head(15)
    static let analyzeMeta: Font = AppTheme.meta(11)
    static let analyzeTiny: Font = AppTheme.meta(9)
}

// MARK: - Analysis history (local, on-device)

/// One completed form analysis: its component scores, when it ran, and the full
/// scorecard it produced (snapshot + metrics). Storing the whole scorecard here
/// makes the newest record the single source of truth for the dashboard — a new
/// upload is always the shown snapshot, and deleting a record reverts the scores
/// to the previous analysis.
struct AnalysisRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let efficiency: Int?
    let power: Int?
    let impact: Int?
    var form: StoredScorecardForm?

    init(id: UUID = UUID(), date: Date, efficiency: Int?, power: Int?, impact: Int?, form: StoredScorecardForm? = nil) {
        self.id = id
        self.date = date
        self.efficiency = efficiency
        self.power = power
        self.impact = impact
        self.form = form
    }

    /// Fault-sensitive blend of the present component scores, or nil if none were
    /// measured. Matches the scorecard's `overall` (same `faultSensitiveScore`) so
    /// the number here, on the share card and in the coach all agree — and a single
    /// weak dial pulls the headline down instead of being averaged away.
    var overall: Int? {
        let vals = [efficiency, power, impact].compactMap { $0 }.map(Double.init)
        guard !vals.isEmpty else { return nil }
        return Int(faultSensitiveScore(vals).rounded())
    }

    func withForm(_ f: StoredScorecardForm?) -> AnalysisRecord {
        AnalysisRecord(id: id, date: date, efficiency: efficiency, power: power, impact: impact, form: f)
    }
}

/// Persists form-analysis history locally, newest first. The first record is the
/// "current" analysis the dashboard renders.
final class AnalysisHistoryStore: ObservableObject {
    static let shared = AnalysisHistoryStore()

    @Published private(set) var records: [AnalysisRecord] = []

    private let key = "analysisHistory.v1"
    private let maxRecords = 20

    private init() {
        load()
        migrateLegacyForm()
    }

    /// The current scorecard the dashboard shows: always the newest analysis.
    var currentForm: StoredScorecardForm? { records.first?.form }

    /// The analysis immediately before the current one (for trend arrows).
    var previous: AnalysisRecord? { records.count > 1 ? records[1] : nil }

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

    /// Record a finished analysis (with its full scorecard) at the front.
    @discardableResult
    func add(form: StoredScorecardForm) -> UUID {
        let record = AnalysisRecord(
            date: form.date,
            efficiency: form.efficiency, power: form.power, impact: form.impact,
            form: form
        )
        records.insert(record, at: 0)
        if records.count > maxRecords {
            for evicted in records[maxRecords...] {
                try? FileManager.default.removeItem(at: Self.csvURL(for: evicted.id))
            }
            records = Array(records.prefix(maxRecords))
        }
        save()
        syncCurrentForm()
        return record.id
    }

    /// Remove one analysis. The newest remaining one becomes current, so every
    /// score on the dashboard (and the coach/scorecard) recomputes.
    func delete(id: UUID) {
        records.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.csvURL(for: id))
        save()
        syncCurrentForm()
    }

    /// Mirror the newest form into ScorecardDataStore so the Coach tab and the
    /// share card keep reading "the current analysis" after adds and deletes.
    private func syncCurrentForm() {
        if let f = records.first?.form {
            ScorecardDataStore.shared.save(f)
        } else {
            ScorecardDataStore.shared.clearForm()
        }
        // The Coach tab persists now (not rebuilt per switch), so tell it the
        // current analysis changed so its TODAY insights refresh.
        NotificationCenter.default.post(name: .analysisSaved, object: nil)
    }

    /// Wipe history and every raw CSV export (sign out and account deletion).
    func clearAll() {
        records = []
        UserDefaults.standard.removeObject(forKey: key)
        try? FileManager.default.removeItem(at: Self.exportsDir)
        ScorecardDataStore.shared.clearForm()
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

    /// Upgrade path: older builds kept the newest scorecard only in
    /// ScorecardDataStore and history rows carried no form. Fold that legacy
    /// form into the newest record so the unified model has one everywhere.
    private func migrateLegacyForm() {
        guard let legacy = ScorecardDataStore.shared.load() else { return }
        if records.isEmpty {
            records = [AnalysisRecord(date: legacy.date,
                                      efficiency: legacy.efficiency, power: legacy.power, impact: legacy.impact,
                                      form: legacy)]
            save()
        } else if records.first?.form == nil {
            records[0] = records[0].withForm(legacy)
            save()
        }
    }
}

struct AnalyzeView: View {
    // Shared: a per-view @StateObject was destroyed on every tab switch, which
    // killed in-flight analyses and reloaded the pose model on each visit.
    @ObservedObject private var processor = VideoProcessor.shared
    @ObservedObject private var history = AnalysisHistoryStore.shared
    @State private var selectedItem: PhotosPickerItem?
    #if DEBUG
    @State private var showLabelTool = false
    #endif
    @State private var selectedVideoURL: URL?
    @State private var showingInstructions = false
    @State private var isPreparingVideo = false
    @State private var videoMode: VideoMode = .side  // Default to side view
    @State private var showingSettings = false
    @State private var showingCamera = false
    @State private var cameraUnavailableAlert = false
    @State private var showScan = false
    @State private var showPaywall = false
    @State private var showAllHistory = false
    @State private var showFullMetrics = false
    @State private var metricGuide: MetricGuideEntry?
    @State private var cachedFocusInsights: [CombinedInsight] = []
    @State private var scanUnavailable = false   // set when the scan backend kill-switch is off
    @State private var analysisFailed = false    // set when a clip processed but scored nothing (no runner)
    @State private var analysisFailedReason = ""
    @ObservedObject private var subscriptions = SubscriptionManager.shared
    @AppStorage("userBodyHeightMeters") private var userBodyHeightMeters: Double = 1.7  // Default 1.7m (average height)
    @AppStorage("scan.selectedShoe") private var shoeForTrend = ""
    @ObservedObject private var scanTrend = ScanViewModel.shared
    @State private var shoeCardPage = 0
    @State private var analyzeShoeList: [String] = []
    @State private var fullMetricsMode: RunMode = .distance

    @AppStorage("treadmillDistanceMeters") private var treadmillDistanceMeters: Double = 2.0  // Default 2.0m
    @AppStorage("useImperialUnits") private var useImperialUnits: Bool = true  // Default to feet/inches
    @State private var heightFeet: Int = 5
    @State private var heightInches: Int = 7

    /// The analysis the dashboard renders: always the newest in history, so a
    /// fresh upload immediately becomes the shown snapshot and scores.
    private var currentForm: StoredScorecardForm? { history.currentForm }

    var body: some View {
        ZStack {
            AppTheme.cardBgAlt.ignoresSafeArea()

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
        }
        .onChange(of: selectedItem) { _, newItem in
            Task {
                if let newItem = newItem {
                    await loadVideo(from: newItem)
                }
            }
        }
        // When an analysis finishes: record it (newest = current) and drop the
        // user straight into Full Metrics — the only place the video now lives.
        .onChange(of: processor.processedVideoURL) { _, url in
            guard let processedURL = url else { return }
            Task { await finalizeAnalysis(processedURL: processedURL) }
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
        .sheet(isPresented: $showFullMetrics) {
            fullMetricsSheet
        }
        .alert("Scan temporarily unavailable", isPresented: $scanUnavailable) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Shoe scanning is briefly offline for maintenance. Your form analysis still works — please try again soon.")
        }
        .alert("Couldn't read that clip", isPresented: $analysisFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(analysisFailedReason)
        }
        .sheet(item: $metricGuide) { entry in
            MetricGuideSheet(entry: entry)
        }
        #if DEBUG
        .sheet(isPresented: $showLabelTool) { LabelClipView() }
        #endif
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
    }

    private var analyzeHomeScroll: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                analyzeHeroHeader
                analyzeDashboardWidgets
                Spacer().frame(height: AppTheme.tabBarHeight + 24)
            }
        }
    }

    /// Snapshot first dashboard: the latest analysis still is the hero (66%),
    /// with the Full Metrics tile and the mini shoe grid stacked beside it
    /// (33%). The scorecard is dissolved into the page as a horizontal dial
    /// row, and the 2x2 cue grid states what is wrong — the fixes live in
    /// Coach. Everything reads from the stored form, so it survives relaunch.
    private var analyzeDashboardWidgets: some View {
        VStack(alignment: .leading, spacing: 0) {
            analyzeHeroRow
            Spacer().frame(height: 12)
            analyzeDialRow
            Spacer().frame(height: 12)
            analyzeCueGrid
        }
        .padding(.horizontal, AppTheme.screenPadding)
        .padding(.top, 4)
    }

    // MARK: Hero row — snapshot 66% / (full metrics + shoes) 33%

    /// Decode the stored scorecard still once per unique blob — the body was
    /// re-decoding the JPEG twice on every render.
    private static var heroImageCache: (data: Data, image: UIImage)?
    private func decodedHeroImage(_ png: Data) -> UIImage? {
        if let cached = Self.heroImageCache, cached.data == png { return cached.image }
        guard let img = UIImage(data: png) else { return nil }
        Self.heroImageCache = (png, img)
        return img
    }

    private var analyzeHeroRow: some View {
        let gap: CGFloat = 12
        let rowWidth = UIScreen.main.bounds.width - AppTheme.screenPadding * 2
        let heroW = (rowWidth - gap) * 0.66
        let colW = (rowWidth - gap) * 0.34
        let shoeH: CGFloat = 158
        let historyH: CGFloat = 40
        // The right column stacks metrics tile + heatmap + history button; the
        // snapshot must be at least this tall so the button is never clipped.
        let columnNeeded = colW + gap + shoeH + gap + historyH
        // Natural height from the snapshot, but never shorter than the column
        // and never so tall it dominates the page.
        let heroH: CGFloat = {
            let natural: CGFloat = {
                guard let png = currentForm?.snapshotPNG, let img = decodedHeroImage(png),
                      img.size.width > 0 else { return 360 }
                return heroW * img.size.height / img.size.width
            }()
            return min(max(natural, columnNeeded), 620)
        }()
        return HStack(alignment: .top, spacing: gap) {
            analyzeSnapshotHero
                .frame(width: heroW, height: heroH)
            VStack(spacing: gap) {
                analyzeFullMetricsTile
                    .frame(height: colW)
                analyzeMiniShoeCard
                    .frame(height: shoeH)
                analyzeHistoryButton
                    .frame(height: historyH)
                Spacer(minLength: 0)   // air only when the snapshot is taller
            }
            .frame(width: colW, height: heroH)
        }
    }

    /// Opens the analysis history, where past runs can be deleted (which reverts
    /// the dashboard's scores to the most recent remaining analysis).
    private var analyzeHistoryButton: some View {
        // Viewing your own history is free — it costs us nothing. Never paywall it.
        Button(action: { showAllHistory = true }) {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(AppTheme.meta(11))
                Text("HISTORY")
                    .font(AppTheme.meta(11))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            .foregroundColor(AppTheme.onAccentPrimary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .appRaisedSurface(fill: AppTheme.accentColor, cornerRadius: 14, shadowRadius: 6, x: 4, y: 5, lightOpacity: 0.08, darkOpacity: 0.34)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var analyzeSnapshotHero: some View {
        if processor.error != nil {
            analyzeErrorTile
        } else if let png = currentForm?.snapshotPNG, let img = decodedHeroImage(png) {
            ZStack(alignment: .topTrailing) {
                // Color.clear pins the size to the proposed frame; the image
                // overlays it and gets clipped, so scaledToFill cannot bleed
                // outside the hero slot.
                Color.clear
                    .overlay(
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onTapGesture { showFullMetrics = true }
                    .overlay(alignment: .topLeading) {
                        if let date = currentForm?.date {
                            Text(Self.recentDateFormatter.string(from: date))
                                .font(AppTheme.meta(10))
                                .foregroundColor(.white.opacity(0.9))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.black.opacity(0.45)))
                                .padding(10)
                                .allowsHitTesting(false)
                        }
                    }
                    // Scan-quality disclosure: non blocking, the scorecard still
                    // shows. Tap opens the filming instructions for a retake.
                    .overlay(alignment: .bottomLeading) {
                        if let warning = processor.scanQualityWarning {
                            Button(action: { showingInstructions = true }) {
                                HStack(spacing: 5) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(AppTheme.meta(9))
                                    // Named cause + tap affordance (v2). The cause
                                    // tells the user exactly what to fix.
                                    Text("\(warning) Tap for tips.")
                                        .font(AppTheme.meta(9))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                .foregroundColor(.black)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color(hex: "#FFD23F")))
                            }
                            .buttonStyle(.plain)
                            .padding(10)
                            .accessibilityLabel("Scan quality warning. \(warning) Double tap for filming tips.")
                        }
                    }
                HStack(spacing: 8) {
                    PhotosPicker(selection: $selectedItem, matching: .videos) {
                        analyzeHeroChip("plus")
                    }
                    Button(action: analyzeStartRecording) {
                        analyzeHeroChip("camera.fill")
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
            }
        } else {
            ZStack(alignment: .topTrailing) {
                PhotosPicker(selection: $selectedItem, matching: .videos) {
                    VStack(alignment: .leading, spacing: 0) {
                        Spacer()
                        Text("ANALYZE")
                            .font(AppTheme.display(30))
                            .foregroundColor(AppTheme.onAccentPrimary)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        Text("Upload a running clip")
                            .font(AppTheme.bodyMedium(12))
                            .foregroundColor(AppTheme.onAccentPrimary.opacity(0.7))
                            .padding(.top, 4)
                        Text("SIDE ON · 60 FPS")
                            .font(AppTheme.meta(10))
                            .foregroundColor(AppTheme.onAccentPrimary.opacity(0.6))
                            .padding(.top, 12)
                        Spacer().frame(height: 30)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .appRaisedSurface(fill: AppTheme.accentColor, cornerRadius: 16, shadowRadius: 8, x: 5, y: 6, lightOpacity: 0.08, darkOpacity: 0.34)
                }
                .buttonStyle(.plain)
                Button(action: analyzeStartRecording) {
                    analyzeHeroChip("camera.fill", onAccent: true)
                }
                .buttonStyle(.plain)
                .padding(10)
            }
            .overlay(alignment: .bottomLeading) {
                Button(action: { showingInstructions = true }) {
                    Text("HOW TO FILM")
                        .font(AppTheme.meta(10))
                        .tracking(1)
                        .foregroundColor(AppTheme.onAccentPrimary.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .padding(12)
            }
        }
    }

    private func analyzeHeroChip(_ icon: String, onAccent: Bool = false) -> some View {
        Image(systemName: icon)
            .font(AppTheme.meta(12))
            .foregroundColor(onAccent ? AppTheme.accentColor : .white)
            .frame(width: 30, height: 30)
            .background(Circle().fill(Color.black.opacity(onAccent ? 0.75 : 0.45)))
            .accessibilityLabel(icon == "plus" ? "Upload a running video"
                : icon == "camera.fill" ? "Record a running video" : "")
    }

    private func analyzeStartRecording() {
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            showingCamera = true
        } else {
            cameraUnavailableAlert = true
        }
    }

    private var analyzeFullMetricsTile: some View {
        Button(action: { showFullMetrics = true }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(AppTheme.meta(12))
                        .foregroundColor(AppTheme.primaryText.opacity(0.5))
                }
                Spacer()
                Text("View full metrics")
                    .font(AppTheme.meta(11))
                    .foregroundColor(AppTheme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .appRaisedSurface(fill: AppTheme.cardBg, cornerRadius: 16, shadowRadius: 8, x: 5, y: 6, lightOpacity: 0.08, darkOpacity: 0.34)
        }
        .buttonStyle(.plain)
    }

    /// The wear heatmaps squeezed to the column — identical rendering to the
    /// scan sheet, smaller cells, margins hugging the shoes. Tap to scan.
    private var analyzeMiniShoeCard: some View {
        let latest = scanTrend.loadedShoe == shoeForTrend ? scanTrend.historyPages.last : nil
        let rawLeft = latest?.left?.zones ?? ScorecardDataStore.shared.loadWearZones(side: "left")
        let rawRight = latest?.right?.zones ?? ScorecardDataStore.shared.loadWearZones(side: "right")
        // Display-balanced so the mini pair reads as one consistent pattern.
        let (leftZones, rightZones) = WearSymmetry.balanced(rawLeft, rawRight)
        return Button(action: analyzeOpenScan) {
            HStack(spacing: 5) {
                FootHeatmapView(isLeft: true, wearZones: leftZones, labelDesign: .default,
                                showLabel: false, cellSize: 2.3, cellSpacing: 0.6)
                FootHeatmapView(isLeft: false, wearZones: rightZones, labelDesign: .default,
                                showLabel: false, cellSize: 2.3, cellSpacing: 0.6)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .appRaisedSurface(fill: AppTheme.cardBg, cornerRadius: 16, shadowRadius: 8, x: 5, y: 6, lightOpacity: 0.08, darkOpacity: 0.34)
        }
        .buttonStyle(.plain)
        .task(id: shoeForTrend) {
            await scanTrend.loadScanData(for: shoeForTrend)
        }
    }

    // MARK: Dial row — the scorecard, dissolved

    /// DRIVE / IMPACT / SMOOTH. The arc + a small caption move green when this
    /// analysis beat the last one and red when it slipped, so progress reads at
    /// a glance. Neutral pink before there's anything to compare against.
    private var analyzeDialRow: some View {
        let prev = history.previous
        return HStack(spacing: 12) {
            analyzeDialTile("DRIVE", currentForm?.power, prev?.power, MetricGuide.drive)
            analyzeDialTile("IMPACT", currentForm?.impact, prev?.impact, MetricGuide.impact)
            analyzeDialTile("SMOOTH", currentForm?.efficiency, prev?.efficiency, MetricGuide.smooth)
        }
    }

    private func analyzeDialTile(_ label: String, _ score: Int?, _ prevScore: Int?, _ guide: MetricGuideEntry) -> some View {
        // Trend vs the previous analysis: nil delta = no comparison yet.
        let delta: Int? = (score != nil && prevScore != nil) ? score! - prevScore! : nil
        let arcColor: Color = {
            guard let d = delta, d != 0 else { return AppTheme.accentColor }
            // Same alarm red the cue tiles use — formRed is reserved for the
            // skeleton overlay/scorecard, and two different reds sat side by side.
            return d > 0 ? AppTheme.accentGreen : Color(hex: "#FF3B30")
        }()
        return Button(action: { metricGuide = guide }) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .stroke(AppTheme.primaryText.opacity(0.1), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: Double(min(max(score ?? 0, 0), 100)) / 100)
                        .stroke(arcColor, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(score.map(String.init) ?? "--")
                        .font(AppTheme.display(21))
                        .foregroundColor(AppTheme.primaryText)
                }
                .frame(width: 62, height: 62)
                Text(label)
                    .font(AppTheme.meta(10))
                    .tracking(1)
                    .foregroundColor(AppTheme.primaryText.opacity(0.4))
                // Trend caption — arrow + points changed since the last analysis.
                if let d = delta, d != 0 {
                    HStack(spacing: 2) {
                        Image(systemName: d > 0 ? "arrow.up" : "arrow.down")
                            .font(AppTheme.meta(8))
                        Text("\(abs(d))")
                            .font(AppTheme.meta(10))
                    }
                    .foregroundColor(d > 0 ? AppTheme.accentGreen : Color(hex: "#FF3B30"))
                } else {
                    // Reserve the row so tiles stay the same height with/without a trend.
                    Text(" ").font(AppTheme.meta(10))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .appRaisedSurface(fill: AppTheme.cardBg, cornerRadius: 16, shadowRadius: 8, x: 5, y: 6, lightOpacity: 0.08, darkOpacity: 0.34)
        }
        .buttonStyle(.plain)
    }

    // MARK: 2x2 cue grid — what is wrong, not how to fix it

    private var analyzeCueGrid: some View {
        let cues = currentForm?.cueScores
        func cue(_ c: FormCue) -> Int? { cues?[c.rawValue].map { Int($0.rounded()) } }
        // HEEL BRAKING is the "does the foot land ahead and brake" cue — the exact
        // thing the validated signed shank-angle-at-contact measures. Drive it from
        // that (same source as SHIN / OVERSTRIDE) instead of the old footUnderCOM /
        // shinVertical classifiers, which were never recalibrated and disagree with
        // it (they read a run with a 0° shank as heel-braking). Consistency first.
        let heel: Int? = currentForm.flatMap { $0.overstrideDeg }
            .map { classifyShinStrideSigned(angle: $0).score }
        let head = cue(.eyesForward)
        let arm = cue(.elbows)
        let cad = currentForm.map(\.cadence)

        // Tile color now reflects the SCORE (green good / amber ok / red poor), not
        // a fixed brand color — a red tile behind a 90 read as an alarm.
        func tint(_ v: Int?) -> Color {
            guard let v else { return Color(hex: "#6E6E73") }
            return v >= 80 ? Color(hex: "#34C759") : v >= 60 ? Color(hex: "#FFB020") : Color(hex: "#FF3B30")
        }
        func cadTint(_ c: Int?) -> Color {
            guard let c else { return Color(hex: "#6E6E73") }
            return (165...190).contains(c) ? Color(hex: "#34C759")
                 : (155...200).contains(c) ? Color(hex: "#FFB020") : Color(hex: "#FF3B30")
        }

        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
            analyzeCueBox("HEEL BRAKING", tint(heel), heel,
                          heel.map { $0 < 65 ? "Foot lands out front and brakes each step." : "Foot lands under you." })
            analyzeCueBox("HEAD DOWN", tint(head), head,
                          head.map { $0 < 65 ? "Eyes drop to the ground ahead of you." : "Gaze is level and forward." })
            analyzeCueBox("ARM CARRIAGE", tint(arm), arm,
                          arm.map { $0 < 65 ? "Arms swing across your body." : "Swing is straight, front to back." })
            analyzeCueBox("CADENCE", cadTint(cad), cad,
                          cad.map { $0 < 160 ? "Slow turnover stretches your stride." : $0 <= 190 ? "Turnover is in the range." : "Very quick turnover." })
        }
    }

    private func analyzeCueBox(_ title: String, _ color: Color, _ value: Int?, _ brief: String?) -> some View {
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(title)
                    .font(AppTheme.meta(10))
                    .tracking(1)
                    .foregroundColor(AppTheme.onAccentPrimary.opacity(0.75))
                Spacer(minLength: 0)
                Text(value.map(String.init) ?? "--")
                    .font(AppTheme.display(20))
                    .foregroundColor(AppTheme.onAccentPrimary)
            }
            Text(brief ?? "No analysis yet.")
                .font(AppTheme.body(11))
                .foregroundColor(AppTheme.onAccentPrimary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .frame(height: 96, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(
                    colors: [color, color.opacity(0.62)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .compositingGroup()
        .shadow(color: .black.opacity(0.34), radius: 8, x: 5, y: 6)
    }

    // MARK: Full metrics sheet — the depth lives here, not on the dashboard

    /// Per step GCT, stored trend graphs, exact angles with target ranges, the
    /// full shoe card, and analysis history — everything a beginner does not
    /// need staring at them on the dashboard.
    private var fullMetricsSheet: some View {
        ZStack {
            AppTheme.bgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 28) {
                    HStack {
                        Text("FULL METRICS")
                            .font(AppTheme.head(20))
                            .foregroundColor(AppTheme.primaryText)
                        Spacer()
                        Button(action: { showFullMetrics = false }) {
                            Image(systemName: "xmark")
                                .font(AppTheme.meta(13))
                                .foregroundColor(AppTheme.primaryText.opacity(0.6))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(AppTheme.primaryText.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)

                    // The analysis clip lives here now — the standalone results
                    // page is gone. Shows the newest processed video (or its
                    // snapshot after relaunch).
                    if processor.processedVideoURL != nil || currentForm?.snapshotPNG != nil {
                        AnalyzeVideoCard(
                            videoURL: processor.processedVideoURL,
                            processor: processor,
                            series: processor.metricSeries,
                            fallbackSnapshot: currentForm?.snapshotPNG.flatMap(UIImage.init(data:))
                        )
                        .padding(.horizontal, 20)
                    }

                    // Single run profile — one set of optimal ranges (distance);
                    // the sprint/distance toggle was removed for simplicity.
                    if let form = currentForm {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("ANGLES + TARGETS")
                                .font(AppTheme.sectionTitleFont)
                                .foregroundColor(AppTheme.primaryText)
                            ForEach(form.metrics, id: \.label) { m in
                                let statusColor = (FormStatus(rawValue: m.status) ?? .warn).color
                                HStack(spacing: 10) {
                                    Text(m.label)
                                        .font(AppTheme.head(14))
                                        .foregroundColor(AppTheme.primaryText)
                                    Spacer()
                                    // Value color-coded red→green by how close to optimal.
                                    Text(m.value)
                                        .font(AppTheme.head(14))
                                        .foregroundColor(statusColor)
                                    Text(m.optimal)
                                        .font(AppTheme.meta(12))
                                        .foregroundColor(AppTheme.primaryText.opacity(0.7))
                                        .frame(width: 76, alignment: .trailing)
                                }
                            }
                        }
                        .padding(.horizontal, 20)

                        analyzeStoredTrends(form)
                            .padding(.horizontal, 20)

                        analyzeContactPhase(form)
                            .padding(.horizontal, 20)
                    } else {
                        Text("Run an analysis to fill this in.")
                            .font(.analyzeCaption)
                            .foregroundColor(AppTheme.primaryText.opacity(0.5))
                            .padding(.horizontal, 20)
                    }

                    // What the shape should look like — the research reference,
                    // separate from the user's own graphs above.
                    analyzeOptimalForm
                        .padding(.horizontal, 20)

                    if let series = processor.metricSeries, series.gaitCycleSeries != nil {
                        GroundContactCard(
                            gait: series.gaitCycleSeries,
                            uncertaintyMs: processor.analysisMetrics?.groundContactUncertaintyMs ?? 0
                        )
                    }

                    analyzeRecentSection
                        .padding(.horizontal, 20)

                    Spacer(minLength: 24)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(AppTheme.bgColor)
    }

    /// CONTACT PHASE — ground contact + overstride. Ground contact is a real
    /// timing measurement, now taken from vertical foot motion (belt-invariant)
    /// with sub-frame interpolation and a plausibility gate, so it reads true
    /// stance rather than the inflated forward-reach span. Overstride is direct
    /// sagittal geometry. We deliberately do NOT show modeled peak force or
    /// leg-spring frequency here: those need force-plate-grade timing a phone
    /// can't deliver, and read physically impossible when the timing is off
    /// (Morin 2005, Young 2023 Sensors, Wille 2014).
    @ViewBuilder private func analyzeContactPhase(_ form: StoredScorecardForm) -> some View {
        return VStack(alignment: .leading, spacing: 12) {
            Text("CONTACT PHASE")
                .font(AppTheme.sectionTitleFont)
                .foregroundColor(AppTheme.primaryText)

            if let ms = form.contactMs, ms.isFinite {
                ComparisonTrack(
                    // Lower contact is springier/better down to elite ~180 ms, so the
                    // good zone has no low penalty (matches the ANGLES GCT score, which
                    // greens anything <=300). Only long contact reads slow/"outside".
                    label: "GROUND CONTACT", value: ms, unit: "ms",
                    axisLo: 150, axisHi: 340, zoneLo: 150, zoneHi: 300,
                    readout: "Time your foot is on the ground each step. Trained distance runners sit near 200 to 250 ms. Quicker, springier steps cut it.")
            }
            if let deg = form.overstrideDeg, deg.isFinite {
                ComparisonTrack(
                    label: "OVERSTRIDE", value: deg, unit: "°",
                    axisLo: -12, axisHi: 28, zoneLo: -12, zoneHi: 8,
                    readout: "Shin angle at contact. Positive means your foot lands ahead of your body. Lift cadence 5 to 10 percent to land under you.",
                    decimals: 0)
            }
            Text("Ground contact is a timing estimate (best at 60 fps or higher); overstride is direct sagittal geometry. We don't show modeled force or leg stiffness — a phone can't measure those without a force plate.")
                .font(AppTheme.body(9))
                .foregroundColor(AppTheme.primaryText.opacity(0.3))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Map a joint chart's reference name to that joint's stored 11-decile curve.
    private static func jointCurve(_ form: StoredScorecardForm, refName: String) -> [Double]? {
        switch refName {
        case "Knee flexion": return form.kneeCycle
        case "Ankle":        return form.ankleCycle
        default:             return nil
        }
    }

    /// The headline: research-backed reference form, drawn as a shaded gait-cycle
    /// band (knee, ankle) that ADAPTS to the runner's own history once they have
    /// a few analyses, blended with the population norm and compared in shape
    /// space. The pipeline stores per-contact scalars plus these cycle curves, so
    /// the user's measured line is dropped on the band where it exists.
    private var analyzeOptimalForm: some View {
        // The user's own measured gait-cycle curves, if the last analysis stored
        // them. Same curve regardless of mode — only the optimal band switches.
        let userCurves: [String: [Double]] = {
            guard let f = currentForm else { return [:] }
            var out: [String: [Double]] = [:]
            if let k = f.kneeCycle, k.count == 11 { out["Knee flexion"] = k }
            if let a = f.ankleCycle, a.count == 11 { out["Ankle"] = a }
            // Hip dropped: from a side view the hip angle is thigh-relative-to-
            // trunk, so forward lean is baked into it with no way to separate the
            // two. Its line was falling off its own axis for exactly this reason.
            return out
        }()
        let blue = AppTheme.accentColor   // signature cyan/blue

        // The runner's PAST analyses (everything except the current one) drive the
        // personalized band: the reference adapts to what they already do, blended
        // with the population norm and capped so it can't become pure self-
        // endorsement. Cold start (no history) → the fixed population band.
        let pastForms: [StoredScorecardForm] = history.records.dropFirst().compactMap { $0.form }

        return VStack(alignment: .leading, spacing: 12) {
            Text(userCurves.isEmpty ? "TYPICAL FORM SHAPE" : "YOUR RUN VS TYPICAL")
                .font(AppTheme.sectionTitleFont)
                .foregroundColor(AppTheme.primaryText)
            ForEach(FormReference.joints(fullMetricsMode).indices, id: \.self) { i in
                let ref = FormReference.joints(fullMetricsMode)[i]
                let past = pastForms.compactMap { Self.jointCurve($0, refName: ref.name) }
                let overlay = AdaptiveForm.overlay(joint: ref, pastCurves: past)
                GaitCycleReferenceChart(
                    ref: ref,
                    accent: blue,
                    userCurve: userCurves[ref.name],
                    userAccent: AppTheme.primaryText,
                    personalCenter: overlay?.center,
                    personalHalfWidth: overlay?.halfWidth,
                    wSelf: overlay?.wSelf ?? 0
                )
            }
            Text("Shaded bands are the typical range from published running kinematics (Novacheck, Schache, Nagahara), not a target: good form is individual, not one line. Your line is this run's cycle average, aligned to the band to compare the shape of your motion since camera angle shifts the exact degrees. Ankle is the least reliable joint from a side view.")
                .font(AppTheme.body(9))
                .foregroundColor(AppTheme.primaryText.opacity(0.3))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Cut a trend series at the point it goes flat (tracking lost / runner
    /// leaves frame → the pipeline carries the last value forward as a constant).
    /// Drops the maximal trailing run of near-constant samples, keeping a small
    /// floor so a legitimately steady signal is never erased.
    static func truncateFlatTail(_ series: [Double], minRun: Int = 8, keepFloor: Int = 12) -> [Double] {
        let v = series.filter { $0.isFinite }
        guard v.count > max(minRun, keepFloor) else { return v }
        let (lo, hi) = robustRange(v)
        let eps = max((hi - lo) * 0.01, 1e-6)
        var i = v.count - 1
        while i > 0 && abs(v[i] - v[i - 1]) <= eps { i -= 1 }
        let flatLen = (v.count - 1) - i
        guard flatLen >= minRun else { return v }
        return Array(v.prefix(max(i + 1, keepFloor)))
    }

    /// 5th–95th percentile range of a series (NaN/inf dropped), so trend graphs
    /// normalise against the real signal and not a lone outlier.
    static func robustRange(_ values: [Double]) -> (Double, Double) {
        let v = values.filter { $0.isFinite }.sorted()
        guard v.count >= 2 else { return (v.first ?? 0, v.last ?? 1) }
        let loIdx = Int((Double(v.count - 1) * 0.05).rounded(.down))
        let hiIdx = Int((Double(v.count - 1) * 0.95).rounded())
        return (v[max(0, loIdx)], v[min(hiIdx, v.count - 1)])
    }

    /// Stored trend graphs from the last analysis (per frame series persisted
    /// with the form): ground contact, bounce, cadence.
    @ViewBuilder private func analyzeStoredTrends(_ form: StoredScorecardForm) -> some View {
        let charts: [(String, [Double]?)] = [
            ("GROUND CONTACT", form.gct),
            ("BOUNCE", form.bounce),
            ("CADENCE", form.cadenceTrend)
        ]
        VStack(alignment: .leading, spacing: 14) {
            ForEach(charts.filter { ($0.1?.count ?? 0) >= 2 }, id: \.0) { chart in
                let raw = (chart.1 ?? []).filter(\.isFinite)
                // Robust range (5th–95th percentile) so one insane sample can't
                // squash the real signal to a flat line; points clamp to 0...1
                // so an outlier never paints outside the frame either.
                let (lo, hi) = Self.robustRange(raw)
                let points = hi > lo
                    ? raw.map { CGFloat(min(max(($0 - lo) / (hi - lo), 0), 1)) }
                    : []
                if points.count >= 2 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(chart.0)
                            .font(AppTheme.sectionTitleFont)
                            .foregroundColor(AppTheme.primaryText)
                        TrendChartView(dataPoints: points,
                                       accent: AppTheme.accentColor, bg: AppTheme.cardBg)
                            .frame(height: 64)
                            .clipped()
                    }
                }
            }
        }
    }

    /// Scorecard in its own separate gray box, to the right of the action card.
    // MARK: - Scores (Efficiency / Power / Impact — uniform, on-theme)
    private var impactReading: ImpactResult? {
        guard let series = processor.metricSeries, let metrics = processor.analysisMetrics else { return nil }
        return impactResult(series: series, metrics: metrics, userBodyHeightMeters: userBodyHeightMeters)
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
                              wear: wear, hasVideo: true, hasShoe: hasShoe,
                              shankAngleAtContactSignedDeg: series.shankAngleAtContactSignedDeg.isFinite
                                  ? series.shankAngleAtContactSignedDeg : nil)
    }

    // MARK: - Recent (bare list — spacing separates rows, no card, no dividers)
    private var analyzeRecentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RECENT")
                .font(.analyzeTiny)
                .foregroundColor(AppTheme.primaryText.opacity(0.35))
                .padding(.bottom, 6)

            let recent = Array(history.records.prefix(3))
            if recent.isEmpty {
                Text("No analyses yet.")
                    .font(.analyzeCaption)
                    .foregroundColor(AppTheme.primaryText.opacity(0.5))
                    .padding(.top, 6)
            } else {
                ForEach(recent) { record in
                    recentFullRow(record)
                }

                if history.records.count > recent.count {
                    Button(action: { showAllHistory = true }) {
                        Text("SEE ALL")
                            .font(AppTheme.meta(11))
                            .foregroundColor(AppTheme.accentColor)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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
                .foregroundColor(AppTheme.primaryText.opacity(0.85))
            Spacer()
            if hasExport(for: record.id) {
                ShareLink(item: csvFileURL(for: record.id)) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(AppTheme.bodySemibold(11))
                        Text("Data")
                            .font(.analyzeMeta)
                    }
                    .foregroundColor(AppTheme.primaryText.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(AppTheme.primaryText.opacity(0.08)))
                    .overlay(Capsule().stroke(AppTheme.primaryText.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Text(record.overall.map(String.init) ?? "—")
                .font(.analyzeMetric)
                .foregroundColor(AppTheme.accentColor)
        }
        .padding(.vertical, 12)
    }

    private var analyzeErrorTile: some View {
        VStack(spacing: 10) {
            Text("Analysis failed")
                .font(AppTheme.bodySemibold(15))
                .foregroundColor(AppTheme.primaryText)
            if let error = processor.error {
                Text(error)
                    .font(AppTheme.body(11))
                    .foregroundColor(AppTheme.primaryText.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }
            Button("Try again") { resetProcessor() }
                .font(AppTheme.bodySemibold(13))
                .foregroundColor(AppTheme.accentColor)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appRaisedSurface(fill: AppTheme.cardBg, cornerRadius: 20)
    }

    private var analyzeShoeHeatGridCard: some View {
        // Zones follow the shoe picked in the header; local store is the
        // fallback when that shoe's history hasn't loaded (or guest mode).
        let latest = scanTrend.loadedShoe == shoeForTrend ? scanTrend.historyPages.last : nil
        let leftZones = latest?.left?.zones ?? ScorecardDataStore.shared.loadWearZones(side: "left")
        let rightZones = latest?.right?.zones ?? ScorecardDataStore.shared.loadWearZones(side: "right")
        let gaitType = latest?.left?.gaitType ?? latest?.right?.gaitType ?? ScorecardDataStore.shared.loadGaitType()
        let strikePattern = latest?.left?.strikePattern ?? latest?.right?.strikePattern ?? ScorecardDataStore.shared.loadGaitStrike()
        let hasScan = leftZones != nil || rightZones != nil
        let health = analyzeCombinedShoeHealth(
            leftPercents: latest?.left?.wearPercents, rightPercents: latest?.right?.wearPercents,
            leftZones: leftZones, rightZones: rightZones)
        // Replace shoes as a pair, so the more worn side sets the estimate.
        let milesLeft = [latest?.left?.estimatedMilesRemaining, latest?.right?.estimatedMilesRemaining]
            .compactMap { $0 }.min()

        return VStack(alignment: .leading, spacing: 10) {
            TabView(selection: $shoeCardPage) {
                analyzeHeatGridPage(leftZones: leftZones, rightZones: rightZones,
                                     gaitType: gaitType, strikePattern: strikePattern, hasScan: hasScan)
                    .tag(0)
                analyzeShoeMetricsPage(gaitType: gaitType, strikePattern: strikePattern,
                                        health: health, milesRemaining: milesLeft)
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 272)

            HStack(spacing: 5) {
                Circle().fill(AppTheme.primaryText.opacity(shoeCardPage == 0 ? 0.75 : 0.22)).frame(width: 5, height: 5)
                Circle().fill(AppTheme.primaryText.opacity(shoeCardPage == 1 ? 0.75 : 0.22)).frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .analyzeHomeWidgetChrome(padding: 18)
        .task(id: shoeForTrend) {
            if analyzeShoeList.isEmpty, let uid = Auth.auth().currentUser?.uid {
                analyzeShoeList = (try? await ScanRepository.shared.fetchShoeNames(uid: uid)) ?? []
            }
            await scanTrend.loadScanData(for: shoeForTrend)
        }
    }

    /// Tap on a heat-grid page body opens the scanner (paywalled). Lives on the
    /// page content, not the TabView, so the header's shoe Menu keeps its tap.
    private func analyzeOpenScan() {
        // Free tier gets a monthly allowance of scans (real API cost). Premium is
        // unlimited. The scanner itself records each completed side; we gate on
        // open, so a session already underway can finish its left+right pair.
        if !RemoteConfigManager.shared.scanEnabled { scanUnavailable = true }
        else if UsageLimits.shared.canScan(isPremium: subscriptions.isPremium) { showScan = true }
        else { showPaywall = true }
    }

    /// Page 1 — the wear heatmaps. Swipe left for gait metrics + wear trend;
    /// tap the heatmaps to scan.
    private func analyzeHeatGridPage(leftZones rawLeft: WearZoneData?, rightZones rawRight: WearZoneData?,
                                      gaitType: String?, strikePattern: String?, hasScan: Bool) -> some View {
        // Balance the two shoes for display so they read as one consistent
        // pattern (raw zones still drive the metrics/health/FOCUS elsewhere).
        let (leftZones, rightZones) = WearSymmetry.balanced(rawLeft, rawRight)
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("SHOE HEAT GRID")
                    .font(.analyzeSection)
                    .foregroundColor(AppTheme.primaryText)
                Spacer()
                Menu {
                    ForEach(analyzeShoeList, id: \.self) { shoe in
                        Button(shoe) { shoeForTrend = shoe }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(shoeForTrend.isEmpty ? "Select shoe" : shoeForTrend)
                            .font(AppTheme.bodyMedium(11))
                            .foregroundColor(AppTheme.primaryText.opacity(0.75))
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(AppTheme.bodySemibold(8))
                            .foregroundColor(AppTheme.primaryText.opacity(0.4))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .appRaisedBox(cornerRadius: 10)
                }
            }

            // A Button, not onTapGesture — plain tap gestures get swallowed by
            // the paged TabView's scroll view, button taps don't.
            Button(action: analyzeOpenScan) {
                VStack(spacing: 14) {
                    HStack(alignment: .center, spacing: 16) {
                        FootHeatmapView(isLeft: true, wearZones: leftZones, labelDesign: .default, showLabel: false)
                        FootHeatmapView(isLeft: false, wearZones: rightZones, labelDesign: .default, showLabel: false)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)

                    if !hasScan {
                        HStack(spacing: 5) {
                            if !subscriptions.isPremium {
                                Image(systemName: "lock.fill")
                                    .font(AppTheme.meta(8))
                            }
                            Text("TAP TO SCAN YOUR SHOES")
                                .font(.analyzeTiny)
                        }
                        .foregroundColor(AppTheme.primaryText.opacity(0.45))
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Page 2 — boxed GAIT / STRIKE / HEALTH stats + the wear-over-time trend
    /// (was its own SHOE HEALTH card; now lives a swipe away from the heatmaps
    /// instead of duplicating the same read lower on the page).
    private func analyzeShoeMetricsPage(gaitType: String?, strikePattern: String?,
                                         health: Int?, milesRemaining: Int?) -> some View {
        Button(action: analyzeOpenScan) {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("SHOE HEALTH")
                    .font(.analyzeSection)
                    .foregroundColor(AppTheme.primaryText)
                Spacer()
                if let milesRemaining {
                    Text("~\(milesRemaining) MILES LEFT")
                        .font(AppTheme.bodyMedium(11))
                        .foregroundColor(AppTheme.primaryText.opacity(0.75))
                }
            }

            HStack(spacing: 10) {
                analyzeShoeStatBox(label: "GAIT", value: gaitType?.uppercased() ?? "--")
                analyzeShoeStatBox(label: "STRIKE", value: strikePattern?.uppercased() ?? "--")
                analyzeShoeStatBox(label: "HEALTH", value: health.map { "\($0)%" } ?? "--")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("WEAR OVER TIME")
                    .font(.analyzeTiny)
                    .foregroundColor(AppTheme.primaryText.opacity(0.4))

                if scanTrend.hasTrend {
                    TrendChartView(dataPoints: scanTrend.trendPoints, accent: AppTheme.accentColor, bg: AppTheme.bgColor)
                        .frame(height: 70)
                    HStack {
                        if let first = scanTrend.trendLabels.first {
                            Text(first).font(AppTheme.bodyMedium(10)).foregroundColor(AppTheme.primaryText.opacity(0.4))
                        }
                        Spacer()
                        if let last = scanTrend.trendLabels.last {
                            Text(last).font(AppTheme.bodyMedium(10)).foregroundColor(AppTheme.primaryText.opacity(0.4))
                        }
                    }
                } else {
                    Text("Scan a few more times to see a trend.")
                        .font(AppTheme.body(12))
                        .foregroundColor(AppTheme.primaryText.opacity(0.35))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 70)
                }
            }
        }
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func analyzeShoeStatBox(label: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.analyzeMetric)
                .foregroundColor(AppTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.analyzeTiny)
                .foregroundColor(AppTheme.accentColor.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .appRaisedBox()
    }

    private func analyzeShoeSummary(gaitType: String?, strikePattern: String?) -> String {
        let gait = gaitType?.uppercased() ?? "GAIT READY"
        guard let strikePattern, !strikePattern.isEmpty else { return gait }
        return "\(gait) · \(strikePattern.uppercased()) STRIKE"
    }

    private func analyzeCombinedShoeHealth(leftPercents: [String: Int]?, rightPercents: [String: Int]?,
                                            leftZones: WearZoneData?, rightZones: WearZoneData?) -> Int? {
        let values = [
            analyzeShoeHealthPercent(percents: leftPercents, zones: leftZones),
            analyzeShoeHealthPercent(percents: rightPercents, zones: rightZones)
        ].compactMap { $0 }
        guard !values.isEmpty else { return nil }
        return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
    }

    /// Health per shoe. Scans from the gpt-5.6 upgrade carry numeric wear depth
    /// per zone (0 fresh, 100 gone) — average those for a finer read. Older
    /// scans fall back to the four color buckets.
    private func analyzeShoeHealthPercent(percents: [String: Int]?, zones: WearZoneData?) -> Int? {
        if let percents, !percents.isEmpty {
            let avgWear = Double(percents.values.reduce(0, +)) / Double(percents.count)
            return Int((100 - avgWear).rounded())
        }
        return analyzeShoeHealthPercent(zones: zones)
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

    // MARK: - Hero header (dashboard)
    private var analyzeHeroHeader: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("Form ")
                        .foregroundColor(AppTheme.primaryText)
                    Text("Analysis")
                        .foregroundColor(AppTheme.primaryText)
                }
                .font(AppTheme.display(32))
            }
            Spacer(minLength: 8)
            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(AppTheme.bodySemibold(14))
                    .foregroundColor(AppTheme.primaryText.opacity(0.45))
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(AppTheme.primaryText.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Analysis settings")
        }
        .padding(.horizontal, AppTheme.screenPadding)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }
    
    private func computeEfficiencyScore(series: MetricSeries?, metrics: AnalysisMetrics? = nil) -> Int? {
        let arm = metrics.map { max($0.elbowRangeLeft, $0.elbowRangeRight) }
        guard let series, let bd = computeEfficiencyBreakdown(series: series, armSwingRangeDeg: arm) else { return nil }
        return bd.composite
    }
    
    private func computeSprintPowerScore() -> Int? {
        guard let series = processor.metricSeries, let metrics = processor.analysisMetrics else { return nil }
        return computeSprintPowerComposite(series: series, metrics: metrics, userBodyHeightMeters: userBodyHeightMeters)
    }

    enum CycleJoint { case knee, hip, ankle }

    /// Cycle-averaged joint FLEXION over the gait cycle, resampled to 11 deciles
    /// so it can overlay the optimal reference. The pipeline already stores all
    /// three joints as flexion-positive (0 = straight): knee = 180−interior,
    /// hip/ankle = 180−interior at source. So NO per-joint conversion here — the
    /// old `180 − knee` inverted the knee curve against its flexion band.
    /// nil when the cycle wasn't resolved.
    static func cycleFlexion(_ g: GaitCycleSeries?, joint: CycleJoint) -> [Double]? {
        guard let g else { return nil }
        let (left, right): ([Double], [Double]) = {
            switch joint {
            case .knee:  return (g.leftKneeAngle, g.rightKneeAngle)
            case .hip:   return (g.leftHipAngle, g.rightHipAngle)
            case .ankle: return (g.leftAnkleAngle, g.rightAnkleAngle)
            }
        }()
        let merged = mergeLegs(left, right)
        guard merged.count >= 3 else { return nil }
        return resample(merged, to: 11)
    }

    /// Average a per-frame series over consecutive foot-hip peaks (strike→strike)
    /// into an 11-decile cycle curve. Used as a fallback when strict gait-cycle
    /// detection fails but the reliable cadence peaks still exist.
    static func foldOverPeaks(_ series: [Double], peaks: [Double], bins: Int = 11) -> [Double]? {
        let idx = peaks.map { Int($0.rounded()) }.filter { $0 >= 0 && $0 < series.count }
        guard idx.count >= 3, series.count >= 3 else { return nil }
        var acc = Array(repeating: 0.0, count: bins)
        var counts = Array(repeating: 0, count: bins)
        for c in 0..<(idx.count - 1) {
            let start = idx[c], end = idx[c + 1]
            guard end > start else { continue }
            let span = Double(end - start)
            for b in 0..<bins {
                let t = Double(b) / Double(bins - 1)
                let p = Double(start) + t * span
                let lo = Int(p.rounded(.down)); let hi = min(lo + 1, series.count - 1)
                let f = p - Double(lo)
                let v0 = series[lo], v1 = series[hi]
                if v0.isFinite && v1.isFinite {
                    acc[b] += v0 + (v1 - v0) * f
                    counts[b] += 1
                }
            }
        }
        let out = (0..<bins).map { counts[$0] > 0 ? acc[$0] / Double(counts[$0]) : Double.nan }
        return out.allSatisfy(\.isFinite) ? out : nil
    }

    private static func mergeLegs(_ a: [Double], _ b: [Double]) -> [Double] {
        let af = a.filter(\.isFinite), bf = b.filter(\.isFinite)
        if af.isEmpty { return bf }
        if bf.isEmpty { return af }
        let n = min(af.count, bf.count)
        return (0..<n).map { (af[$0] + bf[$0]) / 2 }
    }

    private static func resample(_ arr: [Double], to n: Int) -> [Double] {
        guard arr.count >= 2 else { return arr }
        return (0..<n).map { i in
            let pos = Double(i) / Double(n - 1) * Double(arr.count - 1)
            let lo = Int(pos.rounded(.down)); let hi = min(lo + 1, arr.count - 1)
            let f = pos - Double(lo)
            return arr[lo] * (1 - f) + arr[hi] * f
        }
    }

    /// Runs when an analysis completes: builds the scorecard, files it as the
    /// newest history record (which becomes the dashboard's current analysis),
    /// writes its raw-data CSV, and opens Full Metrics on this new result.
    @MainActor
    private func finalizeAnalysis(processedURL: URL) async {
        guard let form = await buildScorecardForm(processedURL: processedURL) else {
            // The clip processed to completion but nothing was scoreable — almost
            // always no runner in frame. Without feedback here the loading overlay
            // just vanishes after a long wait and the dashboard silently reverts to
            // the previous analysis. Tell the user why (using the scan-quality cause
            // when we have one) and reset, which also clears the stale warning so it
            // isn't painted onto the previous run's still-visible scorecard.
            analysisFailedReason = processor.scanQualityWarning
                ?? "We couldn't find a runner in that clip. Film side-on with your whole body in frame, then try again."
            resetProcessor()
            analysisFailed = true
            return
        }
        let id = history.add(form: form)          // newest → current everywhere
        persistRawDataCSV(for: id)
        refreshFocusInsights()
        showFullMetrics = true
    }

    /// Assemble the full scorecard for the just-processed clip. Returns nil when
    /// the clip was too poor to score anything.
    private func buildScorecardForm(processedURL: URL) async -> StoredScorecardForm? {
        guard
            let series = processor.metricSeries,
            let metrics = processor.analysisMetrics,
            let efficiency = computeEfficiencyScore(series: series, metrics: metrics),
            let power = computeSprintPowerScore(),
            let impact = impactReading?.score,
            let breakdown = computeEfficiencyBreakdown(
                series: series,
                armSwingRangeDeg: max(metrics.elbowRangeLeft, metrics.elbowRangeRight)
            )
        else { return nil }

        let snapshotPNG = await scorecardSnapshotPNG(from: processedURL, series: series)
        // Canonical cadence: the same peak-based estimator as the results
        // headline so the scorecard and coach agree.
        let actualDuration = ((try? await AVAsset(url: processedURL).load(.duration))?.seconds) ?? 0
        let footHip = !series.rightFootHipDistanceSeries.isEmpty
            ? series.rightFootHipDistanceSeries : series.leftFootHipDistanceSeries
        // fps from the ANALYZED window, not the full output video. The pipeline
        // trims poseFrames (clean-window + stopped-frame trims), so footHip.count
        // counts only analyzed frames while the video stays full length —
        // footHip.count / videoDuration would under-report fps (and thus cadence).
        let windowDuration = series.durationSeconds > 0.1 ? series.durationSeconds : actualDuration
        let fps = windowDuration > 0 && !footHip.isEmpty ? Double(footHip.count) / windowDuration : 30.0
        let peaks = AnalyzeMath.detectLocalMaxima(footHip, frameRate: fps)
        let peakCadence = peaks.count >= 2 ? AnalyzeMath.calculateCadenceFromPeaks(peaks, frameRate: fps) : 0
        // Jitter-robust cadence: autocorrelation of the foot-hip signal. Peak
        // counting inflates on noisy footage (it once reported 229 spm). Prefer
        // the autocorrelation period; fall back to the cycle-based measurement
        // only when there is no clear periodicity to lock onto.
        let autoCadence = AnalyzeMath.dominantCadence(footHip, frameRate: fps)
        // Autocorrelation is the trusted read. If it finds no clear periodicity,
        // fall back to the cycle-based measurement (bounded, plausible) — NEVER to
        // the peak counter, which is the thing that inflates on jitter.
        let canonicalCadence = autoCadence > 0 ? autoCadence : metrics.cadence
        #if DEBUG
        debugLog("[Cadence] peak=\(Int(peakCadence)) auto=\(Int(autoCadence)) cycleMetrics=\(Int(metrics.cadence)) fps=\(String(format: "%.1f", fps)) n=\(footHip.count) -> canonical=\(Int(canonicalCadence))")
        #endif
        // One overall, used everywhere (this card, history, the share card and the
        // coach): the same fault-sensitive blend of the three dials as
        // AnalysisRecord.overall, so no surface disagrees. Each fault now lives in
        // its dial — over-kipped legs pull DRIVE, flailing arms pull SMOOTH — so a
        // plain blend already reflects them; fault-sensitivity keeps one weak dial
        // from being averaged away behind two strong ones.
        let powerRes = powerResult(series: series, metrics: metrics)
        let overall = overallFormScore(
            smooth: efficiency, drive: power, impact: impact,
            driveConfidence: powerRes.confidence,
            impactConfidence: impactReading?.confidence ?? .low)
#if DEBUG
        debugLog("[Overall] eff=\(efficiency) power=\(power) impact=\(impact) -> overall=\(overall)")
#endif
        let gctValues = [metrics.groundContactLeft, metrics.groundContactRight].filter { $0 > 0 }
        let avgGCT = gctValues.isEmpty ? nil : gctValues.reduce(0, +) / Double(gctValues.count)

        // Per-joint "your run" curve: prefer the strict gait-cycle average, but
        // fall back to folding the per-frame flexion series over the reliable
        // foot-hip peaks (the same peaks that gave cadence) so the overlay still
        // appears when strict cycle detection fails on a noisy clip.
        let usingRight = !series.rightFootHipDistanceSeries.isEmpty
        func robustCycle(_ joint: CycleJoint) -> [Double]? {
            if let strict = Self.cycleFlexion(series.gaitCycleSeries, joint: joint) { return strict }
            let flexTime: [Double]
            switch joint {
            case .knee:  flexTime = usingRight ? series.rightKneeAngleTimeSeries  : series.leftKneeAngleTimeSeries
            case .hip:   flexTime = usingRight ? series.rightHipAngleTimeSeries   : series.leftHipAngleTimeSeries
            case .ankle: flexTime = usingRight ? series.rightAnkleAngleTimeSeries : series.leftAnkleAngleTimeSeries
            }
            // The joint time series are TRIMMED (start at analysisStartTime) but
            // footHip/peaks are full-length — both come from the same frame count,
            // so the trim offset is exactly the length difference. Shift the peaks
            // into the trimmed frame space before folding, or they read wrong frames.
            let offset = max(0, footHip.count - flexTime.count)
            let aligned = peaks.map { $0 - Double(offset) }
            // The per-frame series are already flexion-positive — return as-is,
            // matching cycleFlexion (no knee inversion).
            return Self.foldOverPeaks(flexTime, peaks: aligned)
        }

        let rows: [StoredScorecardMetric] = [
            scorecardMetric(label: "CAD", value: "\(analyzeSafeInt(canonicalCadence))", optimal: "165-200", score: cadenceScore(canonicalCadence)),
            scorecardMetric(label: "TORSO", value: degreeText(series.torsoAngleMean), optimal: "0-14°", score: breakdown.torso.score),
            scorecardMetric(label: "SHIN", value: degreeText(abs(series.shankAngleAtContactSignedDeg)), optimal: "<12°", score: breakdown.shin.score),
            scorecardMetric(label: "KNEE", value: degreeText(series.kneeAngleMean), optimal: "112-138", score: kneeScore(series.kneeAngleMean)),
            scorecardMetric(label: "ELBOW", value: degreeText(series.elbowAngleMean), optimal: "70-120°", score: breakdown.elbow.score),
            scorecardMetric(label: "GCT", value: avgGCT.map { "\(Int($0.rounded()))" } ?? "--", optimal: "<320", score: avgGCT.map(groundContactScore) ?? 0),
            scorecardMetric(label: "STRIKE", value: metrics.footStrikePattern.uppercased().prefix(4).description, optimal: "--", score: 0, neutral: true)
        ]
        // HIP dropped: a side view has no vertical/pelvis reference, so hip angle
        // = thigh-relative-to-trunk and bakes in forward lean (unmeasurable
        // confound). GCT is now measured from vertical foot motion (plausibility-
        // gated), so it reads real stance time instead of the inflated forward-
        // reach span. STRIKE shown as a neutral observation, not graded (evidence
        // doesn't support prescribing a foot-strike pattern).

        return StoredScorecardForm(
            date: Date(),
            overall: overall,
            power: power,
            impact: impact,
            efficiency: efficiency,
            cadence: analyzeSafeInt(canonicalCadence),
            metrics: rows,
            snapshotPNG: snapshotPNG,
            bounce: Self.truncateFlatTail(series.headBobbingYSeries.filter { $0.isFinite }),
            gct: {
                let l = series.groundContactLeftSeries
                let r = series.groundContactRightSeries
                var out: [Double] = []
                for i in 0..<max(l.count, r.count) {
                    if i < l.count { out.append(l[i]) }
                    if i < r.count { out.append(r[i]) }
                }
                return Self.truncateFlatTail(out.filter { $0.isFinite })
            }(),
            cadenceTrend: Self.truncateFlatTail(series.cadenceSeries.filter { $0.isFinite }),
            cueScores: Dictionary(series.formCueScores
                .filter { $0.score.isFinite }
                .map { ($0.cue.rawValue, $0.score) },
                uniquingKeysWith: { a, _ in a }),
            kneeCycle: robustCycle(.knee),
            hipCycle: nil,            // hip curve dropped (trunk-lean confound, no vertical reference)
            ankleCycle: robustCycle(.ankle),
            contactMs: avgGCT,        // ground contact: measured from vertical foot motion, plausibility-gated
            dutyFactor: nil,          // peak force + leg spring stay out: they need force-plate-grade
            legSpringHz: nil,         // timing the spring-mass model can't get from a phone clip
            peakForceBW: nil,
            overstrideDeg: series.shankAngleAtContactSignedDeg.isFinite
                ? series.shankAngleAtContactSignedDeg : nil
        )
    }

    private func scorecardSnapshotPNG(from processedURL: URL, series: MetricSeries) async -> Data? {
        await PeakStrideStill.image(from: processedURL, processor: processor, series: series)?
            .jpegData(compressionQuality: 0.82)
    }

    private func scorecardMetric(label: String, value: String, optimal: String, score: Int, neutral: Bool = false) -> StoredScorecardMetric {
        StoredScorecardMetric(label: label, value: value, optimal: optimal,
                              status: neutral ? FormStatus.neutral.rawValue : scoreStatus(score).rawValue)
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
        // Cadence is pace-dependent and NOT capped near 180: elites sustain
        // 185-200 spm at race pace (Daniels' treadmill data, Kipchoge ~190). A 190
        // ceiling wrongly flagged fast runners, so the good band is 165-200.
        if cadence >= 165 && cadence <= 200 { return 92 }
        let distance = cadence < 165 ? 165 - cadence : cadence - 200
        return max(40, Int((92 - distance * 1.6).rounded()))
    }

    private func groundContactScore(_ milliseconds: Double) -> Int {
        guard milliseconds > 0 else { return 0 }
        // Contact time is pace-dependent; easy-pace distance running commonly sits
        // up to ~320 ms. Only clearly longer is a real drag.
        if milliseconds <= 320 { return 90 }
        return max(40, Int((90 - (milliseconds - 320) * 0.25).rounded()))
    }

    // NOTE: the displayed knee value is the full-cycle MEAN interior angle (swing
    // flexion pulls it well below the stance value). A whole-cycle mean near 160°
    // is biomechanically unreachable; the population mean sits ~120-125°, so the
    // good window is 112-138° (research-reconstructed from published waveforms).
    private func kneeScore(_ angle: Double) -> Int {
        guard angle > 0 else { return 0 }
        if angle >= 112 && angle <= 138 { return 90 }
        let distance = angle < 112 ? 112 - angle : angle - 138
        return max(45, Int((90 - distance * 1.4).rounded()))
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
                    .font(AppTheme.bodySemibold(24))
                    .foregroundColor(AppTheme.primaryText)
                
                Text("Gaita reads your form straight from the video. Nothing to set up here.")
                    .font(AppTheme.body(13))
                    .foregroundColor(AppTheme.primaryText.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)

                // Premium
                if subscriptions.isPremium {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                        Text("Premium active")
                    }
                    .font(AppTheme.bodySemibold(15))
                    .foregroundColor(AppTheme.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    Button(action: {
                        showingSettings = false
                        showPaywall = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles")
                            Text("Get Premium")
                        }
                        .font(AppTheme.bodySemibold(16))
                        .foregroundColor(AppTheme.onAccentPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AppTheme.accentColor)
                        .cornerRadius(12)
                    }
                }

                #if DEBUG
                // Testing-only: skip the paywall. Persisted, survives relaunch,
                // compiled out of Release builds. Green when premium is on.
                Button(action: { subscriptions.debugUnlocked.toggle() }) {
                    HStack {
                        Image(systemName: subscriptions.isPremium ? "checkmark.seal.fill" : "lock.open")
                        Text(subscriptions.isPremium ? "Premium ON (testing) — tap to lock" : "Unlock premium (testing)")
                    }
                    .font(AppTheme.bodySemibold(15))
                    .foregroundColor(subscriptions.isPremium ? AppTheme.onAccentPrimary : AppTheme.primaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(subscriptions.isPremium ? AppTheme.accentColor : AppTheme.primaryText.opacity(0.08))
                    .cornerRadius(12)
                }

                Button(action: {
                    showingSettings = false
                    showLabelTool = true
                }) {
                    Text("Label clips (dev)")
                        .font(AppTheme.bodySemibold(16))
                        .foregroundColor(AppTheme.primaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AppTheme.primaryText.opacity(0.08))
                        .cornerRadius(12)
                }
                #endif

                Button(action: {
                    // A stray typed height must not persist: it skews every
                    // pixel→real-unit metric and can trap the Int() conversions.
                    userBodyHeightMeters = min(max(userBodyHeightMeters, 0.9), 2.4)
                    showingSettings = false
                }) {
                    Text("Done")
                        .font(AppTheme.bodySemibold(16))
                        .foregroundColor(AppTheme.primaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AppTheme.primaryText.opacity(0.08))
                        .cornerRadius(12)
                }
            }
            .padding(24)
            .background(AppTheme.bgColor)
            .cornerRadius(20)
            .padding(.horizontal, 40)
            .onAppear {
                // Initialize feet/inches pickers from stored meters value
                syncHeightPickersFromMeters()
            }
        }
    }

    /// Meters → whole feet/inches with one consistent rounding — mixing
    /// truncated feet with rounded inches showed 1.82 m as 5'0". Clamped so a
    /// stray typed value cannot trap Int() or escape the pickers' 3...7 ft range.
    private func syncHeightPickersFromMeters() {
        let clampedMeters = min(max(userBodyHeightMeters, 0.9), 2.4)
        let totalInches = Int((clampedMeters / 0.0254).rounded())
        heightFeet = min(max(totalInches / 12, 3), 7)
        heightInches = totalInches % 12
    }


    private var instructionsPopup: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()
                .onTapGesture { showingInstructions = false }

            VStack(spacing: 22) {
                HStack {
                    Text("HOW TO RECORD")
                        .font(AppTheme.head(15))
                        .foregroundColor(AppTheme.primaryText)
                    Spacer()
                    Button(action: { showingInstructions = false }) {
                        Image(systemName: "xmark")
                            .font(AppTheme.head(14))
                            .foregroundColor(AppTheme.primaryText.opacity(0.5))
                    }
                }

                // Side-on-treadmill schematic
                HStack(spacing: 16) {
                    VStack(spacing: 5) {
                        Image(systemName: "iphone")
                            .font(AppTheme.body(30))
                            .foregroundColor(AppTheme.accentColor)
                        Text("CAMERA")
                            .font(AppTheme.meta(8))
                            .foregroundColor(AppTheme.primaryText.opacity(0.4))
                    }
                    Image(systemName: "arrow.right")
                        .font(AppTheme.head(14))
                        .foregroundColor(AppTheme.primaryText.opacity(0.3))
                    VStack(spacing: 5) {
                        Image(systemName: "figure.run")
                            .font(AppTheme.body(42))
                            .foregroundColor(AppTheme.primaryText)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(AppTheme.primaryText.opacity(0.3))
                            .frame(width: 72, height: 3)
                        Text("TREADMILL")
                            .font(AppTheme.meta(8))
                            .foregroundColor(AppTheme.primaryText.opacity(0.4))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(RoundedRectangle(cornerRadius: 16).fill(AppTheme.primaryText.opacity(0.04)))

                // Steps
                VStack(alignment: .leading, spacing: 14) {
                    instructionLine(icon: "figure.stand", text: "Stand side on, full body in frame")
                    instructionLine(icon: "ruler", text: "Camera at hip height, about 3 m away")
                    instructionLine(icon: "clock", text: "Record 10–15 seconds of running")
                    instructionLine(icon: "speedometer", text: "Shoot in 60 fps (Slo Mo) for accurate Power")
                }

                // How it works
                Text("We track your joints frame-by-frame to measure your stride, posture, landing impact, and power.")
                    .font(AppTheme.body(12))
                    .foregroundColor(AppTheme.primaryText.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(width: UIScreen.main.bounds.width * 0.88)
            .background(RoundedRectangle(cornerRadius: 22).fill(AppTheme.cardBgAlt))
        }
    }

    private func instructionLine(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(AppTheme.bodySemibold(14))
                .foregroundColor(AppTheme.accentColor)
                .frame(width: 22)
            Text(text)
                .font(AppTheme.bodyMedium(13))
                .foregroundColor(AppTheme.primaryText.opacity(0.85))
            Spacer(minLength: 0)
        }
    }
    
    // MARK: - Video Loading

    /// File-based transfer from the photo picker. Loading the clip as Data
    /// spiked memory by the full video size (hundreds of MB for long clips).
    private struct PickedVideoFile: Transferable {
        let url: URL

        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(contentType: .movie) { file in
                SentTransferredFile(file.url)
            } importing: { received in
                let dest = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mov")
                try FileManager.default.copyItem(at: received.file, to: dest)
                return Self(url: dest)
            }
        }
    }

    private func loadVideo(from item: PhotosPickerItem) async {
        await MainActor.run {
            // Clear the picker selection now that we've captured the item, so
            // re-selecting the SAME clip later still fires onChange (#14).
            selectedItem = nil
            isPreparingVideo = true
        }
        do {
            if let picked = try await item.loadTransferable(type: PickedVideoFile.self) {
                await MainActor.run {
                    selectedVideoURL = picked.url
                }
                await runAnalysis(with: picked.url)
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
            // No separate results screen — the analysis lands back on the tab,
            // which now carries the form report + all the action buttons.
        }
    }

    private func resetProcessor() {
        selectedItem = nil
        selectedVideoURL = nil
        if let old = processor.processedVideoURL {
            try? FileManager.default.removeItem(at: old)
        }
        processor.releaseAnalysisBuffers()
        processor.processedVideoURL = nil
        processor.metricSeries = nil      // clear results so the card returns to Upload/Record
        processor.analysisMetrics = nil
        processor.error = nil
        processor.scanQualityWarning = nil
        processor.selectedSide = nil
        processor.progress = 0
        isPreparingVideo = false
    }

    private var loadingOverlay: some View {
        ZStack {
            // Adaptive scrim: near-black in dark, near-white in light, so the
            // ink/white progress text on top stays legible in both modes.
            Color(light: .white, dark: .black).opacity(0.92)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .stroke(AppTheme.primaryText.opacity(0.15), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: min(max(processor.progress, 0), 1))
                        .stroke(
                            AppTheme.accentColor,
                            style: StrokeStyle(lineWidth: 6, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Text("\(Int((processor.progress * 100).rounded()))%")
                        .font(AppTheme.displayTabular(18))
                        .foregroundColor(AppTheme.primaryText)
                }
                .frame(width: 88, height: 88)
                
                Text(loadingStatusMessage)
                    .font(AppTheme.bodyMedium(16))
                    .foregroundColor(AppTheme.primaryText)
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

// MARK: - Peak-stride still (shared)
// One still pipeline shared by the scorecard snapshot and the results-screen
// video poster, so every surface shows the same mid-stride frame instead of
// whatever happens to sit at t=0 (often an empty scene before the runner enters).
enum PeakStrideStill {
    /// Find the foot-FLAT contact frame near a detected strike: the frame where the
    /// foot is lowest (planted on the ground/belt) AND most directly under the hip —
    /// true mid-stance. This avoids the forward-reaching swing frame where the foot
    /// is still hovering before touchdown.
    static func frameIndex(around heelStrikeIndex: Int, processor: VideoProcessor) -> Int {
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

    /// Extract the peak-stride frame from the processed video as a still.
    static func image(from videoURL: URL, processor: VideoProcessor, series: MetricSeries) async -> UIImage? {
        // Refine the heel-strike index to the true foot-landing frame, matching the
        // manual Snapshot button (raw peaks can sit a few frames off contact).
        let baseIndex = series.heelStrikeFrameIndices.first ?? 0
        let frameIndex = Self.frameIndex(around: baseIndex, processor: processor)

        let asset = AVAsset(url: videoURL)
        // Pose frames exist only where detection succeeded, so index math drifts
        // whenever the runner enters late — the stored presentation time is exact.
        let timestamp: Double
        if let frameTime = processor.getPoseFrame(at: frameIndex)?.time {
            timestamp = frameTime
        } else {
            let totalFrames = max(series.rightFootHipDistanceSeries.count, series.leftFootHipDistanceSeries.count, 1)
            let assetDuration = (try? await asset.load(.duration))?.seconds ?? series.durationSeconds
            let duration = max(assetDuration, 0.1)
            let frameRate = Double(totalFrames) / duration
            timestamp = Double(frameIndex) / max(frameRate, 1)
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero   // exact frame
        generator.requestedTimeToleranceAfter = .zero

        do {
            let cgImage = try await generator.image(at: CMTime(seconds: timestamp, preferredTimescale: 600)).image
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }
}

// MARK: - Full Metrics video card

/// The processed skeleton clip, shown inside Full Metrics. Starts paused on the
/// peak-stride still (so it never opens on an empty pre-run frame); tap to play.
/// Falls back to the stored snapshot when the live video is gone (e.g. relaunch).
struct AnalyzeVideoCard: View {
    let videoURL: URL?
    let processor: VideoProcessor
    let series: MetricSeries?
    let fallbackSnapshot: UIImage?

    @State private var player: AVPlayer?
    @State private var poster: UIImage?
    @State private var posterDismissed = false

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
            }
            if let still = poster ?? fallbackSnapshot, !posterDismissed || player == nil {
                Image(uiImage: still)
                    .resizable()
                    .scaledToFit()
                if player != nil {
                    Image(systemName: "play.fill")
                        .font(AppTheme.head(18))
                        .foregroundColor(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous)
                .stroke(AppTheme.subtleBorder, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.cardCornerRadius, style: .continuous))
        .onTapGesture {
            guard player != nil else { return }
            posterDismissed = true
            player?.play()
        }
        .onAppear {
            if player == nil, let videoURL {
                player = AVPlayer(url: videoURL)
                if let series {
                    Task {
                        let still = await PeakStrideStill.image(from: videoURL, processor: processor, series: series)
                        await MainActor.run { poster = still }
                    }
                }
            }
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - Analyze math helpers

/// Peak/cadence math shared by the scorecard builder. Extracted from the old
/// full-screen results page (now removed) so the estimator stays identical.
enum AnalyzeMath {
    // Detect all local maxima (peaks) in a signal with sub-frame accuracy.
    // Returns fractional frame indices refined via parabolic interpolation.
    static func detectLocalMaxima(_ series: [Double], frameRate: Double) -> [Double] {
        // A degenerate analysis (no runner detected) produces empty series; the
        // scan range 1..<(count-1) traps below 3 elements.
        guard series.count >= 3 else { return [] }
        var intPeaks: [Int] = []
        let minSpacingFrames = max(1, Int(frameRate * 0.2)) // 0.2s minimum spacing to avoid noise

        for i in 1..<(series.count - 1) {
            if series[i].isNaN { continue }
            let isLocalMax = series[i] > series[i-1] &&
                            series[i] > series[i+1] &&
                            (i < 2 || series[i] > series[i-2]) &&
                            (i >= series.count - 2 || series[i] > series[i+2])
            if isLocalMax {
                if intPeaks.isEmpty || (i - intPeaks.last!) >= minSpacingFrames {
                    intPeaks.append(i)
                } else {
                    let lastPeakIndex = intPeaks.last!
                    if series[i] > series[lastPeakIndex] {
                        intPeaks[intPeaks.count - 1] = i
                    }
                }
            }
        }

        // Parabolic (quadratic) interpolation for sub-frame accuracy.
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
                let clampedOffset = max(-0.5, min(0.5, offset))
                refinedPeaks.append(Double(i) + clampedOffset)
            } else {
                refinedPeaks.append(Double(i))
            }
        }
        return refinedPeaks
    }

    // N peaks produce N-1 step intervals for one foot; x2 for both-feet SPM.
    static func calculateCadenceFromPeaks(_ peaks: [Double], frameRate: Double) -> Double {
        guard peaks.count >= 2, frameRate > 0 else { return 0 }
        let firstPeak = peaks.first!
        let lastPeak = peaks.last!
        let timeElapsed = (lastPeak - firstPeak) / frameRate
        guard timeElapsed > 0 else { return 0 }
        let intervals = Double(peaks.count - 1)
        let cadence = (intervals / timeElapsed) * 60.0 * 2.0
        return min(300, cadence)
    }

    /// Jitter-robust cadence via autocorrelation of the single-foot foot-hip
    /// distance. Peak-counting inflates on noisy footage — a wobble within a
    /// stride reads as an extra step (that is how a real clip produced an
    /// impossible 229 spm). Autocorrelation locks onto the fundamental stride
    /// PERIOD and ignores jitter and spurious wiggles. Returns 0 when there is no
    /// clear periodicity in the physiological band, so the caller can fall back.
    static func dominantCadence(_ series: [Double], frameRate: Double) -> Double {
        let x = series.filter { $0.isFinite }
        guard x.count >= 12, frameRate > 0 else { return 0 }
        let mean = x.reduce(0, +) / Double(x.count)
        let d = x.map { $0 - mean }
        let energy = d.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-9 else { return 0 }
        // The foot-hip distance cycles ONCE per stride of that foot. The lag (in
        // frames) for a total cadence C is fps·120/C. Search the physiological
        // band C ∈ [120, 230] spm; higher cadence = shorter period = smaller lag.
        let minLag = max(2, Int((frameRate * 120.0 / 230.0).rounded()))
        let maxLag = min(d.count - 1, Int((frameRate * 120.0 / 120.0).rounded()))
        guard maxLag > minLag + 1 else { return 0 }
        var corr = [Double](repeating: 0, count: maxLag + 1)
        var bestLag = minLag
        var bestCorr = -Double.greatestFiniteMagnitude
        var sum = 0.0
        for lag in minLag...maxLag {
            var s = 0.0
            for i in 0..<(d.count - lag) { s += d[i] * d[i + lag] }
            let c = s / energy
            corr[lag] = c
            sum += c
            if c > bestCorr { bestCorr = c; bestLag = lag }
        }
        // Real stride periodicity makes a CLEAR peak that stands above the flat
        // autocorrelation baseline; noise stays flat. Judge on that prominence,
        // not a high absolute value — an irregular but real stride can peak at
        // only ~0.16 yet be unmistakable (2x the band mean). Absolute floor guards
        // against a fully random signal.
        let bandMean = sum / Double(maxLag - minLag + 1)
        guard bestCorr > 0.12, bestCorr > bandMean + 0.05 else { return 0 }
        // Sub-lag parabolic refinement around the peak for a smoother estimate.
        var refined = Double(bestLag)
        if bestLag > minLag, bestLag < maxLag {
            let denom = corr[bestLag - 1] - 2 * corr[bestLag] + corr[bestLag + 1]
            if abs(denom) > 1e-12 {
                refined += max(-0.5, min(0.5, 0.5 * (corr[bestLag - 1] - corr[bestLag + 1]) / denom))
            }
        }
        return frameRate / refined * 120.0
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
                    .font(AppTheme.body(15))
                    .foregroundColor(AppTheme.primaryText.opacity(0.9))
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
            .font(AppTheme.bodySemibold(10))
            .foregroundColor(.black)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color.opacity(0.9))
            .clipShape(Capsule())
    }
}

// MARK: - Ground contact card (per step)

/// Per-step ground contact time, the "science of speed" read: how long each
/// foot spends on the ground, drawn as one bar per step against honest
/// reference lines. Data comes straight from the detected gait cycles
/// (heel strike to toe off), so it renders only when steps were detected.
private struct GroundContactCard: View {
    let gait: GaitCycleSeries?
    let uncertaintyMs: Double
    @State private var showGuide = false

    private struct ContactStep {
        let time: Double
        let ms: Double
        let isLeft: Bool
    }

    private var steps: [ContactStep] {
        guard let gait else { return [] }
        var out: [ContactStep] = []
        // Use the vertical-motion stance time (contactMs), not toeOffTime-startTime:
        // the cycle is anchored to the forward-reach peak, which precedes touchdown
        // and inflates that difference (the reason this card read ~326 vs the true
        // ~228). contactMs is plausibility-gated already; skip NaN/out-of-range.
        for c in gait.leftCycles where c.contactMs.isFinite {
            if (120...400).contains(c.contactMs) { out.append(ContactStep(time: c.startTime, ms: c.contactMs, isLeft: true)) }
        }
        for c in gait.rightCycles where c.contactMs.isFinite {
            if (120...350).contains(c.contactMs) { out.append(ContactStep(time: c.startTime, ms: c.contactMs, isLeft: false)) }
        }
        return out.sorted { $0.time < $1.time }
    }

    var body: some View {
        let steps = self.steps
        if steps.count >= 2 {
            let values = steps.map(\.ms)
            let avg = values.reduce(0, +) / Double(values.count)
            let leftVals = steps.filter(\.isLeft).map(\.ms)
            let rightVals = steps.filter { !$0.isLeft }.map(\.ms)
            let hasBoth = !leftVals.isEmpty && !rightVals.isEmpty

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("Ground Contact")
                        .font(AppTheme.bodySemibold(16))
                        .foregroundColor(AppTheme.primaryText.opacity(0.9))
                    Button(action: { showGuide = true }) {
                        Image(systemName: "info.circle")
                            .font(AppTheme.body(14))
                            .foregroundColor(AppTheme.primaryText.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    if hasBoth {
                        HStack(spacing: 10) {
                            legendDot(Color(hex: "#00CED1"), "L")
                            legendDot(Color(hex: "#FF8C00"), "R")
                        }
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(avg.rounded()))")
                        .font(AppTheme.display(30))
                        .foregroundColor(AppTheme.primaryText)
                    Text("MS AVG")
                        .font(AppTheme.meta(10))
                        .foregroundColor(AppTheme.primaryText.opacity(0.4))
                    Spacer()
                    if hasBoth {
                        let avgL = leftVals.reduce(0, +) / Double(leftVals.count)
                        let avgR = rightVals.reduce(0, +) / Double(rightVals.count)
                        Text("L \(Int(avgL.rounded()))  R \(Int(avgR.rounded()))")
                            .font(AppTheme.meta(12))
                            .foregroundColor(AppTheme.primaryText.opacity(0.55))
                    }
                }

                contactChart(steps)
                    .frame(height: 190)

                Text(uncertaintyMs >= 20
                     ? "ONE BAR PER STEP. TIMING GOOD TO ABOUT ±\(Int(uncertaintyMs.rounded())) MS AT THIS FRAME RATE."
                     : "ONE BAR PER STEP.")
                    .font(AppTheme.meta(8))
                    .tracking(0.5)
                    .foregroundColor(AppTheme.primaryText.opacity(0.3))
            }
            .padding(.horizontal, 20)
            .sheet(isPresented: $showGuide) {
                MetricGuideSheet(entry: MetricGuide.groundContact)
            }
        }
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(AppTheme.meta(9))
                .foregroundColor(AppTheme.primaryText.opacity(0.45))
        }
    }

    private func contactChart(_ steps: [ContactStep]) -> some View {
        let maxVal = max(320, (steps.map(\.ms).max() ?? 0) + 30)
        let guides: [(value: Double, label: String)] = [
            (100, "SPRINT"), (200, "ELITE"), (250, "GOOD")
        ].filter { $0.0 < maxVal - 20 }

        return GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                ForEach(guides, id: \.label) { g in
                    let y = h * (1 - CGFloat(g.value / maxVal))
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: y))
                        p.addLine(to: CGPoint(x: w, y: y))
                    }
                    .stroke(AppTheme.primaryText.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
                    Text("\(g.label) \(Int(g.value))")
                        .font(AppTheme.meta(8))
                        .foregroundColor(AppTheme.primaryText.opacity(0.3))
                        .position(x: w - 34, y: max(8, y - 8))
                }
                ForEach(steps.indices, id: \.self) { i in
                    let s = steps[i]
                    let slot = w / CGFloat(steps.count)
                    let barW = min(16, slot * 0.55)
                    let barH = max(2, h * CGFloat(s.ms / maxVal))
                    RoundedRectangle(cornerRadius: 3)
                        .fill((s.isLeft ? Color(hex: "#00CED1") : Color(hex: "#FF8C00")).opacity(0.9))
                        .frame(width: barW, height: barH)
                        .position(x: slot * (CGFloat(i) + 0.5), y: h - barH / 2)
                }
            }
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
                    .font(AppTheme.bodySemibold(16))
                    .foregroundColor(AppTheme.primaryText.opacity(0.9))
                
                if isEstimate {
                    GraphBadge(text: "3D Estimate", color: .yellow)
                }
                
                if isAngleUnsafe {
                    GraphBadge(text: "Angle-unsafe", color: .orange)
                }
                
                if !info.isEmpty {
                    Button(action: { showInfo = true }) {
                        Image(systemName: "info.circle").accessibilityLabel("About this metric")
                            .font(AppTheme.body(14))
                            .foregroundColor(AppTheme.primaryText.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
            }
            
            if series.isEmpty {
                Text("No data")
                    .font(AppTheme.body(14))
                    .foregroundColor(AppTheme.primaryText.opacity(0.45))
                    .frame(height: 360)
            } else {
                // Graph content - no cursor, no scrolling
                SparklineView(
                    series: series,
                    color: AppTheme.accentColor,
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
                    .stroke(AppTheme.primaryText.opacity(0.08), lineWidth: 1)
                    
                    // Axes
                    Path { path in
                        path.move(to: CGPoint(x: plotInset.leading, y: plotInset.top))
                        path.addLine(to: CGPoint(x: plotInset.leading, y: plotInset.top + plotHeight))
                        path.addLine(to: CGPoint(x: plotInset.leading + plotWidth, y: plotInset.top + plotHeight))
                    }
                    .stroke(AppTheme.primaryText.opacity(0.25), lineWidth: 1)
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
                    .stroke(AppTheme.primaryText, lineWidth: 2.5)
                    .opacity(0.9)
                    .allowsHitTesting(false)  // Don't block scrolling
                }
                
                if attachAxes {
                    // Y-axis labels (min/mid/max) - positioned on left side
                    VStack(alignment: .leading, spacing: 0) {
                        Text(formatValue(maxVal))
                            .font(AppTheme.bodyMedium(12))
                            .foregroundColor(AppTheme.primaryText.opacity(0.8))
                        Spacer()
                        Text(formatValue((maxVal + minVal) / 2))
                            .font(AppTheme.body(11))
                            .foregroundColor(AppTheme.primaryText.opacity(0.6))
                        Spacer()
                        Text(formatValue(minVal))
                            .font(AppTheme.bodyMedium(12))
                            .foregroundColor(AppTheme.primaryText.opacity(0.8))
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
                                .font(AppTheme.bodyMedium(12))
                                .foregroundColor(AppTheme.primaryText.opacity(0.8))
                            Spacer()
                            Text(timeLabel(midSeconds))
                                .font(AppTheme.body(11))
                                .foregroundColor(AppTheme.primaryText.opacity(0.6))
                            Spacer()
                            Text(timeLabel(totalSeconds))
                                .font(AppTheme.bodyMedium(12))
                                .foregroundColor(AppTheme.primaryText.opacity(0.8))
                        }
                        .padding(.leading, plotInset.leading)
                        .padding(.trailing, plotInset.trailing)
                        .padding(.bottom, 6)
                        
                        // X-axis title
                        Text("Time (s)")
                            .font(AppTheme.bodyMedium(11))
                            .foregroundColor(AppTheme.primaryText.opacity(0.5))
                            .padding(.bottom, 4)
                    }
                    
                    // Y-axis title - rotated on the left
                    VStack {
                        Text(unit)
                            .font(AppTheme.bodyMedium(11))
                            .foregroundColor(AppTheme.primaryText.opacity(0.5))
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

// MARK: - Gauge Dial (compact half-arc used on suggestion cards)

struct GaugeDial: View {
    let score: Int
    let color: Color

    private var normalizedScore: Double { min(max(Double(score), 0), 100) / 100.0 }
    private var filledEndAngle: Double { 180 + normalizedScore * 180 }

    var body: some View {
        ZStack {
            GaugeArcShape(startAngle: 180, endAngle: 360)
                .stroke(AppTheme.primaryText.opacity(0.15), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: 56, height: 28)
            if filledEndAngle > 180 {
                GaugeArcShape(startAngle: 180, endAngle: filledEndAngle)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [
                                Color(hex: "#FF3B30"), Color(hex: "#FF9500"),
                                Color(hex: "#FFD700"), Color(hex: "#34C759")
                            ]),
                            center: .bottom,
                            startAngle: .degrees(180),
                            endAngle: .degrees(360)
                        ),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .frame(width: 56, height: 28)
            }
            Text("\(score)")
                .font(AppTheme.head(15))
                // The chip is a fixed dark scrim, so its text is fixed white —
                // primaryText flipped to ink in light mode and went muddy.
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.5), radius: 1, x: 0, y: 1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.4))
                .cornerRadius(4)
                .offset(y: 10)
        }
        .frame(width: 64, height: 44)
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
                        AppTheme.primaryText.opacity(0.12),
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
                            .font(AppTheme.display(36))
                            .foregroundColor(AppTheme.primaryText)
                    } else {
                        Text("--")
                            .font(AppTheme.display(36))
                            .foregroundColor(AppTheme.primaryText.opacity(0.35))
                    }
                }
                .offset(y: 20)
            }
            .frame(width: 160, height: 100)

            Text(scoreLabel)
                .font(AppTheme.bodyMedium(13))
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
        case 70..<85: return Color(hex: "#FFD23F")
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
                    .stroke(AppTheme.primaryText.opacity(0.12), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .frame(width: 160, height: 80)
                
                if score != nil && filledEndAngle > 180 {
                    GaugeArcShape(startAngle: 180, endAngle: filledEndAngle)
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [
                                    Color(hex: "#FF3B30"),
                                    Color(hex: "#FF9500"),
                                    Color(hex: "#FFD23F"),
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
                            .font(AppTheme.display(36))
                            .foregroundColor(AppTheme.primaryText)
                    } else {
                        Text("--")
                            .font(AppTheme.display(36))
                            .foregroundColor(AppTheme.primaryText.opacity(0.35))
                    }
                }
                .offset(y: 20)
            }
            .frame(width: 160, height: 100)
            
            Text(scoreLabel)
                .font(AppTheme.bodyMedium(13))
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
                        .font(AppTheme.bodySemibold(15))
                        .foregroundColor(AppTheme.primaryText)
                }
                Text(tip)
                    .font(AppTheme.body(13))
                    .foregroundColor(AppTheme.primaryText.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            GaugeDial(score: score, color: color)
                .padding(.top, 2)
        }
        .padding(12)
        .background(AppTheme.primaryText.opacity(0.08))
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
        case 65..<80: return Color(hex: "#FFD23F")
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
                        .font(AppTheme.bodySemibold(15))
                        .foregroundColor(AppTheme.primaryText)
                    Text(cls.label)
                        .font(AppTheme.bodyMedium(12))
                        .foregroundColor(color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color.opacity(0.15))
                        .cornerRadius(4)
                    if let d = detail {
                        Text(d)
                            .font(AppTheme.meta(12))
                            .foregroundColor(AppTheme.primaryText.opacity(0.6))
                    }
                }
                Text(cls.tip)
                    .font(AppTheme.body(13))
                    .foregroundColor(AppTheme.primaryText.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            GaugeDial(score: cls.score, color: color)
                .padding(.top, 2)
        }
        .padding(12)
        .background(AppTheme.primaryText.opacity(0.08))
        .cornerRadius(10)
    }
}

// MARK: - Foot Placement Card (label only, no score dial)

struct FootPlacementCard: View {
    let label: String
    let tip: String

    private var accentColor: Color {
        label == "Unknown" ? .gray : AppTheme.accentColor.opacity(0.75)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(accentColor)
                    .frame(width: 10, height: 10)
                Text("Foot Placement")
                    .font(AppTheme.bodySemibold(15))
                    .foregroundColor(AppTheme.primaryText)
                Spacer(minLength: 0)
                Text(label)
                    .font(AppTheme.bodySemibold(13))
                    .foregroundColor(accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(accentColor.opacity(0.18))
                    .cornerRadius(8)
            }
            Text(tip)
                .font(AppTheme.body(13))
                .foregroundColor(AppTheme.primaryText.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(AppTheme.primaryText.opacity(0.08))
        .cornerRadius(10)
    }
}

// MARK: - Snapshot View

/// Drives snapshot sheets with the image itself. The old isPresented flag plus
/// a separate optional image let the sheet present before the image state
/// landed, leaving a permanently blank white sheet (seen on iOS 26).
struct SnapshotSheetItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

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
                            .font(AppTheme.bodyMedium(16))
                            .foregroundColor(AppTheme.primaryText.opacity(0.8))
                            .padding(.horizontal, 20)
                        
                        Text("This snapshot shows your running form at the moment of heel strike (ground contact).")
                            .font(AppTheme.body(14))
                            .foregroundColor(AppTheme.primaryText.opacity(0.6))
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
                        Image(systemName: "xmark").accessibilityLabel("Close")
                            .foregroundColor(AppTheme.primaryText)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if let imageData = image.pngData() {
                        ShareLink(item: imageData, preview: SharePreview("Skeleton Snapshot")) {
                            Image(systemName: "square.and.arrow.up").accessibilityLabel("Share")
                                .foregroundColor(AppTheme.primaryText)
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

// MARK: - Analysis history sheet (view + delete past analyses)

/// Every stored analysis, newest first. Swipe to delete one; the newest
/// remaining analysis becomes the dashboard's current scores.
struct AnalysisHistorySheet: View {
    @ObservedObject private var history = AnalysisHistoryStore.shared
    @Environment(\.dismiss) private var dismiss

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d, yyyy · h:mm a"; return f
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.bgColor.ignoresSafeArea()
                if history.records.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(AppTheme.body(30))
                            .foregroundColor(AppTheme.primaryText.opacity(0.3))
                        Text("No analyses yet")
                            .font(AppTheme.bodyMedium(15))
                            .foregroundColor(AppTheme.primaryText.opacity(0.6))
                    }
                } else {
                    List {
                        ForEach(history.records) { record in
                            row(record)
                                .listRowBackground(AppTheme.primaryText.opacity(0.04))
                                .listRowSeparatorTint(AppTheme.primaryText.opacity(0.08))
                        }
                        .onDelete { offsets in
                            for i in offsets { history.delete(id: history.records[i].id) }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(AppTheme.accentColor)
                }
            }
        }
        .presentationBackground(AppTheme.bgColor)
    }

    private func row(_ record: AnalysisRecord) -> some View {
        HStack(spacing: 12) {
            Group {
                // 46pt cell at up to 3x → 138px is plenty; decode a thumbnail
                // rather than the full snapshot to avoid scroll jank + memory.
                if let png = record.form?.snapshotPNG, let img = downsampledThumbnail(png, maxPixel: 138) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(AppTheme.primaryText.opacity(0.06))
                        .overlay(Image(systemName: "figure.run").foregroundColor(AppTheme.primaryText.opacity(0.3)))
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(Self.dateFormatter.string(from: record.date))
                    .font(AppTheme.bodyMedium(13))
                    .foregroundColor(AppTheme.primaryText)
                HStack(spacing: 10) {
                    scoreChip("DRIVE", record.power)
                    scoreChip("IMPACT", record.impact)
                    scoreChip("SMOOTH", record.efficiency)
                }
            }
            Spacer()
            Text(record.overall.map(String.init) ?? "—")
                .font(AppTheme.display(20))
                .foregroundColor(AppTheme.accentColor)
        }
        .padding(.vertical, 6)
    }

    private func scoreChip(_ label: String, _ v: Int?) -> some View {
        Text("\(label) \(v.map(String.init) ?? "--")")
            .font(AppTheme.meta(9))
            .foregroundColor(AppTheme.primaryText.opacity(0.5))
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

