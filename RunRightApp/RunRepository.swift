import Foundation
import FirebaseAuth
import FirebaseFirestore
import CoreLocation

final class RunRepository {
    static let shared = RunRepository()
    private init() {}

    private func runsCollection(uid: String) -> CollectionReference {
        Firestore.firestore().collection("users").document(uid).collection("runs")
    }

    // MARK: - Save

    /// Save a pre-built DTO directly (used by HealthKit sync).
    func saveRunDTO(_ dto: RunSummaryDTO, uid: String) async throws {
        let doc = runsCollection(uid: uid).document(dto.runId)
        try await writeDurable(doc, dto.toFirestore())
    }

    func saveRunSummary(_ summary: ActivitySummary, shoeName: String? = nil,
                        route: [CLLocationCoordinate2D] = []) async throws {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "RunRepository", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Not signed in — unable to save run."])
        }

        let runDoc = runsCollection(uid: uid).document()

        let dto = RunSummaryDTO(
            runId: runDoc.documentID,
            startTime: summary.startTime,
            distanceMeters: summary.distance,
            durationSeconds: summary.duration,
            avgSpeedMps: summary.averageSpeed,
            avgHeartRateBpm: nil,
            shoeName: shoeName,
            routeLatLng: RunSummaryDTO.downsampleRoute(route)
        )

