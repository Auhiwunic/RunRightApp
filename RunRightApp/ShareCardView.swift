//
//  ShareCardView.swift
//  RunRightApp
//
//  Shareable run scorecard — black, data-first sheet styled like a racing-telemetry
//  dash: monospaced/digital font and bordered field boxes. Merges the color-coded
//  foot-contact skeleton with the gait/shoe-wear analysis, headline scores, and a
//  packed metric table. Exports a high-res image via ImageRenderer + share sheet.
//

import SwiftUI
import FirebaseAuth

// MARK: - Fonts (telemetry / digital — monospaced)

private extension Font {
    // Share card uses the app faces (Archivo/Switzer). Numbers use the tabular
    // Archivo cut so the packed metric table stays column-aligned in the export.
    static func arial(_ size: CGFloat) -> Font { AppTheme.bodyMedium(size) }
    static func arialBold(_ size: CGFloat) -> Font { AppTheme.displayTabular(size) }
}

// MARK: - Telemetry field box

private extension View {
    /// Bordered, sharp-cornered field cell like a sim-racing dash readout.
    func telemetryBox() -> some View {
        self
            .background(Color.white.opacity(0.04))
            .overlay(Rectangle().stroke(Color.white.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Status / color coding

enum FormStatus { case good, warn, bad, neutral
    var color: Color {
        switch self {
        case .good: return Color(red: 0.18, green: 0.80, blue: 0.44)   // green
        case .warn: return Color(red: 1.00, green: 0.62, blue: 0.04)   // orange
        case .bad:  return Color(red: 1.00, green: 0.23, blue: 0.19)   // red
        case .neutral: return Color(red: 0.62, green: 0.64, blue: 0.68) // muted — an observation, not a grade
        }
    }
}

// MARK: - Data

struct MetricStat: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let optimal: String
    let status: FormStatus
}

struct ScorecardData {
    var name: String
    var distance: String
    var time: String
    var pace: String

    var overall: Int
    var grade: String
    var power: Int
    var impact: Int
    var efficiency: Int
    var cadence: Int

    var metrics: [MetricStat]

    var gaitType: String
    var strikePattern: String

    /// Real frame extracted from the processed analysis video.
    var snapshotImage: UIImage?
    /// Real shoe-scan photo from the gait analysis.
    var gaitImage: UIImage?
    /// Latest AI wear analysis for left/right shoe scans.
    var leftWearZones: WearZoneData?
    var rightWearZones: WearZoneData?

    /// Full-video time-series for the sparkline graphs.
    var bounce: [Double] = []
    var gct: [Double] = []
    var cadenceTrend: [Double] = []
}

struct StoredScorecardMetric: Codable {
    let label: String
    let value: String
    let optimal: String
    let status: String

    var metricStat: MetricStat {
        MetricStat(label: label, value: value, optimal: optimal, status: FormStatus(rawValue: status) ?? .warn)
    }
}

extension FormStatus: RawRepresentable, Codable {
    typealias RawValue = String

    init?(rawValue: String) {
        switch rawValue {
        case "good": self = .good
        case "warn": self = .warn
        case "bad": self = .bad
        case "neutral": self = .neutral
        default: return nil
        }
    }

    var rawValue: String {
        switch self {
        case .good: return "good"
        case .warn: return "warn"
        case .bad: return "bad"
        case .neutral: return "neutral"
        }
    }
}

struct StoredScorecardForm: Codable, Identifiable {
    // Timestamp doubles as identity — each analysis is stamped at creation, so
    // collisions are effectively impossible and no schema/migration is needed.
    var id: Date { date }
    let date: Date
    let overall: Int
    let power: Int
    let impact: Int
    let efficiency: Int
    let cadence: Int
    let metrics: [StoredScorecardMetric]
    let snapshotPNG: Data?
    var bounce: [Double]? = nil
    var gct: [Double]? = nil
    var cadenceTrend: [Double]? = nil
    var cueScores: [String: Double]? = nil   // FormCue.rawValue → 0..100, for the Coach tab
    // Measured joint-flexion curves resampled to 11 deciles of the gait cycle
    // (0=foot strike … 100=next strike), for the your-vs-optimal overlay.
    var kneeCycle: [Double]? = nil
    var hipCycle: [Double]? = nil
    var ankleCycle: [Double]? = nil
    // Contact-phase scalars for the "you vs optimal" comparison tracks. Force is
    // a modeled spring-mass magnitude (not a measured waveform); overstride is a
    // direct sagittal geometry measurement.
    var contactMs: Double? = nil
    var dutyFactor: Double? = nil
    var legSpringHz: Double? = nil
    var peakForceBW: Double? = nil
    var overstrideDeg: Double? = nil
}

final class ScorecardDataStore {
    static let shared = ScorecardDataStore()
    private let key = "scorecard.latestForm.v1"
    private let gaitKey = "scorecard.gaitImage.v1"
    private let gaitTypeKey = "scorecard.gaitType.v1"
    private let strikeKey = "scorecard.gaitStrike.v1"
    private let leftWearZonesKey = "scorecard.leftWearZones.v1"
    private let rightWearZonesKey = "scorecard.rightWearZones.v1"
    private let wearShoeKey = "scorecard.wearShoe.v1"

    private init() {}

    func save(_ record: StoredScorecardForm) {
        do {
            let data = try JSONEncoder().encode(record)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            // A silent failure here leaves stale data on every downstream surface.
            print("[Scorecard] encode failed, keeping previous form: \(error)")
            assertionFailure("Scorecard encode failed: \(error)")
        }
    }

    func load() -> StoredScorecardForm? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(StoredScorecardForm.self, from: data)
    }

    /// Remove only the current form (leaves gait/wear data). Used when the last
    /// analysis is deleted from history so downstream surfaces stop showing it.
    func clearForm() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Persist the latest scanned shoe-sole image (+ optional analysis) so the
    /// scorecard's gait panel shows it locally, independent of the cloud backend.
    func saveGait(image: Data?, gaitType: String?, strikePattern: String?) {
        if let image { UserDefaults.standard.set(image, forKey: gaitKey) }
        if let gaitType { UserDefaults.standard.set(gaitType, forKey: gaitTypeKey) }
        if let strikePattern { UserDefaults.standard.set(strikePattern, forKey: strikeKey) }
    }

    func loadGaitImage() -> Data? { UserDefaults.standard.data(forKey: gaitKey) }
    func loadGaitType() -> String? { UserDefaults.standard.string(forKey: gaitTypeKey) }
    func loadGaitStrike() -> String? { UserDefaults.standard.string(forKey: strikeKey) }

    /// Persist the latest AI wear-zone grid for each side so the scorecard can
    /// render the same heatmap output shown in the Scan tab.
    func saveWearZones(side: String, zones: WearZoneData?) {
        guard let zones,
              let data = try? JSONEncoder().encode(zones)
        else { return }

        let key = side.lowercased() == "left" ? leftWearZonesKey : rightWearZonesKey
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Wear zones describe one physical pair. When a different shoe is scanned,
    /// drop the other side's stored zones so insights never fuse two shoes.
    func resetWearZonesIfShoeChanged(to shoe: String) {
        let previous = UserDefaults.standard.string(forKey: wearShoeKey)
        guard previous != shoe else { return }
        UserDefaults.standard.removeObject(forKey: leftWearZonesKey)
        UserDefaults.standard.removeObject(forKey: rightWearZonesKey)
        UserDefaults.standard.set(shoe, forKey: wearShoeKey)
    }

    func loadWearZones(side: String) -> WearZoneData? {
        let key = side.lowercased() == "left" ? leftWearZonesKey : rightWearZonesKey
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WearZoneData.self, from: data)
    }

    /// The shoe the locally stored wear zones belong to.
    func loadWearShoe() -> String? { UserDefaults.standard.string(forKey: wearShoeKey) }

    func clear() {
        for k in [key, gaitKey, gaitTypeKey, strikeKey, leftWearZonesKey, rightWearZonesKey, wearShoeKey] {
            UserDefaults.standard.removeObject(forKey: k)
        }
    }
}

// MARK: - Share card (telemetry data sheet)

struct ShareCardView: View {
    var data: ScorecardData
    private let bg = Color(hex: "#1A1A1C")
    private let card = Color(hex: "#2A2A2E")
    private let cardSoft = Color(hex: "#242428")
    private let accent = Color(hex: "#00CED1")
    private let heroHeight: CGFloat = 360   // shared height of snapshot + score column

    var body: some View {
        VStack(spacing: 12) {

            // ── Title ──
            HStack {
                Text("SCORECARD")
                    .font(AppTheme.headBold(22))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)

            // ── Top band: real snapshot left, score stack right ──
            // Photo + score column share the same height (heroHeight) so their
            // bottoms line up, and the HStack padding gives both equal margins.
            HStack(alignment: .top, spacing: 14) {
                Group {
                    if let img = data.snapshotImage {
                        // Frame matches the photo's real aspect ratio → fills exactly
                        // (rounded corners, nothing cropped — full head-to-foot frame).
                        let ar = min(0.82, max(0.45, img.size.width / max(img.size.height, 1)))
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: heroHeight * ar, height: heroHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    } else {
                        cardSoft
                            .frame(width: heroHeight * 0.56, height: heroHeight)
                            .overlay(placeholder("No snapshot"))
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }

                // Score inline with the photo's top, dials clustered tightly at the
                // bottom (SMOOTH's bottom lines up with the bottom of the photo).
                VStack(alignment: .trailing, spacing: 0) {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(data.overall)")
                            .font(AppTheme.display(56))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(
                                LinearGradient(colors: [.white, accent], startPoint: .top, endPoint: .bottom)
                            )
                        Rectangle()
                            .fill(accent)
                            .frame(width: 46, height: 3)
                            .cornerRadius(1.5)
                        Text("OVERALL")
                            .font(AppTheme.meta(10))
                            .foregroundColor(.white)
                    }

                    Spacer(minLength: 28)   // gap: score sits apart from the dial cluster

                    VStack(alignment: .trailing, spacing: 14) {   // dials grouped tightly
                        dial("DRIVE", data.power, Color(hex: "#00CED1"))
                        dial("IMPACT", data.impact, Color(hex: "#FF8C00"))
                        dial("SMOOTH", data.efficiency, Color(hex: "#FFD23F"))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: heroHeight, maxHeight: heroHeight, alignment: .topTrailing)
            }
            .padding(.horizontal, 22)   // equal left (photo) / right (dials) margins

            // ── FOOTER: full-video graphs (left) + wear heatmap (right) + metrics ──
            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !data.bounce.isEmpty {
                            graphRow("BOUNCE", data.bounce, Color(hex: "#00CED1"))
                        }
                        if !data.gct.isEmpty {
                            graphRow("GROUND CONTACT", data.gct, Color(hex: "#00FF7F"))
                        }
                        if !data.cadenceTrend.isEmpty {
                            graphRow("CADENCE", data.cadenceTrend, Color(hex: "#FF3B3B"))
                        }
                    }
                    .frame(maxWidth: .infinity)

                    if data.leftWearZones != nil || data.rightWearZones != nil {
                        VStack(spacing: 4) {
                            heatmapPanel
                            if !data.gaitType.isEmpty {
                                Text(data.gaitType)
                                    .font(AppTheme.meta(9))
                                    .foregroundColor(accent)
                            }
                        }
                    }
                }

                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

                // Equal margins between each stat and on the left/right edges
                HStack(spacing: 0) {
                    ForEach(Array(data.metrics.prefix(5))) { m in
                        Spacer(minLength: 0)
                        inlineStat(m.label, m.value, m.status.color)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(18)
        }
        // Glassmorphic: semi-transparent dark over a blurred shot of the run
        .background(cardGlassBackground)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(
                    LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.05)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.1), radius: 24, x: 0, y: 1)
        .padding(16)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var cardGlassBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)        // frosted glass — blurs the app behind
            Color.black.opacity(0.58)                   // smoked-black tint (still see-through)
            LinearGradient(colors: [Color.white.opacity(0.05), .clear],
                           startPoint: .topLeading, endPoint: .bottom)  // sheen
        }
        .environment(\.colorScheme, .dark)
    }

    private func heroStat(_ value: String) -> some View {
        Text(value)
            .font(AppTheme.displayTabular(15))
            .foregroundColor(.white)
    }

    private func inlineStat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .center, spacing: 4) {
            Text(value)
                .font(AppTheme.displayTabular(21))
                .foregroundColor(color)
                .lineLimit(1).minimumScaleFactor(0.55)
            Text(label)
                .font(AppTheme.meta(11))
                .foregroundColor(.white)
        }
    }

    @ViewBuilder
    private func dashCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(14)
            .background(card)
            .cornerRadius(20)
    }

    private func statChip(_ label: String, _ value: String, color: Color = .white, big: Bool = false) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(AppTheme.displayTabular(big ? 30 : 24))
                .foregroundColor(color)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(label)
                .font(AppTheme.meta(9))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(cardSoft)
        .cornerRadius(16)
    }

    private func sectionLabel(_ t: String) -> some View {
        Text(t)
            .font(AppTheme.meta(12))
            .foregroundColor(.white)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(AppTheme.meta(12))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scoreColor(_ s: Int) -> Color {
        s >= 80 ? FormStatus.good.color : (s >= 60 ? FormStatus.warn.color : FormStatus.bad.color)
    }

    private func dial(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 6) {
            RingMeter(value: value, color: color, lineWidth: 6, fontSize: 16)
                .frame(width: 54, height: 54)
            Text(label)
                .font(AppTheme.meta(9))
                .foregroundColor(.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func graphRow(_ title: String, _ values: [Double], _ color: Color,
                          _ values2: [Double] = [], _ color2: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(AppTheme.meta(9))
                .foregroundColor(.white)
            Sparkline(values: values, color: color, values2: values2, color2: color2)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
        }
    }

    /// The left/right shoe wear heatmaps for the scorecard's gait panel.
    private var heatmapPanel: some View {
        HStack(spacing: 6) {
            FootHeatmapView(isLeft: true, wearZones: data.leftWearZones,
                            labelDesign: .default, showLabel: false, cellSize: 3, cellSpacing: 0.7)
            FootHeatmapView(isLeft: false, wearZones: data.rightWearZones,
                            labelDesign: .default, showLabel: false, cellSize: 3, cellSpacing: 0.7)
        }
    }
}

private struct RingMeter: View {
    let value: Int
    let color: Color
    var lineWidth: CGFloat = 6
    var fontSize: CGFloat = 17
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, value))) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(value)")
                .font(AppTheme.displayTabular(fontSize))
                .foregroundColor(.white)
        }
    }
}

