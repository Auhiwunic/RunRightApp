import Foundation
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage

final class ScanRepository {
    static let shared = ScanRepository()
    private init() {}

    private func scansCollection(uid: String) -> CollectionReference {
        Firestore.firestore().collection("users").document(uid).collection("scans")
    }

    private func shoesCollection(uid: String) -> CollectionReference {
        Firestore.firestore().collection("users").document(uid).collection("shoes")
    }

    func ensureShoeExists(uid: String, shoeName: String) async throws {
        let shoeId = shoeDocumentId(from: shoeName)
        let doc = shoesCollection(uid: uid).document(shoeId)

        // serverTimestamp DOES overwrite on merge, so writing it on every scan
        // reset createdAt and churned shoe ordering. Stamp it only on creation.
        let snapshot = try await doc.getDocument()
        if snapshot.exists {
            try await doc.setData(["shoeName": shoeName], merge: true)
        } else {
            try await doc.setData([
                "shoeName": shoeName,
                "createdAt": FieldValue.serverTimestamp()
            ], merge: true)
        }
    }

    func saveSingleShoeScan(
        uid: String,
        scanId: String = UUID().uuidString,
        shoeName: String,
        side: String,
        createdAt: Date = Date(),
        result: SingleShoeResponse,
        imageDownloadURL: String?
    ) async throws {
        try await ensureShoeExists(uid: uid, shoeName: shoeName)

        let wearZonesDTO: WearZonesDTO? = result.wearZones.map { zones in
            WearZonesDTO(
                bigToe: zones.bigToe,
                lesserToes: zones.lesserToes,
                medialBall: zones.medialBall,
                centralBall: zones.centralBall,
                lateralBall: zones.lateralBall,
                medialMidfoot: zones.medialMidfoot,
                lateralMidfoot: zones.lateralMidfoot,
                medialHeel: zones.medialHeel,
                centralHeel: zones.centralHeel,
                lateralHeel: zones.lateralHeel
            )
        }

        let dto = ShoeScanDTO(
            scanId: scanId,
            shoeName: shoeName,
            side: side,
            createdAt: createdAt,
            wearZones: wearZonesDTO,
            gaitType: result.gaitType,
            strikePattern: result.strikePattern,
            primaryWearAreas: result.primaryWearAreas,
            gaitCause: result.gaitCause,
            concern: result.concern,
            severity: result.severity,
            imageUrl: imageDownloadURL,
            wearPercents: result.wearPercents,
            estimatedMilesRemaining: result.estimatedMilesRemaining,
            confidence: result.confidence,
            treadNote: result.treadNote
        )

        let doc = scansCollection(uid: uid).document(scanId)
        try await doc.setData(dto.toFirestore(), merge: true)
    }

    func fetchScans(uid: String, shoeName: String, limit: Int = 200) async throws -> [ShoeScanDTO] {
        let query = scansCollection(uid: uid)
            .whereField("shoeName", isEqualTo: shoeName)
            .order(by: "createdAt", descending: true)
            .limit(to: limit)

        let snapshot = try await query.getDocuments()
        return snapshot.documents.compactMap { doc in
            decodeScanDTO(docId: doc.documentID, data: doc.data())
        }
    }

    func fetchLatestScan(uid: String) async throws -> ShoeScanDTO? {
        let query = scansCollection(uid: uid)
            .order(by: "createdAt", descending: true)
            .limit(to: 1)

        let snapshot = try await query.getDocuments()
        guard let doc = snapshot.documents.first else { return nil }
        return decodeScanDTO(docId: doc.documentID, data: doc.data())
    }

    private func decodeScanDTO(docId: String, data: [String: Any]) -> ShoeScanDTO? {
        guard let shoeName = data["shoeName"] as? String,
              let side = data["side"] as? String
        else { return nil }

        // Normalize: Firestore always returns Timestamp, but handle Date for safety.
        let createdAt: Date = {
            if let ts = data["createdAt"] as? Timestamp { return ts.dateValue() }
            if let d = data["createdAt"] as? Date { return d }
            return Date()
        }()

        let gaitType = data["gaitType"] as? String
        let strikePattern = data["strikePattern"] as? String
        let primaryWearAreas = data["primaryWearAreas"] as? String
        let gaitCause = data["gaitCause"] as? String
        let concern = data["concern"] as? String
        let severity = data["severity"] as? String
        let imageUrl = data["imageUrl"] as? String

        let wearZones: WearZonesDTO? = {
            guard let zonesDict = data["wearZones"] as? [String: Any] else { return nil }

            func zone(_ key: String) -> String? { zonesDict[key] as? String }

            guard let bigToe = zone("bigToe"),
                  let lesserToes = zone("lesserToes"),
                  let medialBall = zone("medialBall"),
                  let centralBall = zone("centralBall"),
                  let lateralBall = zone("lateralBall"),
                  let medialMidfoot = zone("medialMidfoot"),
                  let lateralMidfoot = zone("lateralMidfoot"),
                  let medialHeel = zone("medialHeel"),
                  let centralHeel = zone("centralHeel"),
                  let lateralHeel = zone("lateralHeel")
            else { return nil }

            return WearZonesDTO(
                bigToe: bigToe,
                lesserToes: lesserToes,
                medialBall: medialBall,
                centralBall: centralBall,
                lateralBall: lateralBall,
                medialMidfoot: medialMidfoot,
                lateralMidfoot: lateralMidfoot,
                medialHeel: medialHeel,
                centralHeel: centralHeel,
                lateralHeel: lateralHeel
            )
        }()

        return ShoeScanDTO(
            scanId: docId,
            shoeName: shoeName,
            side: side,
            createdAt: createdAt,
            wearZones: wearZones,
            gaitType: gaitType,
            strikePattern: strikePattern,
            primaryWearAreas: primaryWearAreas,
            gaitCause: gaitCause,
            concern: concern,
            severity: severity,
            imageUrl: imageUrl,
            wearPercents: data["wearPercents"] as? [String: Int],
            estimatedMilesRemaining: data["estimatedMilesRemaining"] as? Int,
            confidence: data["confidence"] as? Int,
            treadNote: data["treadNote"] as? String
        )
    }

    /// Fetches all shoe names the user has ever saved, newest first.
    func fetchShoeNames(uid: String) async throws -> [String] {
        let snapshot = try await shoesCollection(uid: uid)
            .order(by: "createdAt", descending: true)
            .getDocuments()
        return snapshot.documents.compactMap { $0.data()["shoeName"] as? String }
    }

    private func shoeDocumentId(from shoeName: String) -> String {
        let lowered = shoeName.lowercased().replacingOccurrences(of: " ", with: "_")
        // Firestore document IDs cannot contain "/" (it's the path separator) and
        // cannot be "." or "..". A shoe named e.g. "Nike/Pegasus" used to build an
        // invalid path and crash the app — sanitize before use.
        var id = lowered
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\u{00}", with: "")
        if id.isEmpty || id == "." || id == ".." { id = "shoe" }
        return id
    }
}
