//
//  LewisVoiceBackend.swift
//  RunRightApp
//
//  The coach's voice: pre rendered clips of every cue line, spoken by the
//  Kokoro-82M "Lewis" British male voice (Apache 2.0) and bundled in the app.
//  Rendering happened at build time on a dev machine, so the app ships ~6MB of
//  audio instead of a ~100MB synthesis model — fully offline, no inference,
//  full quality. Any sentence without a bundled clip falls through to the
//  system voice, so copy drift degrades gracefully instead of going silent.
//
//  Clips live in the bundled LewisVoice folder, named by a slug of the exact
//  sentence (see slug(_:)). Composite mile cues ("Mile 3. 8:45 per mile.
//  Steady.") are played as a short sequence of clips.
//

import Foundation

@MainActor
final class LewisVoiceBackend: SpeechBackend {
    let displayName = "Gaita coach"

    private let player: AudioPlaybackController
    private var stopped = false

    init(player: AudioPlaybackController) {
        self.player = player
    }

    /// True when the bundled clip folder is present (guards the composite chain).
    static var isAvailable: Bool {
        Bundle.main.url(forResource: "LewisVoice", withExtension: nil) != nil
    }

    func speak(_ text: String) async throws {
        stopped = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpeechBackendError.emptyText }

        guard let clips = Self.clipSequence(for: trimmed) else {
            throw SpeechBackendError.playbackFailed   // no clip — caller falls back
        }
        for url in clips {
            if stopped { return }
            try await player.play(fileURL: url)
        }
    }

    func stop() {
        stopped = true
        player.stop()
    }

    // MARK: - Text → clips

    /// Resolve a sentence to bundled clips: exact match first, then the
    /// composite mile pattern "Mile N.[ M:SS per mile.] Tail."
    static func clipSequence(for text: String) -> [URL]? {
        if let exact = clipURL(slug(text)) { return [exact] }

        guard let match = text.wholeMatch(of: /Mile (\d+)\.(?: (\d+):(\d{2}) per mile\.)? ?(.*)/) else {
            return nil
        }
        var urls: [URL] = []
        guard let mileClip = clipURL("mile_\(match.1)") else { return nil }
        urls.append(mileClip)
        if let m = match.2, let s = match.3 {
            guard let paceClip = clipURL("pace_\(m)_\(s)") else { return nil }
            urls.append(paceClip)
        }
        let tail = String(match.4).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty {
            guard let tailClip = clipURL(slug(tail)) else { return nil }
            urls.append(tailClip)
        }
        return urls
    }

    static func clipURL(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "m4a", subdirectory: "LewisVoice")
    }

    /// Deterministic filename slug for a sentence. Mirrored exactly by the
    /// generation script (tools/generate_lewis_voice.py) — change both or none.
    static func slug(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = ""
        var lastWasSep = true
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasSep = false
            } else if !lastWasSep {
                out.append("_")
                lastWasSep = true
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        return String(out.prefix(120))
    }
}
