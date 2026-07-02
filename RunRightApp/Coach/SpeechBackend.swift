//
//  SpeechBackend.swift
//  Weekly Plan
//

import Foundation

enum SpeechBackendError: LocalizedError {
    case emptyText
    case cloudNotConfigured
    case cloudRequestFailed(String)
    case playbackFailed
    case cacheWriteFailed

    var errorDescription: String? {
        switch self {
        case .emptyText: "Nothing to speak."
        case .cloudNotConfigured: "Cloud voice URL is not configured."
        case .cloudRequestFailed(let detail): "Cloud voice failed: \(detail)"
        case .playbackFailed: "Couldn't play audio."
        case .cacheWriteFailed: "Couldn't save voice cache."
        }
    }
}

@MainActor
protocol SpeechBackend: AnyObject {
    var displayName: String { get }
    func speak(_ text: String) async throws
    func stop()
}
