import Foundation
import UIKit
import FirebaseAuth
import FirebaseAppCheck

final class ShoeAnalysisService {
    static let shared = ShoeAnalysisService()

    private init() {}

    private var endpoint: String? {
        Bundle.main.object(forInfoDictionaryKey: "SHOE_ANALYSIS_ENDPOINT") as? String
    }

    /// Preferred path: backend proxy (keeps the OpenAI key server-side). Sends the
    /// image as base64 plus the caller's Firebase ID token; the function verifies
    /// the user, calls GPT-4o, and returns a SingleShoeResponse.
    /// Fallback path (dev only): calls OpenAI directly via the in-app key when no
    /// SHOE_ANALYSIS_ENDPOINT is configured.
    /// `previousZones` anchors the AI to the last scan so wear never regresses.
    func analyzeSingleShoe(
        imageUrl: String,
        side: String,
        fallbackImage: UIImage? = nil,
        previousZones: WearZoneData? = nil
    ) async throws -> SingleShoeResponse {
        if let endpoint, !endpoint.isEmpty, let url = URL(string: endpoint) {
            guard let idToken = try await Auth.auth().currentUser?.getIDToken() else {
                throw NSError(domain: "ShoeAnalysisService", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Not signed in. Please sign in and try again."])
            }

            var body: [String: Any] = ["side": side]
            // Prefer sending the image bytes directly so the backend doesn't need
            // Storage read access; fall back to a URL if that's all we have.
            if let image = fallbackImage,
               let jpeg = resized(image, maxDimension: 2048).jpegData(compressionQuality: 0.92) {
                body["imageBase64"] = jpeg.base64EncodedString()
            } else if !imageUrl.isEmpty {
                body["imageUrl"] = imageUrl
            }
            if let z = previousZones {
                body["previousZones"] = z.toDictionary()
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
            // Backend enforces App Check (appCheckOk 401s without the token).
            if let appCheckToken = try? await AppCheck.appCheck().token(forcingRefresh: false) {
                request.setValue(appCheckToken.token, forHTTPHeaderField: "X-Firebase-AppCheck")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 90

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let e as URLError where e.code == .notConnectedToInternet
                || e.code == .networkConnectionLost || e.code == .timedOut {
                throw NSError(domain: "ShoeAnalysisService", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "You are offline. Check your connection and try again."])
            }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw NSError(domain: "ShoeAnalysisService", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
            }

            do {
                return try JSONDecoder().decode(SingleShoeResponse.self, from: data)
            } catch {
                // Surface a clean "Failed to parse results" instead of a raw
                // DecodingError string leaking to the UI (#13).
                throw OpenAIError.parseError
            }
        }

        guard let fallbackImage else {
            throw NSError(
                domain: "ShoeAnalysisService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Backend endpoint not configured (SHOE_ANALYSIS_ENDPOINT missing), and no fallbackImage provided."]
            )
        }

        // Local/dev fallback.
        return try await OpenAIService.shared.analyzeSingleShoe(fallbackImage, side: side, previousZones: previousZones)
    }

    private func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard max(size.width, size.height) > maxDimension else { return image }
        let ratio = maxDimension / max(size.width, size.height)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let out = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return out ?? image
    }
}
