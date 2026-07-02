//
//  AVSpeechBackend.swift
//  Weekly Plan
//

import AVFoundation

@MainActor
final class AVSpeechBackend: NSObject, SpeechBackend {
    private let synthesizer = AVSpeechSynthesizer()
    private let selectedVoice: AVSpeechSynthesisVoice?
    private var finishContinuation: CheckedContinuation<Void, Error>?

    private(set) var displayName: String

    override init() {
        let voice = Self.bestAvailableVoice()
        selectedVoice = voice
        displayName = Self.displayName(for: voice)
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpeechBackendError.emptyText }

        stop()
        _ = AudioSessionManager.activate()

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = selectedVoice ?? AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        utterance.preUtteranceDelay = 0.12
        utterance.postUtteranceDelay = 0.08

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            finishContinuation = continuation
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        finishContinuation?.resume()
        finishContinuation = nil
    }

  // MARK: - Voice selection

    private static func bestAvailableVoice() -> AVSpeechSynthesisVoice? {
        let premiumIdentifiers = [
            "com.apple.voice.premium.en-US.Samantha",
            "com.apple.voice.premium.en-US.Ava",
            "com.apple.voice.premium.en-US.Allison",
            "com.apple.voice.premium.en-US.Zoe",
            "com.apple.voice.premium.en-US.Nathan",
            "com.apple.voice.enhanced.en-US.Samantha",
            "com.apple.voice.enhanced.en-US.Ava",
            "com.apple.voice.enhanced.en-US.Allison",
            "com.apple.voice.enhanced.en-US.Zoe",
            "com.apple.voice.enhanced.en-US.Nathan",
        ]

        for identifier in premiumIdentifiers {
            if let voice = AVSpeechSynthesisVoice(identifier: identifier) {
                return voice
            }
        }

        let englishVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }

        if #available(iOS 17.0, *) {
            if let match = pickByPreference(from: englishVoices.filter { $0.quality == .premium }) {
                return match
            }
        }

        if #available(iOS 16.0, *) {
            if let match = pickByPreference(from: englishVoices.filter { $0.quality == .enhanced }) {
                return match
            }
        }

        let preferredNames = [
            "Samantha", "Ava", "Allison", "Zoe", "Nathan",
            "Karen", "Daniel", "Moira", "Tessa"
        ]

        for name in preferredNames {
            if let voice = englishVoices.first(where: {
                $0.name.localizedCaseInsensitiveContains(name)
                    && !$0.name.localizedCaseInsensitiveContains("Compact")
            }) {
                return voice
            }
        }

        return AVSpeechSynthesisVoice(language: "en-US") ?? englishVoices.first
    }

    private static func pickByPreference(from voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        let preferredNames = ["Samantha", "Ava", "Allison", "Zoe", "Nathan", "Karen"]
        for name in preferredNames {
            if let voice = voices.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
                return voice
            }
        }
        return voices.first
    }

    private static func displayName(for voice: AVSpeechSynthesisVoice?) -> String {
        guard let voice else { return "System voice" }
        if #available(iOS 16.0, *) {
            switch voice.quality {
            case .premium: return "\(voice.name) · Premium"
            case .enhanced: return "\(voice.name) · Enhanced"
            default: return voice.name
            }
        }
        return voice.name
    }
}

extension AVSpeechBackend: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            finishContinuation?.resume()
            finishContinuation = nil
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            finishContinuation?.resume()
            finishContinuation = nil
        }
    }
}
