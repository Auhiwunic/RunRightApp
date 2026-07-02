//
//  CompositeSpeechBackend.swift
//  Weekly Plan
//

import Foundation

/// Cache → cloud (and cache write) → on-device system voice.
@MainActor
final class CompositeSpeechBackend: SpeechBackend {
    private(set) var displayName: String
    private let mode: SpeechVoiceMode
    private let systemBackend: AVSpeechBackend
    private let cloudBackend: CloudTTSSpeechBackend?
    private let player: AudioPlaybackController
    private let voiceName: String

    private var lastUsedLabel = "System voice"

    init(
        mode: SpeechVoiceMode,
        systemBackend: AVSpeechBackend,
        cloudBackend: CloudTTSSpeechBackend?,
        player: AudioPlaybackController,
        voiceName: String = CoachTTSConfig.cloudVoiceName
    ) {
        self.mode = mode
        self.systemBackend = systemBackend
        self.cloudBackend = cloudBackend
        self.player = player
        self.voiceName = voiceName
        self.displayName = systemBackend.displayName
    }

    func speak(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpeechBackendError.emptyText }

        switch mode {
        case .system:
            lastUsedLabel = systemBackend.displayName
            try await systemBackend.speak(trimmed)
            displayName = lastUsedLabel
            return

        case .cloudOnly:
            if let cloudBackend {
                do {
                    try await speakViaCloud(trimmed, cloud: cloudBackend)
                    return
                } catch {
                    lastUsedLabel = "\(systemBackend.displayName) (fallback)"
                    try await systemBackend.speak(trimmed)
                    displayName = lastUsedLabel
                    throw error
                }
            }
            lastUsedLabel = systemBackend.displayName
            try await systemBackend.speak(trimmed)
            displayName = lastUsedLabel
            return

        case .hybrid:
            if let cached = SpeechAudioCache.cachedFileURL(for: trimmed, voice: voiceName) {
                lastUsedLabel = "ElevenLabs · Cached"
                try await player.play(fileURL: cached)
                displayName = lastUsedLabel
                return
            }

            if let cloudBackend {
                do {
                    try await speakViaCloud(trimmed, cloud: cloudBackend)
                    return
                } catch {
                    lastUsedLabel = "\(systemBackend.displayName) (fallback)"
                    try await systemBackend.speak(trimmed)
                    displayName = lastUsedLabel
                    throw error
                }
            }

            lastUsedLabel = systemBackend.displayName
            try await systemBackend.speak(trimmed)
            displayName = lastUsedLabel
        }
    }

    func stop() {
        player.stop()
        cloudBackend?.stop()
        systemBackend.stop()
    }

    private func speakViaCloud(_ text: String, cloud: CloudTTSSpeechBackend) async throws {
        let data = try await cloud.fetchAudio(for: text)
        _ = try? SpeechAudioCache.save(data, for: text, voice: voiceName)
        lastUsedLabel = cloud.displayName
        try await player.play(data: data)
        displayName = lastUsedLabel
    }
}
