//
//  CoachVoiceEngine.swift
//  RunRightApp
//
//  The dynamic coach voice: Kokoro-82M running on the Neural Engine via
//  FluidAudio (Apache 2.0 end to end — verified, zero GPL). Speaks ARBITRARY
//  text — chat replies, anything the scripted clip library can't cover.
//
//  Premium only: the ~94MB model set is NOT bundled; it downloads on demand
//  after the user subscribes and lives in Application Support. Lewis ships
//  with the app as a 512KB style vector (bm_lewis.bin) and is installed into
//  the model store before first init, since the engine's default set only
//  includes one stock voice.
//

import Foundation
import AVFoundation
import FluidAudio

@MainActor
final class CoachVoiceEngine: ObservableObject {
    static let shared = CoachVoiceEngine()

    enum EngineState: Equatable {
        case idle
        case downloading(Double)   // 0...1
        case ready
        case failed(String)
    }

    @Published private(set) var state: EngineState = .idle

    private var manager: KokoroAneManager?
    private let player = AudioPlaybackController()
    private static let voiceName = "bm_lewis"

    private init() {}

    var isReady: Bool { state == .ready }

    /// After a failed init, wait this long before trying again. Without it the
    /// Coach tab's warmup .task re-ran the whole model download attempt on
    /// every appearance, hammering the network on each tab switch.
    private static let retryCooldown: TimeInterval = 15 * 60
    private var lastFailureAt: Date?

    /// Download (if needed) and initialize the engine. Call only for premium
    /// users — the download is the paid feature's cost, not the free tier's.
    func ensureReady() async {
        if case .ready = state { return }
        if case .downloading = state { return }
        if case .failed = state, let last = lastFailureAt,
           Date().timeIntervalSince(last) < Self.retryCooldown { return }
        state = .downloading(0)
        do {
            try Self.installLewisStyleIfNeeded()
            try await KokoroAneResourceDownloader.ensureModels(variant: .english, directory: nil) { [weak self] progress in
                Task { @MainActor in self?.state = .downloading(progress.fractionCompleted * 0.85) }
            }
            try await KokoroAneResourceDownloader.ensureG2PAssets { [weak self] progress in
                Task { @MainActor in self?.state = .downloading(0.85 + progress.fractionCompleted * 0.1) }
            }
            await KokoroAneResourceDownloader.ensureEnglishLexicon()
            let m = KokoroAneManager(defaultVoice: Self.voiceName)
            try await m.initialize(preloadVoices: [Self.voiceName])
            manager = m
            state = .ready
        } catch {
            lastFailureAt = Date()
            state = .failed(error.localizedDescription)
        }
    }

    /// Speak arbitrary text in the coach voice, chunked by sentence to stay
    /// under the engine's phoneme cap. Lewis or nothing: if the engine is not
    /// ready the reply stays text only — the robotic system voice broke the
    /// coach's identity, so it never speaks chat replies.
    func speak(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let manager, case .ready = state else { return }
        _ = AudioSessionManager.activate()

        let parts = Self.chunks(Self.speakable(trimmed))
        guard !parts.isEmpty else { return }
        do {
            // Pipeline synthesis with playback: the next sentence is synthesized
            // WHILE the current one plays. The old serial synth→play loop left a
            // dead gap equal to the neural synthesis time at every sentence
            // boundary, which is exactly what made the voice sound choppy.
            var pending = Task { [manager] in
                try await manager.synthesize(text: parts[0], voice: Self.voiceName, speed: 1.05)
            }
            for i in parts.indices {
                let wav = try await pending.value
                if i + 1 < parts.count {
                    let next = parts[i + 1]
                    pending = Task { [manager] in
                        try await manager.synthesize(text: next, voice: Self.voiceName, speed: 1.05)
                    }
                }
                try await player.play(data: wav)
            }
        } catch {
            // stay silent — text is already on screen
        }
    }

    /// Rewrite text so the voice reads it naturally: a multiplication "x" between
    /// numbers (interval notation like "4x400") is otherwise pronounced as the
    /// letter "ex" by the synthesizer, so turn it into the spoken word "by".
    static func speakable(_ text: String) -> String {
        text.replacing(/(\d)\s*[xX×]\s*(\d)/) { match in "\(match.1) by \(match.2)" }
    }

    func stop() {
        player.stop()
    }

    // MARK: - Lewis style vector

    /// The engine's stock download carries only its default voice; Lewis ships
    /// in the app bundle as a raw [510x256] fp32 style vector and is copied
    /// into the model store the engine reads voice packs from.
    private static func installLewisStyleIfNeeded() throws {
        guard let src = Bundle.main.url(forResource: "bm_lewis", withExtension: "bin") else { return }
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let dir = appSupport.appendingPathComponent("fluidaudio/Models/kokoro-82m-coreml/ANE", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("bm_lewis.bin")
        if !FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.copyItem(at: src, to: dst)
        }
    }

    // MARK: - Chunking

    /// Split text into sentence groups short enough for one synthesis call.
    static func chunks(_ text: String, limit: Int = 220) -> [String] {
        var out: [String] = []
        var current = ""
        var sentence = ""
        for ch in text {
            sentence.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                if current.count + sentence.count > limit, !current.isEmpty {
                    out.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    current = ""
                }
                current += sentence
                sentence = ""
            }
        }
        current += sentence
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        // hard-split any oversized chunk on word boundaries
        return out.flatMap { chunk -> [String] in
            guard chunk.count > limit else { return [chunk] }
            var pieces: [String] = []
            var piece = ""
            for word in chunk.split(separator: " ") {
                if piece.count + word.count + 1 > limit, !piece.isEmpty {
                    pieces.append(piece)
                    piece = ""
                }
                piece += (piece.isEmpty ? "" : " ") + word
            }
            if !piece.isEmpty { pieces.append(piece) }
            return pieces
        }
    }
}
