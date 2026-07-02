import Foundation
import FirebaseFirestore

final class FirebaseFirestoreService {
    static let shared = FirebaseFirestoreService()

    private let db: Firestore

    private init() {
        self.db = Firestore.firestore()
    }

    func collection(_ path: String) -> CollectionReference {
        db.collection(path)
    }

    func document(_ path: String) -> DocumentReference {
        db.document(path)
    }

    /// Returns a sentinel value that tells Firestore to use the server clock.
    /// Use this in dictionary payloads instead of `Date()` or `Timestamp(date:)`.
    func serverTimestamp() -> FieldValue {
        FieldValue.serverTimestamp()
    }

    /// Convenience: current Firestore instance.
    var firestore: Firestore { db }
}

