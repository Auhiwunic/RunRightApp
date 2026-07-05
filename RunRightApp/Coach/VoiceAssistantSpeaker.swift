//
//  VoiceAssistantSpeaker.swift
//  Weekly Plan
//

import AVFoundation
import Combine

@MainActor
final class VoiceAssistantSpeaker: ObservableObject {
    @Published private(set) var isSpeaking = false
    @Published private(set) var lastError: String?

    private let systemBackend: AVSpeechBackend
    private let player = AudioPlaybackController()
    private var backend: CompositeSpeechBackend
    private var speakTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?

    init() {
        let system = AVSpeechBackend()
        systemBackend = system
        backend = Self.makeBackend(system: system, player: player)

        interruptionObserver = AudioSessionManager.observeInterruptions { [weak self] in
            _ = AudioSessionManager.activate()
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    func prepare() {
        _ = AudioSessionManager.activate()
    }

    func speak(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        speakTask?.cancel()
        lastError = nil
        _ = AudioSessionManager.activate()

        speakTask = Task { [backend] in
            isSpeaking = true
            do {
                try await backend.speak(text)
                if !Task.isCancelled {
                    lastError = nil
                }
            } catch {
                if !Task.isCancelled {
                    lastError = errorMessage(for: error)
                }
            }
            if !Task.isCancelled {
                isSpeaking = false
            }
        }
    }

    func stop() {
        speakTask?.cancel()
        speakTask = nil
        backend.stop()
        isSpeaking = false
    }

    func shutdown() {
        stop()
        AudioSessionManager.deactivate()
    }

    /// Graceful end: let the in-flight utterance (e.g. the closing run cue) finish
    /// playing, THEN deactivate the audio session — so a fast Save that tears down
    /// the run doesn't clip the cue. Deactivates immediately if nothing is speaking.
    /// `keepActiveIf` lets the caller veto deactivation (e.g. a new run started).
    func finishThenDeactivate(keepActiveIf stillNeeded: @escaping @MainActor () -> Bool = { false }) {
        let task = speakTask
        Task { [weak self] in
            if let task { _ = await task.value }
            guard let self else { return }
            if self.isSpeaking || stillNeeded() { return }
            AudioSessionManager.deactivate()
        }
    }

    private func errorMessage(for error: Error) -> String {
        if case SpeechBackendError.cloudRequestFailed(let detail) = error {
            return detail
        }
        return "Voice unavailable — used system voice."
    }

    private static func makeBackend(
        system: AVSpeechBackend,
        player: AudioPlaybackController
    ) -> CompositeSpeechBackend {
        // Apple's on-device voice is the default: free, offline, nothing sent
        // off device. The cloud voice stays behind an explicit opt-in flag —
        // do not flip it on until the TTS worker authenticates callers.
        let cloudOptIn = UserDefaults.standard.bool(forKey: "coach.cloudVoice.v1")
        let mode: SpeechVoiceMode = (cloudOptIn && CoachTTSConfig.cloudBaseURL != nil) ? .hybrid : .system
        let cloud: CloudTTSSpeechBackend?
        if let baseURL = CoachTTSConfig.cloudBaseURL {
            cloud = CloudTTSSpeechBackend(baseURL: baseURL, player: player)
        } else {
            cloud = nil
        }

        return CompositeSpeechBackend(
            mode: mode,
            systemBackend: system,
            cloudBackend: cloud,
            player: player
        )
    }
}
