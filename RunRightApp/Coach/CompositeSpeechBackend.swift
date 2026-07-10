//
//  CompositeSpeechBackend.swift
//  Weekly Plan
//

import Foundation

/// Lewis or silence. Bundled coach clips first, then the opt-in cloud voice —
/// NEVER the robotic system voice. Unknown/uncovered lines stay silent (the
/// text is already on screen); a bad fallback is worse than none.
@MainActor
final class CompositeSpeechBackend: SpeechBackend {
    private(set) var displayName: String
    private let mode: SpeechVoiceMode
    private let systemBackend: AVSpeechBackend
    private let cloudBackend: CloudTTSSpeechBackend?
    private let bundledBackend: LewisVoiceBackend?
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
        self.bundledBackend = LewisVoiceBackend.isAvailable ? LewisVoiceBackend(player: player) : nil
        self.player = player
        self.voiceName = voiceName
        self.displayName = systemBackend.displayName
    }

    func speak(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpeechBackendError.emptyText }

        // 1) Bundled Lewis clip for this exact cue → play it.
        if let bundledBackend, LewisVoiceBackend.clipSequence(for: trimmed) != nil {
            lastUsedLabel = bundledBackend.displayName
            try await bundledBackend.speak(trimmed)
            displayName = lastUsedLabel
            return
        }

        // 2) Opt-in cloud voice only (mode != .system). Any failure → silence,
        //    never the system voice.
        if mode != .system, let cloudBackend {
            if let cached = SpeechAudioCache.cachedFileURL(for: trimmed, voice: voiceName) {
                lastUsedLabel = cloudBackend.displayName
                try? await player.play(fileURL: cached)
                displayName = lastUsedLabel
                return
            }
            try? await speakViaCloud(trimmed, cloud: cloudBackend)
            return
        }

        // 3) No clip, no opt-in cloud → stay silent. The text is on screen.
    }

    func stop() {
        bundledBackend?.stop()
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
