//
//  CoachTTSConfig.swift
//  Weekly Plan
//

import Foundation

/// Configuration for cloud TTS. Point `cloudBaseURL` at your backend proxy — never embed API keys in the app.
enum CoachTTSConfig: Sendable {
    /// Example: `https://your-worker.workers.dev/tts`
    /// POST JSON `{"text":"..."}` → `audio/mpeg` response.
    nonisolated static let cloudBaseURL: URL? = URL(string: "https://coach-pace-tts.coach-pace.workers.dev")
    // Set after deploying cloudflare-worker/ — see cloudflare-worker/README.md

    /// ElevenLabs voice id (sent to your proxy as `voice` in the JSON body).
    nonisolated static let cloudVoiceName = "hpp4J3VqNfWAUOO0d1Us"
    nonisolated static let requestTimeout: TimeInterval = 15
}

enum SpeechVoiceMode: String, CaseIterable, Identifiable {
    case hybrid
    case cloudOnly
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hybrid: "Hybrid"
        case .cloudOnly: "Cloud"
        case .system: "System"
        }
    }

    var subtitle: String {
        switch self {
        case .hybrid: "Cache → cloud → system fallback"
        case .cloudOnly: "Cloud voice with system fallback"
        case .system: "On-device Siri voices"
        }
    }
}