        try await writeDurable(runDoc, dto.toFirestore())
    }

    /// Firestore's async `setData` only resumes on SERVER acknowledgement, so it
    /// hangs forever offline — even though the write is already durable in the
    /// local cache (offline persistence) and syncs on reconnect. Cap the wait: if
    /// the server hasn't acked within `seconds`, return so the "Saving…" UI never
    /// hangs; the run is safely queued. A fast online error still surfaces.
    private func writeDurable(_ doc: DocumentReference, _ data: [String: Any], timeout seconds: Double = 5) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await doc.setData(data, merge: true) }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            _ = try await group.next()   // first to finish; a fast write error rethrows here
            group.cancelAll()
        }
    }

    // MARK: - Fetch single / recent

    func fetchLastRun(uid: String) async throws -> RunSummaryDTO? {
        let query = runsCollection(uid: uid)
            .order(by: "startTime", descending: true)
            .limit(to: 1)

        let snapshot = try await query.getDocuments()
        guard let doc = snapshot.documents.first else { return nil }
        return RunSummaryDTO.fromFirestore(doc.data(), runId: doc.documentID)
    }

    func fetchRuns(uid: String, limit: Int) async throws -> [RunSummaryDTO] {
        let query = runsCollection(uid: uid)
            .order(by: "startTime", descending: true)
            .limit(to: limit)

        let snapshot = try await query.getDocuments()
        return snapshot.documents.compactMap { doc in
            RunSummaryDTO.fromFirestore(doc.data(), runId: doc.documentID)
        }
    }

    // MARK: - Fetch ALL runs (for stats computation)

    func fetchAllRuns(uid: String) async throws -> [RunSummaryDTO] {
        let query = runsCollection(uid: uid)
            .order(by: "startTime", descending: true)

        let snapshot = try await query.getDocuments()
        return snapshot.documents.compactMap { doc in
            RunSummaryDTO.fromFirestore(doc.data(), runId: doc.documentID)
        }
    }

    // MARK: - Day query

    func fetchTotalDurationSecondsForDay(uid: String, date: Date) async throws -> TimeInterval {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return 0 }

        let query = runsCollection(uid: uid)
            .whereField("startTime", isGreaterThanOrEqualTo: Timestamp(date: startOfDay))
            .whereField("startTime", isLessThan: Timestamp(date: endOfDay))

        let snapshot = try await query.getDocuments()
        let total = snapshot.documents.reduce(TimeInterval(0)) { partial, doc in
            let d = doc.data()["durationSeconds"] as? TimeInterval ?? 0
            return partial + d
        }
        return total
    }

    func fetchRunsForDay(uid: String, date: Date) async throws -> [RunSummaryDTO] {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return [] }

        let query = runsCollection(uid: uid)
            .whereField("startTime", isGreaterThanOrEqualTo: Timestamp(date: startOfDay))
            .whereField("startTime", isLessThan: Timestamp(date: endOfDay))
            .order(by: "startTime", descending: true)

        let snapshot = try await query.getDocuments()
        return snapshot.documents.compactMap { doc in
            RunSummaryDTO.fromFirestore(doc.data(), runId: doc.documentID)
        }
    }

    // MARK: - Monthly query

    func fetchRunsForMonth(uid: String, date: Date) async throws -> [RunSummaryDTO] {
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.year, .month], from: date)
        guard let startOfMonth = calendar.date(from: comps),
              let endOfMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth)
        else { return [] }

        let query = runsCollection(uid: uid)
            .whereField("startTime", isGreaterThanOrEqualTo: Timestamp(date: startOfMonth))
            .whereField("startTime", isLessThan: Timestamp(date: endOfMonth))
            .order(by: "startTime", descending: true)

        let snapshot = try await query.getDocuments()
        return snapshot.documents.compactMap { doc in
            RunSummaryDTO.fromFirestore(doc.data(), runId: doc.documentID)
        }
    }

    // MARK: - Weekly query (Mon-Sun of current week)

    func fetchRunsForWeek(uid: String, date: Date) async throws -> [RunSummaryDTO] {
        let monday = PlanRepository.shared.weekStart(for: date)
        let calendar = Calendar.current
        guard let nextMonday = calendar.date(byAdding: .day, value: 7, to: monday) else { return [] }

        let query = runsCollection(uid: uid)
            .whereField("startTime", isGreaterThanOrEqualTo: Timestamp(date: monday))
            .whereField("startTime", isLessThan: Timestamp(date: nextMonday))
            .order(by: "startTime", descending: false)

        let snapshot = try await query.getDocuments()
        return snapshot.documents.compactMap { doc in
            RunSummaryDTO.fromFirestore(doc.data(), runId: doc.documentID)
        }
    }

    /// Returns miles per day for Mon(0)…Sun(6) of the week containing `date`
    static func weeklyMiles(from runs: [RunSummaryDTO], weekOf date: Date) -> [Double] {
        let monday = PlanRepository.shared.weekStart(for: date)
        let calendar = Calendar.current
        var daily = [Double](repeating: 0, count: 7)

        for run in runs {
            let daysSinceMonday = calendar.dateComponents([.day], from: calendar.startOfDay(for: monday), to: calendar.startOfDay(for: run.startTime)).day ?? -1
            if daysSinceMonday >= 0 && daysSinceMonday < 7 {
                daily[daysSinceMonday] += run.distanceMiles
            }
        }
        return daily
    }

    // MARK: - Computed stats from runs array

    struct RunStats {
        var totalRuns: Int = 0
        var totalMiles: Double = 0
        var totalHours: Double = 0
        var monthlyRuns: Int = 0
        var monthlyMiles: Double = 0
        // Personal records (best time for each distance bracket)
        var pr5K: TimeInterval? // seconds for ~5K (4800-5500m)
        var pr10K: TimeInterval? // seconds for ~10K (9500-10800m)
        var prHalf: TimeInterval? // seconds for ~half marathon (20500-22000m)
        var prMarathon: TimeInterval? // seconds for ~marathon (41500-43000m)
        // Shoes with mileage
        var shoesMileage: [(name: String, miles: Double)] = []
    }

    static func computeStats(from runs: [RunSummaryDTO]) -> RunStats {
        var stats = RunStats()
        stats.totalRuns = runs.count

        let calendar = Calendar.current
        let now = Date()
        let currentMonth = calendar.component(.month, from: now)
        let currentYear = calendar.component(.year, from: now)

        var shoeMileMap: [String: Double] = [:]
        // PR tracking: keep best (shortest) duration for each distance bracket
        var best5K: TimeInterval = .infinity
        var best10K: TimeInterval = .infinity
        var bestHalf: TimeInterval = .infinity
        var bestMarathon: TimeInterval = .infinity

        for run in runs {
            let miles = run.distanceMiles
            let hours = run.durationSeconds / 3600.0
            stats.totalMiles += miles
            stats.totalHours += hours

            // Monthly
            let runMonth = calendar.component(.month, from: run.startTime)
            let runYear = calendar.component(.year, from: run.startTime)
            if runMonth == currentMonth && runYear == currentYear {
                stats.monthlyRuns += 1
                stats.monthlyMiles += miles
            }

            // Shoe mileage
            if let shoe = run.shoeName, !shoe.isEmpty {
                shoeMileMap[shoe, default: 0] += miles
            }

            // Personal records — check if run is within distance bracket
            let d = run.distanceMeters
            if d >= 4800 && d <= 5500 && run.durationSeconds < best5K {
                best5K = run.durationSeconds
            }
            if d >= 9500 && d <= 10800 && run.durationSeconds < best10K {
                best10K = run.durationSeconds
            }
            if d >= 20500 && d <= 22000 && run.durationSeconds < bestHalf {
                bestHalf = run.durationSeconds
            }
            if d >= 41500 && d <= 43000 && run.durationSeconds < bestMarathon {
                bestMarathon = run.durationSeconds
            }
        }

        stats.pr5K = best5K.isFinite ? best5K : nil
        stats.pr10K = best10K.isFinite ? best10K : nil
        stats.prHalf = bestHalf.isFinite ? bestHalf : nil
        stats.prMarathon = bestMarathon.isFinite ? bestMarathon : nil

        stats.shoesMileage = shoeMileMap
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { (name: $0.key, miles: $0.value) }

        return stats
    }

    // MARK: - HealthKit dedup query

    /// Returns all runs since `since` date — used by HealthKitManager to avoid duplicates.
    func fetchRunsSince(uid: String, since: Date) async throws -> [RunSummaryDTO] {
        let snapshot = try await runsCollection(uid: uid)
            .whereField("startTime", isGreaterThanOrEqualTo: Timestamp(date: since))
            .order(by: "startTime", descending: false)
            .getDocuments()
        return snapshot.documents.compactMap { RunSummaryDTO.fromFirestore($0.data(), runId: $0.documentID) }
    }

    // Format PR time: "23:42" or "1:52:30"
    static func formatPRTime(_ seconds: TimeInterval) -> String {
        let totalSec = Int(seconds)
        let hours = totalSec / 3600
        let mins = (totalSec % 3600) / 60
        let secs = totalSec % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }
}
