//
//  BacktestRunner.swift
//  RunRightApp
//
//  DEBUG-ONLY headless backtest. When launched with GAITA_BACKTEST=1 in the
//  environment, it runs the REAL analysis pipeline (VideoProcessor + the same
//  global scoring functions the Analyze tab uses) over every clip dropped into
//  Documents/backtest_inbox/, then writes Documents/backtest_results.json.
//
//  This exists so a whole folder of clips can be scored reproducibly from the
//  command line (push clips into the app container, launch with the flag, read
//  the JSON back) instead of hand-picking each one through the photo picker.
//  Wrapped in #if DEBUG so it never ships.
//

#if DEBUG
import Foundation

@MainActor
enum BacktestRunner {

    struct ClipResult: Codable {
        let clip: String
        var ok: Bool
        var error: String?
        var overall: Int?
        var drive: Int?          // power
        var impact: Int?
        var smooth: Int?         // efficiency
        var hipROM: Double?
        var ankleROM: Double?
        var kneeROM: Double?
        var armROM: Double?
        var cadence: Double?
        var torsoDeg: Double?
        var gctMs: Double?
        var footStrike: String?
        var cues: [String: Double]?
    }

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["GAITA_BACKTEST"] == "1"
    }

    /// Call from app launch; no-ops unless the backtest flag is set.
    static func runIfNeeded() {
        guard isEnabled else { return }
        Task { await runAll() }
    }

    static func runAll() async {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let inbox = docs.appendingPathComponent("backtest_inbox", isDirectory: true)
        let out = docs.appendingPathComponent("backtest_results.json")

        let exts: Set<String> = ["mov", "mp4", "m4v", "qt"]
        let files = ((try? fm.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? [])
            .filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        NSLog("BACKTEST START inbox=\(inbox.path) files=\(files.count)")

        let height = UserDefaults.standard.double(forKey: "userBodyHeightMeters")
        let bodyHeight = height > 0.5 ? height : 1.7

        var results: [ClipResult] = []
        for url in files {
            var r = ClipResult(clip: url.lastPathComponent, ok: false)

            let processor = VideoProcessor()
            processor.videoMode = .side
            processor.error = nil
            await processor.processVideo(url: url)

            if let s = processor.metricSeries, let m = processor.analysisMetrics {
                let armROM = max(m.elbowRangeLeft, m.elbowRangeRight)
                if let smooth = computeEfficiencyBreakdown(series: s, armSwingRangeDeg: armROM)?.composite {
                    let drive = computeSprintPowerComposite(series: s, metrics: m, userBodyHeightMeters: bodyHeight)
                    let impact = impactResult(series: s, metrics: m, userBodyHeightMeters: bodyHeight).score
                    let overall = Int(faultSensitiveScore([Double(smooth), Double(drive), Double(impact)]).rounded())
                    let gctVals = [m.groundContactLeft, m.groundContactRight].filter { $0 > 0 }
                    let gct = gctVals.isEmpty ? Double.nan : gctVals.reduce(0, +) / Double(gctVals.count)

                    r.ok = true
                    r.overall = overall; r.drive = drive; r.impact = impact; r.smooth = smooth
                    r.hipROM = max(m.hipExtensionRangeLeft, m.hipExtensionRangeRight)
                    r.ankleROM = max(m.ankleDorsiRangeLeft, m.ankleDorsiRangeRight)
                    r.kneeROM = max(m.kneeFlexionRangeLeft, m.kneeFlexionRangeRight)
                    r.armROM = armROM
                    r.cadence = m.cadence
                    r.torsoDeg = s.torsoAngleMean
                    r.gctMs = gct.isFinite ? gct : nil
                    r.footStrike = m.footStrikePattern
                    r.cues = Dictionary(uniqueKeysWithValues: s.formCueScores.map { ($0.cue.rawValue, Double($0.score)) })
                } else {
                    r.error = processor.error ?? "efficiency composite nil (tracking/framing)"
                }
            } else {
                r.error = processor.error ?? "no metrics produced (pose not tracked)"
            }

            results.append(r)
            NSLog("BACKTEST clip=\(r.clip) ok=\(r.ok) overall=\(r.overall.map(String.init) ?? "-") drive=\(r.drive.map(String.init) ?? "-") impact=\(r.impact.map(String.init) ?? "-") smooth=\(r.smooth.map(String.init) ?? "-") strike=\(r.footStrike ?? "-") err=\(r.error ?? "")")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(results) {
            try? data.write(to: out)
            NSLog("BACKTEST wrote \(results.count) result(s) to \(out.path)")
        }
        NSLog("BACKTEST DONE")
    }
}
#endif