/// Minimal sparkline — one or two lines over the full clip, no axes or marks.
private struct Sparkline: View {
    let values: [Double]
    let color: Color
    var values2: [Double] = []
    var color2: Color = .white
    var body: some View {
        GeometryReader { geo in
            let all = values + values2
            let lo = all.min() ?? 0
            let hi = all.max() ?? 1
            ZStack {
                area(values, lo, hi, geo.size)
                    .fill(LinearGradient(colors: [color.opacity(0.4), color.opacity(0.0)],
                                         startPoint: .top, endPoint: .bottom))
                path(values, lo, hi, geo.size)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                if !values2.isEmpty {
                    path(values2, lo, hi, geo.size)
                        .stroke(color2, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
    private func point(_ i: Int, _ v: Double, _ lo: Double, _ hi: Double, _ size: CGSize, _ n: Int) -> CGPoint {
        let range = max(hi - lo, 0.0001)
        return CGPoint(x: size.width * CGFloat(i) / CGFloat(max(1, n - 1)),
                       y: size.height * (1 - CGFloat((v - lo) / range)))
    }
    private func path(_ vals: [Double], _ lo: Double, _ hi: Double, _ size: CGSize) -> Path {
        Path { p in
            guard vals.count > 1 else { return }
            for (i, v) in vals.enumerated() {
                let pt = point(i, v, lo, hi, size, vals.count)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }
    private func area(_ vals: [Double], _ lo: Double, _ hi: Double, _ size: CGSize) -> Path {
        Path { p in
            guard vals.count > 1 else { return }
            p.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in vals.enumerated() {
                p.addLine(to: point(i, v, lo, hi, size, vals.count))
            }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.closeSubpath()
        }
    }
}

/// Battery meter — fills bottom-up to `value`, with a terminal nub.
// MARK: - Share screen (export + share sheet)

struct ScorecardShareScreen: View {
    var onClose: (() -> Void)? = nil
    @State private var shareItem: ExportFile?
    @State private var data: ScorecardData?
    @State private var isLoading = true
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            if let data {
                ShareCardView(data: data)
            } else if isLoading {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("Building scorecard…")
                        .font(.arial(14)).foregroundColor(.white.opacity(0.7))
                }
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        // Close + Share: the screen previously rendered the card with no way to
        // share it (exportAndShare was never wired up) and no close control.
        .overlay(alignment: .topLeading) {
            Button(action: { onClose?() ?? dismiss() }) {
                Image(systemName: "xmark").accessibilityLabel("Close")
                    .font(AppTheme.bodySemibold(15))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
            .buttonStyle(.plain)
            .padding(14)
        }
        .overlay(alignment: .bottom) {
            if data != nil {
                Button(action: exportAndShare) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share")
                    }
                    .font(AppTheme.bodySemibold(15))
                    .foregroundColor(.black)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 18)
            }
        }
        .sheet(item: $shareItem) { file in
            ShareSheet(items: [file.url])
        }
        .task { await loadRealScorecard() }
        .presentationBackground(.clear)
    }

    @MainActor private func exportAndShare() {
        guard let data else { return }
        // Render over an OPAQUE background — the card's own glow background is
        // translucent, so without this the exported PNG carried alpha and looked
        // washed out / unreadable when shared onto a light surface.
        let renderer = ImageRenderer(content:
            ShareCardView(data: data)
                .frame(width: 400, height: 780)
                .background(AppTheme.bgColor)
        )
        renderer.proposedSize = ProposedViewSize(width: 400, height: 780)
        renderer.scale = 3
        guard let img = renderer.uiImage else { return }
        // PNG encoding a ~2.8M pixel bitmap and writing it are heavy; keep them
        // off the main thread so the share tap never hitches the UI.
        Task.detached(priority: .userInitiated) {
            guard let png = img.pngData() else { return }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Gaita-scorecard.png")
            try? png.write(to: url, options: .atomic)
            await MainActor.run { shareItem = ExportFile(url: url) }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text("SCORECARD DATA DOES NOT EXIST")
                .font(.arialBold(18))
                .foregroundColor(.white)
            Text(errorMessage ?? "Required real analysis data does not exist.")
                .font(.arial(13))
                .foregroundColor(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    @MainActor private func loadRealScorecard() async {
        isLoading = true
        defer { isLoading = false }

        guard let form = ScorecardDataStore.shared.load() else {
            errorMessage = "Real form-analysis data does not exist."
            data = nil
            return
        }

        let latestRun = await loadLatestRun()
        let latestScan = await loadLatestScan()
        let scanImage = await loadScanImage(from: latestScan?.imageUrl)
        let fallbackLeftZones = latestScan?.side == "left" ? latestScan?.wearZones.map(WearZoneData.init(dto:)) : nil
        let fallbackRightZones = latestScan?.side == "right" ? latestScan?.wearZones.map(WearZoneData.init(dto:)) : nil

        data = ScorecardData(
            name: displayName(),
            distance: latestRun.map { String(format: "%.1f MI", $0.distanceMiles) } ?? "NO RUN",
            time: latestRun.map { formatDuration($0.durationSeconds) } ?? "--:--",
            pace: latestRun.map { formatPace($0) } ?? "-- /MI",
            overall: form.overall,
            grade: grade(for: form.overall),
            power: form.power,
            impact: form.impact,
            efficiency: form.efficiency,
            cadence: form.cadence,
            metrics: form.metrics.map(\.metricStat),
            gaitType: (ScorecardDataStore.shared.loadGaitType() ?? latestScan?.gaitType)?.uppercased()
                ?? (ScorecardDataStore.shared.loadGaitImage() != nil ? "ANALYSIS PENDING" : "GAIT DOES NOT EXIST"),
            strikePattern: (ScorecardDataStore.shared.loadGaitStrike() ?? latestScan?.strikePattern)?.uppercased() ?? "--",
            snapshotImage: form.snapshotPNG.flatMap(UIImage.init(data:)),
            gaitImage: ScorecardDataStore.shared.loadGaitImage().flatMap(UIImage.init(data:)) ?? scanImage,
            leftWearZones: ScorecardDataStore.shared.loadWearZones(side: "left") ?? fallbackLeftZones,
            rightWearZones: ScorecardDataStore.shared.loadWearZones(side: "right") ?? fallbackRightZones,
            bounce: form.bounce ?? [],
            gct: form.gct ?? [],
            cadenceTrend: form.cadenceTrend ?? []
        )
    }

    private func loadLatestRun() async -> RunSummaryDTO? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        return try? await RunRepository.shared.fetchLastRun(uid: uid)
    }

    private func loadLatestScan() async -> ShoeScanDTO? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        return try? await ScanRepository.shared.fetchLatestScan(uid: uid)
    }

    private func loadScanImage(from urlString: String?) async -> UIImage? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return UIImage(data: data)
        } catch {
            return nil
        }
    }

    private func displayName() -> String {
        let name = Auth.auth().currentUser?.displayName ?? ""
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "GAITA" : trimmed.uppercased()
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }

    private func formatPace(_ run: RunSummaryDTO) -> String {
        guard run.distanceMiles > 0 else { return "-- /MI" }
        let paceSeconds = run.durationSeconds / run.distanceMiles
        return "\(formatDuration(paceSeconds)) /MI"
    }

    private func grade(for score: Int) -> String {
        switch score {
        case 93...100: return "A"
        case 90..<93: return "A-"
        case 87..<90: return "B+"
        case 83..<87: return "B"
        case 80..<83: return "B-"
        case 77..<80: return "C+"
        case 73..<77: return "C"
        case 70..<73: return "C-"
        case 60..<70: return "D"
        default: return "F"
        }
    }

}

#Preview {
    ScorecardShareScreen()
}
