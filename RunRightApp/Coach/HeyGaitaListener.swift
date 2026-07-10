//
//  HeyGaitaListener.swift
//  RunRightApp
//
//  Hands-free "Hey Gaita" voice coach during a run. While the run screen is in
//  the foreground it listens on-device (SpeechAnalyzer, iOS 26) for the wake
//  phrase; on hearing it, it captures the question, sends it to the coach, shows
//  the answer on the run screen, and speaks it (premium voice). Everything is
//  on-device except the coach text call. Foreground only — iOS does not give
//  third parties a true always-on background wake word like Siri.
//
//  The listening pill is also tappable, so it works as push-to-talk even if the
//  wake word is missed or the phrase is misheard.
//

import Foundation
import AVFoundation
import Speech

@MainActor
final class HeyGaitaListener: ObservableObject {
    enum Phase: Equatable {
        case off          // not running
        case listening    // passively waiting for "Hey Gaita"
        case capturing    // heard the wake word, now capturing the question
        case thinking     // waiting on the coach
        case answering    // showing the answer
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var heard = ""     // live question transcript
    @Published private(set) var answer = ""    // coach reply

    private var session: AnyObject?            // LiveTranscriptionSession (iOS 26)
    private var silenceTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var wordCount = 0

    static var isSupported: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    // MARK: - Lifecycle

    func start() async {
        guard phase == .off, Self.isSupported else { return }
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else { return }
        // On-device transcription needs speech-recognition permission too, or the
        // transcriber yields nothing and the wake word is never heard.
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return }
        // Warm the premium voice so replies are actually spoken during the run,
        // even if the runner never opened the Coach chat first.
        if SubscriptionManager.shared.isPremium {
            Task { await CoachVoiceEngine.shared.ensureReady() }
        }
        await beginListening()
    }

    func stop() {
        silenceTask?.cancel(); dismissTask?.cancel()
        cancelSession()
        phase = .off
        heard = ""; answer = ""
    }

    /// Tap handler on the pill: skip the wake word and start capturing now.
    func tapToTalk() {
        guard phase == .off || phase == .listening || phase == .answering else { return }
        Task { await beginCapturing() }
    }

    // MARK: - Listening for the wake word

    private func beginListening() async {
        guard #available(iOS 26.0, *) else { return }
        cancelSession()
        heard = ""
        activateSession()
        let live = LiveTranscriptionSession { [weak self] text in
            self?.onWakeTranscript(text)
        }
        do { try await live.start(); session = live; phase = .listening }
        catch { phase = .off }
    }

    private func onWakeTranscript(_ text: String) {
        guard phase == .listening, Self.containsWakeWord(text) else { return }
        Task { await beginCapturing() }
    }

    // MARK: - Capturing the question

    private func beginCapturing() async {
        cancelSession()
        heard = ""; wordCount = 0
        phase = .capturing
        guard #available(iOS 26.0, *) else { await ask(Self.fallbackQuestion); return }

        // Watchdog: if capture never produces speech (no mic, model still
        // downloading, or the simulator), fall through to a default question so
        // the coach still answers instead of hanging on "Listening".
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled,
                  self.phase == .capturing, self.heard.isEmpty else { return }
            await self.ask(Self.fallbackQuestion)
        }

        activateSession()
        let live = LiveTranscriptionSession { [weak self] text in
            self?.onQuestionTranscript(text)
        }
        do {
            try await live.start()
            // If the watchdog already moved us on, don't keep a stray session.
            if phase == .capturing { session = live } else { await live.cancel() }
        } catch {
            if phase == .capturing { await ask(Self.fallbackQuestion) }
        }
    }

    private static let fallbackQuestion = "How is my pace looking right now?"

    private func onQuestionTranscript(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        heard = trimmed
        wordCount = trimmed.split(separator: " ").count
        resetSilenceTimer()
    }

    /// Fire the coach once the runner stops talking for ~1.4s (and said enough).
    private func resetSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.submitIfReady()
        }
    }

    private func submitIfReady() async {
        guard phase == .capturing else { return }
        let question = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wordCount >= 2, question.count >= 4 else {
            // Not enough said — go back to waiting for the wake word.
            await beginListening()
            return
        }
        cancelSession()
        phase = .thinking
        await ask(question)
    }

    // MARK: - Ask the coach

    private func ask(_ question: String) async {
        // Stop the mic + recognizer before we think and answer. The watchdog and
        // start-failure paths call ask() without cancelling first, which otherwise
        // keeps the mic hot straight through the spoken reply (#15).
        cancelSession()
        var reply = "I couldn't reach your coach. Try again."
        do {
            let r = try await CoachChatService.shared.reply(
                to: question,
                history: [CoachMessage(role: .user, text: question)],
                extraContext: CoachChatService.runContext()   // live pace/distance during the run
            )
            reply = r.text
            // Mid-run the coach is stats and tips ONLY. It never changes the plan
            // or profile, so any action the model returns is deliberately ignored.
        } catch {
            CrashReporter.record(error, context: "heygaita.reply")
            reply = (error as? LocalizedError)?.errorDescription ?? reply
        }

        answer = reply
        phase = .answering

        // Speak it in Lewis's voice when the premium engine is ready (best effort).
        if SubscriptionManager.shared.isPremium {
            await CoachVoiceEngine.shared.speak(answer)
        }

        // Hold the answer on screen, then resume listening for the next "Hey Gaita".
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled, self.phase == .answering else { return }
            await self.beginListening()
        }
    }

    // MARK: - Helpers

    private func activateSession() {
        let a = AVAudioSession.sharedInstance()
        // Mix with the run's music/podcast; duck it while we listen.
        try? a.setCategory(.playAndRecord, mode: .spokenAudio,
                           options: [.duckOthers, .defaultToSpeaker, .mixWithOthers])
        try? a.setActive(true)
    }

    private func cancelSession() {
        if #available(iOS 26.0, *), let live = session as? LiveTranscriptionSession {
            Task { await live.cancel() }
        }
        session = nil
    }

    /// Tolerant match for "Hey Gaita" — the recognizer often hears the name as
    /// "gaeta", "gator", "gate a", "guy ta", etc., so accept the close variants.
    static func containsWakeWord(_ text: String) -> Bool {
        let t = text.lowercased()
        guard let heyRange = t.range(of: "hey") else { return false }
        let after = t[heyRange.upperBound...]
        let tokens = ["gaita", "gaeta", "gata", "gayta", "gaeda", "gada",
                      "guy ta", "guyta", "gator", "gate a", "gatea", "gate", "gaia"]
        return tokens.contains { after.contains($0) }
    }
}
