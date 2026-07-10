//
//  CoachVoiceInput.swift
//  RunRightApp
//
//  Voice messages to the coach with LIVE transcription: audio streams from the
//  mic into Apple's on-device SpeechAnalyzer (iOS 26) and words appear in the
//  chat as you speak (volatile results), firming up into the final transcript
//  when you stop. Audio never leaves the phone — only the final text goes to
//  the coach service, which is already disclosed as chat content.
//

import Foundation
import AVFoundation
import Speech

@MainActor
final class CoachVoiceInput: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case denied
    }

    @Published private(set) var phase: Phase = .idle
    /// Finalized text plus the current volatile guess — updates as you speak.
    @Published private(set) var liveTranscript = ""

    /// Held as AnyObject so this class compiles below iOS 26.
    private var session: AnyObject?

    /// On-device live transcription needs the iOS 26 Speech stack.
    static var isSupported: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    func startRecording() async {
        guard phase == .idle || phase == .denied else { return }
        guard #available(iOS 26.0, *) else { return }

        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            phase = .denied
            return
        }

        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
        try? audioSession.setActive(true)

        liveTranscript = ""
        let live = LiveTranscriptionSession { [weak self] text in
            self?.liveTranscript = text
        }
        do {
            try await live.start()
            session = live
            phase = .recording
        } catch {
            phase = .idle
        }
    }

    /// Stop and return the final on-device transcript (nil when nothing usable).
    func stopAndTranscribe() async -> String? {
        guard phase == .recording else { return nil }
        guard #available(iOS 26.0, *), let live = session as? LiveTranscriptionSession else {
            phase = .idle
            return nil
        }
        phase = .transcribing
        let text = await live.finish()
        session = nil
        liveTranscript = ""
        phase = .idle
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func cancel() {
        if #available(iOS 26.0, *), let live = session as? LiveTranscriptionSession {
            Task { await live.cancel() }
        }
        session = nil
        liveTranscript = ""
        phase = .idle
    }
}

// MARK: - Live streaming session (iOS 26)

@available(iOS 26.0, *)
@MainActor
final class LiveTranscriptionSession {
    private let audioEngine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<String, Never>?
    private let onUpdate: @MainActor (String) -> Void

    init(onUpdate: @escaping @MainActor (String) -> Void) {
        self.onUpdate = onUpdate
    }

    func start() async throws {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw SpeechBackendError.playbackFailed
        }
        // Volatile results are what make the transcript live.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        self.transcriber = transcriber

        // One-time on-device model install (system storage, shared across apps).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechBackendError.playbackFailed
        }

        // Accumulate finals + latest volatile into the live string.
        let onUpdate = self.onUpdate
        resultsTask = Task { @MainActor in
            var finalized = ""
            do {
                for try await result in transcriber.results {
                    let piece = String(result.text.characters)
                    if result.isFinal {
                        finalized += piece
                        onUpdate(finalized)
                    } else {
                        onUpdate(finalized + piece)
                    }
                }
            } catch {
                // stream ended — keep whatever was finalized
            }
            return finalized
        }

        let (inputSequence, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        inputContinuation = continuation
        try await analyzer.start(inputSequence: inputSequence)

        let inputNode = audioEngine.inputNode
        // Echo cancellation: without it the mic hears the phone's own speaker,
        // so music or the coach's voice drowns the runner and "Hey Gaita" never
        // triggers while anything is playing. Must be set BEFORE reading the tap
        // format (it changes the input format). Best effort — unsupported routes
        // (some simulators) just keep the raw mic.
        try? inputNode.setVoiceProcessingEnabled(true)
        let tapFormat = inputNode.outputFormat(forBus: 0)
        let converter = AVAudioConverter(from: tapFormat, to: analyzerFormat)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buffer, _ in
            guard let converter else {
                continuation.yield(AnalyzerInput(buffer: buffer))
                return
            }
            let ratio = analyzerFormat.sampleRate / tapFormat.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up) + 16)
            guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
            var fed = false
            var convError: NSError?
            converter.convert(to: out, error: &convError) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if convError == nil, out.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: out))
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Stop the mic, flush the analyzer, and return the final transcript.
    func finish() async -> String {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        let text = await resultsTask?.value ?? ""
        analyzer = nil
        transcriber = nil
        return text
    }

    func cancel() async {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        analyzer = nil
        transcriber = nil
    }
}
