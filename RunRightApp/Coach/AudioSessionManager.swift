//
//  AudioSessionManager.swift
//  Weekly Plan
//

import AVFoundation

enum AudioSessionManager {
    @discardableResult
    static func activate(showErrors: Bool = false) -> Bool {
        let session = AVAudioSession.sharedInstance()

        // Idempotent fast path: the player calls this before EVERY sentence and
        // every clip in a composite cue. Re-setting the category each time can
        // click and re-pump the music ducking between sentences — and mid-run it
        // would flip the Hey Gaita mic's .playAndRecord session to .playback.
        // If a playback-capable category is already configured, just stay active.
        if session.category == .playback || session.category == .playAndRecord {
            if (try? session.setActive(true)) != nil { return true }
        }

        let attempts: [() throws -> Void] = [
            {
                // Duck (lower) the user's music while Gaita speaks, then restore it.
                // .mixWithOthers keeps the music PLAYING (ducked) rather than
                // stopping it, so the runner can listen to music through the run.
                try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .mixWithOthers])
                try session.setActive(true)
            },
            {
                try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .mixWithOthers])
                try session.setActive(true)
            },
            {
                try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
                try session.setActive(true)
            },
        ]

        for attempt in attempts {
            do {
                try attempt()
                return true
            } catch {
                continue
            }
        }

        do {
            try session.setActive(true)
            return true
        } catch {
            return !showErrors
        }
    }

    static func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    static func observeInterruptions(onResume: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            guard
                let userInfo = notification.userInfo,
                let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: typeValue),
                type == .ended
            else { return }

            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                Task { @MainActor in
                    onResume()
                }
            }
        }
    }
}
