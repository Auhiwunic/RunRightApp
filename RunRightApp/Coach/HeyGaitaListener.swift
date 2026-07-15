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
import AudioToolbox
import Speech
import UIKit

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
    /// Latest full transcript from the live session (finalized + volatile).
    private var lastTranscript = ""
    /// Transcript snapshot at the moment the wake word was heard — the question
    /// is whatever the runner says after this point.
    private var captureBaseline = ""

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
        lastTranscript = ""; captureBaseline = ""
    }

    /// Tap handler on the pill: skip the wake word and start capturing now.
    func tapToTalk() {
        guard phase == .off || phase == .listening || phase == .answering else { return }
        if phase == .listening, session != nil {
            enterCapture(from: lastTranscript)   // reuse the running session
        } else {
            Task { await beginCapturing() }
        }
    }

    // MARK: - Listening for the wake word

    private func beginListening() async {
        guard #available(iOS 26.0, *) else { return }
        cancelSession()
        heard = ""; lastTranscript = ""; captureBaseline = ""
        activateSession()
        let live = LiveTranscriptionSession { [weak self] text in
            self?.onTranscript(text)
        }
        do { try await live.start(); session = live; phase = .listening }
        catch { phase = .off }
    }

    /// One stream, two modes: while listening it watches for the wake word;
    /// while capturing it extracts the question from the same running session.
    /// Not restarting the analyzer on wake is what makes capture feel instant —
    /// the old teardown+respin took over a second and ate the first words.
    private func onTranscript(_ text: String) {
        lastTranscript = text
        switch phase {
        case .listening:
            if Self.containsWakeWord(text) { enterCapture(from: text) }
        case .capturing:
            onQuestionTranscript(Self.questionPart(of: text, afterBaseline: captureBaseline))
        default:
            break
        }
    }

    // MARK: - Capturing the question

    /// Switch the already-running session into capture mode (instant).
    private func enterCapture(from currentText: String) {
        silenceTask?.cancel(); dismissTask?.cancel()
        captureBaseline = currentText
        heard = ""; wordCount = 0
        phase = .capturing
        wakeChime()
        startCaptureWatchdog()
    }

    /// Cold start: no session running (tap-to-talk from .off/.answering).
    private func beginCapturing() async {
        // Push-to-talk means the mic is off until now, so the first tap may need
        // permission. The OS returns the cached grant instantly on later taps.
        let mic = await AVAudioApplication.requestRecordPermission()
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard mic, speech else { returnToIdle(); return }
        if SubscriptionManager.shared.isPremium {
            Task { await CoachVoiceEngine.shared.ensureReady() }
        }
        cancelSession()
        captureBaseline = ""; lastTranscript = ""
        heard = ""; wordCount = 0
        phase = .capturing
        wakeChime()
        guard #available(iOS 26.0, *) else { await ask(Self.fallbackQuestion); return }

        startCaptureWatchdog()
        activateSession()
        let live = LiveTranscriptionSession { [weak self] text in
            self?.onTranscript(text)
        }
        do {
            try await live.start()
            // If the watchdog already moved us on, don't keep a stray session.
            if phase == .capturing { session = live } else { await live.cancel() }
        } catch {
            if phase == .capturing { await ask(Self.fallbackQuestion) }
        }
    }

    /// Watchdog: if capture never produces speech (no mic, model still
    /// downloading, or the simulator), fall through to a default question so
    /// the coach still answers instead of hanging on "Listening".
    private func startCaptureWatchdog() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard let self, !Task.isCancelled,
                  self.phase == .capturing, self.heard.isEmpty else { return }
            await self.ask(Self.fallbackQuestion)
        }
    }

    /// Short "I'm listening" cue the moment the wake word lands — audible tick
    /// plus a haptic, so the runner knows to ask without looking at the screen.
    private func wakeChime() {
        AudioServicesPlaySystemSound(1113)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private static let fallbackQuestion = "How is my pace looking right now?"

    private func onQuestionTranscript(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }   // wake-segment rewrite noise
        heard = trimmed
        wordCount = trimmed.split(separator: " ").count
        resetSilenceTimer()
    }

    /// Fire the coach once the runner stops talking for ~1.1s (and said enough).
    private func resetSilenceTimer() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.submitIfReady()
        }
    }

    private func submitIfReady() async {
        guard phase == .capturing else { return }
        let question = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard wordCount >= 2, question.count >= 4 else {
            // Not enough said — drop back to mic-off idle (tap again to retry).
            returnToIdle()
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
        // "Got it" cue: a second, lower tick + light haptic marks the moment the
        // question is understood and the coach starts thinking, so the runner
        // knows to stop talking without looking at the screen.
        AudioServicesPlaySystemSound(1114)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        phase = .thinking
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

        // Hold the answer on screen, then go idle (mic OFF). Push-to-talk: the
        // runner taps the mic button again to ask another question — we never sit
        // on a hot mic, so their music plays uninterrupted between questions.
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled, self.phase == .answering else { return }
            self.returnToIdle()
        }
    }

    /// Return to the mic-off idle state and release the audio session so the
    /// runner's music comes back up.
    private func returnToIdle() {
        silenceTask?.cancel(); dismissTask?.cancel()
        cancelSession()
        heard = ""; answer = ""; lastTranscript = ""; captureBaseline = ""
        phase = .off
        AudioSessionManager.deactivate()
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

    /// Close variants the recognizer hears the name as ("gaeta", "gator",
    /// "gate a", "guy ta", …).
    static let wakeTokens = ["gaita", "gaeta", "gata", "gayta", "gaeda", "gada",
                             "guy ta", "guyta", "gator", "gate a", "gatea", "gate", "gaia"]

    /// Tolerant match for "Hey Gaita".
    static func containsWakeWord(_ text: String) -> Bool {
        let t = text.lowercased()
        guard let heyRange = t.range(of: "hey") else { return false }
        let after = t[heyRange.upperBound...]
        return wakeTokens.contains { after.contains($0) }
    }

    /// The question portion of a running transcript: everything after the LAST
    /// wake-token occurrence. Volatile results rewrite the current segment, so
    /// re-deriving from scratch each update is the robust option; if the wake
    /// token got rewritten away, fall back to dropping the snapshot prefix.
    static func questionPart(of text: String, afterBaseline baseline: String) -> String {
        var cut: String.Index?
        for token in wakeTokens {
            if let r = text.range(of: token, options: [.caseInsensitive, .backwards]) {
                if cut == nil || r.upperBound > cut! { cut = r.upperBound }
            }
        }
        if let cut { return String(text[cut...]) }
        if !baseline.isEmpty, text.hasPrefix(baseline) {
            return String(text.dropFirst(baseline.count))
        }
        return text
    }
}
