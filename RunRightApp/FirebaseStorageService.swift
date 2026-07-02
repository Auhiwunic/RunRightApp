import Foundation
import FirebaseStorage

final class FirebaseStorageService {
    static let shared = FirebaseStorageService()

    private let storage: Storage

    private init() {
        self.storage = Storage.storage()
    }

    /// Upload image data to the given path and return its public download URL.
    func uploadImageData(_ data: Data, path: String, contentType: String = "image/jpeg") async throws -> URL {
        let ref = storage.reference(withPath: path)
        let metadata = StorageMetadata()
        metadata.contentType = contentType

        // Use the async overload introduced in Firebase 10+.
        _ = try await ref.putDataAsync(data, metadata: metadata)

        let downloadURL = try await ref.downloadURL()
        return downloadURL
    }
}
