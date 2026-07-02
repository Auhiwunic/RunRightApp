//
//  CloudTTSSpeechBackend.swift
//  Weekly Plan
//

import Foundation

@MainActor
final class CloudTTSSpeechBackend: SpeechBackend {
    let displayName: String
    private let baseURL: URL
    private let voiceName: String
    private let session: URLSession
    private let player: AudioPlaybackController

    init(
        baseURL: URL,
        voiceName: String = CoachTTSConfig.cloudVoiceName,
        player: AudioPlaybackController,
        displayName: String? = nil
    ) {
        self.baseURL = baseURL
        self.voiceName = voiceName
        self.player = player
        self.displayName = displayName ?? "ElevenLabs · Cloud"
        self.session = URLSession(configuration: .default)
    }

    func speak(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpeechBackendError.emptyText }

        let data = try await fetchAudio(for: trimmed)
        try await player.play(data: data)
    }

    func stop() {
        player.stop()
    }

    func fetchAudio(for text: String) async throws -> Data {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = CoachTTSConfig.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: String] = [
            "text": text,
            "voice": voiceName,
        ]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw SpeechBackendError.cloudRequestFailed("Invalid response")
        }

        guard (200...299).contains(http.statusCode) else {
            let detail = Self.errorMessage(from: data, statusCode: http.statusCode)
            throw SpeechBackendError.cloudRequestFailed(detail)
        }

        guard !data.isEmpty else {
            throw SpeechBackendError.cloudRequestFailed("Empty audio")
        }

        return data
    }

    private static func errorMessage(from data: Data, statusCode: Int) -> String {
        if
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let detail = json["detail"] as? [String: Any],
            let message = detail["message"] as? String
        {
            if detail["code"] as? String == "paid_plan_required" {
                return "ElevenLabs: that voice needs a paid plan. Upgrade at elevenlabs.io or pick a default voice id."
            }
            return message
        }

        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text
        }

        return "HTTP \(statusCode)"
    }
}
