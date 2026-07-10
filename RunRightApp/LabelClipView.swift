//
//  LabelClipView.swift
//  RunRightApp
//
//  DEBUG-ONLY calibration tool. Pick a clip, run the REAL engine on it, see the
//  scores it produced, then record YOUR own grade for the same clip. Every label
//  is appended to Documents/form_labels.csv together with the engine's output —
//  that side-by-side (engine vs human) file is the ground-truth dataset used to
//  tune ScoringConfig after launch.
//
//  The whole file is wrapped in #if DEBUG, so none of it ships to the App Store.
//

#if DEBUG
import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers

/// Self-contained copy of the Analyze tab's picked-video transfer type (that one
/// is private). Copies the chosen movie into a temp file we can hand the engine.
private struct LabelPickedVideo: Transferable {
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

/// Everything the engine produced for one clip, flattened for display + CSV.
private struct EngineReadout {
    let overall: Int
    let drive: Int          // power
    let impact: Int
    let smooth: Int         // efficiency
    let hipROM: Double
    let ankleROM: Double
    let kneeROM: Double
    let armROM: Double
    let cadence: Double
    let torsoDeg: Double
    let gctMs: Double
    let footStrike: String
    let cues: [(name: String, score: Double)]
}

struct LabelClipView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("userBodyHeightMeters") private var bodyHeight: Double = 1.7

    @StateObject private var processor = VideoProcessor()

    @State private var selectedItem: PhotosPickerItem?
    @State private var clipName = ""
    @State private var readout: EngineReadout?
    @State private var isBusy = false
    @State private var loadError: String?

    // Human label
    @State private var humanOverall: Double = 75
    @State private var faults: Set<String> = []
    @State private var note = ""

    @State private var savedCount = 0
    @State private var justSaved = false

    private let faultOptions = ["Arms", "Legs / knee drive", "Posture", "Cadence", "Bounce", "Overstride", "Foot strike", "Other"]

