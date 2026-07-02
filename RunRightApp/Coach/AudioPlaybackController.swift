//
//  AudioPlaybackController.swift
//  Weekly Plan
//

import AVFoundation

@MainActor
final class AudioPlaybackController: NSObject {
    private var player: AVAudioPlayer?
    private var finishContinuation: CheckedContinuation<Void, Error>?

    func play(data: Data) async throws {
        stop()
        _ = AudioSessionManager.activate()

        let audioPlayer = try AVAudioPlayer(data: data)
        audioPlayer.delegate = self
        audioPlayer.prepareToPlay()
        player = audioPlayer

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            finishContinuation = continuation
            guard audioPlayer.play() else {
                finishContinuation = nil
                continuation.resume(throwing: SpeechBackendError.playbackFailed)
                return
            }
        }
    }

    func play(fileURL: URL) async throws {
        stop()
        _ = AudioSessionManager.activate()

        let audioPlayer = try AVAudioPlayer(contentsOf: fileURL)
        audioPlayer.delegate = self
        audioPlayer.prepareToPlay()
        player = audioPlayer

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            finishContinuation = continuation
            guard audioPlayer.play() else {
                finishContinuation = nil
                continuation.resume(throwing: SpeechBackendError.playbackFailed)
                return
            }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        finishContinuation?.resume()
        finishContinuation = nil
    }

    var isPlaying: Bool {
        player?.isPlaying ?? false
    }
}

extension AudioPlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            finishContinuation?.resume()
            finishContinuation = nil
            self.player = nil
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            finishContinuation?.resume(throwing: error ?? SpeechBackendError.playbackFailed)
            finishContinuation = nil
            self.player = nil
        }
    }
}
