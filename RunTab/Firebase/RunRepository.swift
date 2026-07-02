import Foundation
import FirebaseAuth
import FirebaseFirestore

final class RunRepository {
    static let shared = RunRepository()
    private init() {}

    private func runsCollection(uid: String) -> CollectionReference {
        Firestore.firestore().collection("users").document(uid).collection("runs")
    }

    func saveRunSummary(_ summary: ActivitySummary) async throws {
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
            avgHeartRateBpm: nil
        )

        try await runDoc.setData(dto.toFirestore(), merge: true)
    }

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

    func fetchTotalDurationSecondsForDay(uid: String, date: Date) async throws -> TimeInterval {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return 0 }

        // Use Timestamp for Firestore queries to match the stored type.
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
}