    // Documents/form_labels.csv
    private var csvURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("form_labels.csv")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    pickerRow
                    if isBusy { busyRow }
                    if let loadError { errorRow(loadError) }
                    if let readout { engineCard(readout); labelCard(readout) }
                    footer
                }
                .padding(20)
            }
            .navigationTitle("Label clips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if FileManager.default.fileExists(atPath: csvURL.path) {
                        ShareLink(item: csvURL) { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
            .onAppear { savedCount = existingRowCount() }
            .onChange(of: selectedItem) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
        }
    }

    // MARK: - Rows

    private var pickerRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            PhotosPicker(selection: $selectedItem, matching: .videos) {
                Label(readout == nil ? "Pick a clip" : "Pick another clip",
                      systemImage: "video.badge.plus")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.15)))
            }
            TextField("Clip name (optional, e.g. IMG_2659)", text: $clipName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var busyRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Running the engine…").foregroundStyle(.secondary)
        }
    }

    private func errorRow(_ msg: String) -> some View {
        Text(msg)
            .font(AppTheme.body(16))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func engineCard(_ r: EngineReadout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ENGINE SAYS").font(AppTheme.bodySemibold(11)).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                bigScore("OVERALL", r.overall)
                bigScore("DRIVE", r.drive)
                bigScore("IMPACT", r.impact)
                bigScore("SMOOTH", r.smooth)
            }
            Divider()
            grid(r)
            DisclosureGroup("Cue scores") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(r.cues, id: \.name) { c in
                        HStack {
                            Text(c.name).font(AppTheme.body(11))
                            Spacer()
                            Text("\(Int(c.score.rounded()))").font(AppTheme.displayTabular(11))
                        }
                    }
                }
                .padding(.top, 4)
            }
            .font(AppTheme.body(11))
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
    }

    private func grid(_ r: EngineReadout) -> some View {
        let rows: [(String, String)] = [
            ("Hip ROM", fmt(r.hipROM, "°")),
            ("Knee ROM", fmt(r.kneeROM, "°")),
            ("Ankle ROM", fmt(r.ankleROM, "°")),
            ("Arm ROM", fmt(r.armROM, "°")),
            ("Cadence", fmt(r.cadence, " spm")),
            ("Torso", fmt(r.torsoDeg, "°")),
            ("GCT", fmt(r.gctMs, " ms")),
            ("Strike", r.footStrike),
        ]
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0).font(AppTheme.body(11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(row.1).font(AppTheme.displayTabular(11))
                }
            }
        }
    }

    private func labelCard(_ r: EngineReadout) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("YOUR GRADE").font(AppTheme.bodySemibold(11)).foregroundStyle(.secondary)

            HStack {
                Text("Overall").font(AppTheme.body(15))
                Spacer()
                Text("\(Int(humanOverall))").font(AppTheme.displayTabular(20))
            }
            Slider(value: $humanOverall, in: 0...100, step: 1)

            Text("Faults you see").font(AppTheme.body(15))
            FlowChips(options: faultOptions, selection: $faults)

            TextField("Notes (what looks off?)", text: $note, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)

            Button {
                saveLabel(r)
            } label: {
                Text(justSaved ? "Saved ✓" : "Save label")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.08)))
    }

    private var footer: some View {
        HStack {
            Text("\(savedCount) label\(savedCount == 1 ? "" : "s") saved")
                .font(AppTheme.body(11)).foregroundStyle(.secondary)
            Spacer()
            if FileManager.default.fileExists(atPath: csvURL.path) {
                ShareLink(item: csvURL) { Label("Export CSV", systemImage: "square.and.arrow.up").font(AppTheme.body(11)) }
            }
        }
    }

    private func bigScore(_ label: String, _ v: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(v)").font(AppTheme.displayTabular(22))
            Text(label).font(AppTheme.meta(9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func fmt(_ v: Double, _ unit: String) -> String {
        v.isFinite ? "\(Int(v.rounded()))\(unit)" : "—"
    }

    // MARK: - Engine run

    private func load(_ item: PhotosPickerItem) async {
        await MainActor.run { isBusy = true; loadError = nil; readout = nil; justSaved = false }
        do {
            guard let picked = try await item.loadTransferable(type: LabelPickedVideo.self) else {
                await MainActor.run { loadError = "Couldn't load that video."; isBusy = false }
                return
            }
            processor.videoMode = .side
            processor.error = nil
            await processor.processVideo(url: picked.url)
            let built = buildReadout()
            await MainActor.run {
                readout = built
                if built == nil { loadError = processor.error ?? "The clip couldn't be analyzed (framing/tracking)." }
                // seed the human slider at the engine's overall so you nudge from there
                if let built { humanOverall = Double(built.overall) }
                isBusy = false
            }
        } catch {
            await MainActor.run { loadError = "Load failed: \(error.localizedDescription)"; isBusy = false }
        }
    }

    /// Reuses the exact global scoring functions the Analyze tab uses.
    private func buildReadout() -> EngineReadout? {
        guard let s = processor.metricSeries, let m = processor.analysisMetrics else { return nil }
        let armROM = max(m.elbowRangeLeft, m.elbowRangeRight)
        guard let smooth = computeEfficiencyBreakdown(series: s, armSwingRangeDeg: armROM)?.composite else { return nil }
        let powerRes = powerResult(series: s, metrics: m)
        let impactRes = impactResult(series: s, metrics: m, userBodyHeightMeters: bodyHeight)
        let drive = powerRes.score
        let impact = impactRes.score
        let overall = overallFormScore(
            smooth: smooth, drive: drive, impact: impact,
            driveConfidence: powerRes.confidence, impactConfidence: impactRes.confidence)
        let gctVals = [m.groundContactLeft, m.groundContactRight].filter { $0 > 0 }
        let gct = gctVals.isEmpty ? .nan : gctVals.reduce(0, +) / Double(gctVals.count)
        return EngineReadout(
            overall: overall, drive: drive, impact: impact, smooth: smooth,
            hipROM: max(m.hipExtensionRangeLeft, m.hipExtensionRangeRight),
            ankleROM: max(m.ankleDorsiRangeLeft, m.ankleDorsiRangeRight),
            kneeROM: max(m.kneeFlexionRangeLeft, m.kneeFlexionRangeRight),
            armROM: armROM,
            cadence: m.cadence,
            torsoDeg: s.torsoAngleMean,
            gctMs: gct,
            footStrike: m.footStrikePattern,
            cues: s.formCueScores.map { ($0.cue.rawValue, Double($0.score)) }
        )
    }

    // MARK: - CSV

    private func saveLabel(_ r: EngineReadout) {
        let cueByName = Dictionary(uniqueKeysWithValues: r.cues.map { ($0.name, $0.score) })
        let cueCols = FormCue.allCases.map { cueByName[$0.rawValue].map { String(Int($0.rounded())) } ?? "" }
        let name = clipName.isEmpty ? "clip_\(savedCount + 1)" : clipName
        let fields: [String] = [
            String(Date().timeIntervalSince1970),
            csvEscape(name),
            String(r.overall), String(r.drive), String(r.impact), String(r.smooth),
            String(Int(r.hipROM.rounded())), String(Int(r.ankleROM.rounded())),
            String(Int(r.kneeROM.rounded())), String(Int(r.armROM.rounded())),
            String(Int(r.cadence.rounded())), String(Int(r.torsoDeg.rounded())),
            r.gctMs.isFinite ? String(Int(r.gctMs.rounded())) : "",
            csvEscape(r.footStrike),
            String(Int(humanOverall)),
            csvEscape(faults.sorted().joined(separator: "; ")),
            csvEscape(note),
        ] + cueCols

        let header = (["timestamp", "clip", "eng_overall", "eng_drive", "eng_impact", "eng_smooth",
                       "hip_rom", "ankle_rom", "knee_rom", "arm_rom", "cadence", "torso_deg",
                       "gct_ms", "foot_strike", "human_overall", "human_faults", "note"]
                      + FormCue.allCases.map { csvEscape($0.rawValue) }).joined(separator: ",") + "\n"
        let row = fields.joined(separator: ",") + "\n"

        if !FileManager.default.fileExists(atPath: csvURL.path) {
            try? (header + row).write(to: csvURL, atomically: true, encoding: .utf8)
        } else if let h = try? FileHandle(forWritingTo: csvURL) {
            h.seekToEndOfFile(); h.write(Data(row.utf8)); try? h.close()
        }

        savedCount = existingRowCount()
        justSaved = true
        // reset the human inputs for the next clip; keep the engine readout on screen
        note = ""; faults = []
    }

    private func existingRowCount() -> Int {
        guard let text = try? String(contentsOf: csvURL, encoding: .utf8) else { return 0 }
        return max(0, text.split(separator: "\n").count - 1)   // minus header
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}

/// Simple wrapping chip multi-selector.
private struct FlowChips: View {
    let options: [String]
    @Binding var selection: Set<String>

    var body: some View {
        // Two-column grid keeps it dead simple and wraps predictably.
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(options, id: \.self) { opt in
                let on = selection.contains(opt)
                Button {
                    if on { selection.remove(opt) } else { selection.insert(opt) }
                } label: {
                    Text(opt)
                        .font(AppTheme.body(11))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(on ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.1)))
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(on ? Color.accentColor : Color.clear, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
#endif
