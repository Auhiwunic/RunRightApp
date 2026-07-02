import Foundation
import FirebaseAuth
import SwiftUI

// MARK: - Scan History Models

/// One scan flattened for display — built from a live AI result or a Firestore record.
struct ScanSnapshot {
    let zones: WearZoneData?
    let gaitType: String
    let strikePattern: String?
    let primaryWearAreas: String?
    let gaitCause: String?
    let concern: String?
    let severity: String?

    init(result: SingleShoeResponse) {
        zones            = result.wearZones
        gaitType         = result.gaitType
        strikePattern    = result.strikePattern
        primaryWearAreas = result.primaryWearAreas
        gaitCause        = result.gaitCause
        concern          = result.concern
        severity         = result.severity
    }

    init(dto: ShoeScanDTO) {
        zones            = dto.wearZones.map(WearZoneData.init(dto:))
        gaitType         = dto.gaitType ?? "neutral"
        strikePattern    = dto.strikePattern
        primaryWearAreas = dto.primaryWearAreas
        gaitCause        = dto.gaitCause
        concern          = dto.concern
        severity         = dto.severity
    }
}

/// All scans from one calendar day — one page of the wear-pattern carousel.
struct ScanHistoryPage: Identifiable {
    let id: Date          // startOfDay — stable identity for the page
    let date: Date
    var left: ScanSnapshot?
    var right: ScanSnapshot?
}

extension WearZoneData {
    init(dto: WearZonesDTO) {
        bigToe         = dto.bigToe
        lesserToes     = dto.lesserToes
        medialBall     = dto.medialBall
        centralBall    = dto.centralBall
        lateralBall    = dto.lateralBall
        medialMidfoot  = dto.medialMidfoot
        lateralMidfoot = dto.lateralMidfoot
        medialHeel     = dto.medialHeel
        centralHeel    = dto.centralHeel
        lateralHeel    = dto.lateralHeel
    }
}

@MainActor
final class ScanViewModel: ObservableObject {
    /// Shared instance so scan history survives tab switches (ScanView itself is
    /// recreated each time the Scan tab is shown via switch-based lazy loading).
    static let shared = ScanViewModel()

    /// Wear-health % per scan day (0…1), oldest → newest. Empty until there are
    /// at least two scan days to draw a line between.
    @Published var trendPoints: [CGFloat] = []
    /// Date labels aligned to the first and last trend points.
    @Published var trendLabels: [String] = []
    @Published var trendError: String?

    /// True once there's enough history (2+ scan days) to draw a meaningful trend.
    var hasTrend: Bool { trendPoints.count >= 2 }

    /// Which shoe the history currently reflects — lets ScanView skip a redundant
    /// reload (and the empty-state flash) when the same shoe is reselected.
    @Published private(set) var loadedShoe = ""

    /// Scan history for the selected shoe, one page per day, oldest → newest.
    /// The last page (rightmost in the carousel) is the most recent.
    @Published var historyPages: [ScanHistoryPage] = []

    /// Fetches all scans for a shoe and rebuilds both the trend chart and the history carousel.
    func loadScanData(for shoeName: String) async {
        guard !shoeName.isEmpty else {
            historyPages = []
            loadedShoe = ""
            return
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            trendError = "Not signed in."
            return
        }

        trendError = nil
        do {
            let scans = try await ScanRepository.shared.fetchScans(uid: uid, shoeName: shoeName, limit: 400)
            buildHistory(from: scans)
            computeTrend()
            loadedShoe = shoeName
        } catch {
            trendError = "Could not load scan history: \(error.localizedDescription)"
        }
    }

    /// Groups scans by calendar day. Scans arrive newest-first, so the first
    /// scan seen for a day+side is the latest one that day — keep it, skip the rest.
    private func buildHistory(from scans: [ShoeScanDTO]) {
        let calendar = Calendar.current
        var byDay: [Date: ScanHistoryPage] = [:]

        for scan in scans {
            let day = calendar.startOfDay(for: scan.createdAt)
            var page = byDay[day] ?? ScanHistoryPage(id: day, date: day, left: nil, right: nil)
            if scan.side == "left" {
                if page.left == nil { page.left = ScanSnapshot(dto: scan) }
            } else if page.right == nil {
                page.right = ScanSnapshot(dto: scan)
            }
            byDay[day] = page
        }

        historyPages = byDay.values.sorted { $0.date < $1.date }
    }

    /// Inserts a just-completed scan into today's page immediately — no Firestore round-trip.
    func mergeLiveScan(side: String, snapshot: ScanSnapshot) {
        let today = Calendar.current.startOfDay(for: Date())
        if let idx = historyPages.firstIndex(where: { $0.id == today }) {
            if side == "left" { historyPages[idx].left = snapshot }
            else              { historyPages[idx].right = snapshot }
        } else {
            var page = ScanHistoryPage(id: today, date: today, left: nil, right: nil)
            if side == "left" { page.left = snapshot } else { page.right = snapshot }
            historyPages.append(page)
        }
        computeTrend()   // keep the trend graph in sync with the new scan
    }

    /// Builds the wear trend from the history pages — one point per scan day,
    /// averaging whichever shoes were scanned that day. No empty-month gaps, so
    /// the line reflects real scans instead of crashing to zero.
    private func computeTrend() {
        func wearScore(_ color: String) -> CGFloat {
            switch color.lowercased() {
            case "green":  return 1.0
            case "yellow": return 0.45
            case "orange": return 0.15
            case "red":    return 0.0
            default:       return 1.0
            }
        }

        func health(_ z: WearZoneData) -> CGFloat {
            let scores = [
                z.bigToe, z.lesserToes, z.medialBall, z.centralBall, z.lateralBall,
                z.medialMidfoot, z.lateralMidfoot, z.medialHeel, z.centralHeel, z.lateralHeel
            ].map(wearScore)
            return scores.reduce(0, +) / CGFloat(scores.count)
        }

        // One health value per scan day (average of the sides scanned that day).
        let dayHealths: [(date: Date, value: CGFloat)] = historyPages.compactMap { page in
            let zones = [page.left?.zones, page.right?.zones].compactMap { $0 }
            guard !zones.isEmpty else { return nil }
            let avg = zones.map(health).reduce(0, +) / CGFloat(zones.count)
            return (page.date, max(0, min(1, avg)))
        }

        guard dayHealths.count >= 2 else {
            trendPoints = []
            trendLabels = []
            return
        }

        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MMM d"

        trendPoints = dayHealths.map { $0.value }
        // Label only the endpoints to keep the axis clean.
        trendLabels = [
            formatter.string(from: dayHealths.first!.date),
            formatter.string(from: dayHealths.last!.date)
        ]
    }
}

