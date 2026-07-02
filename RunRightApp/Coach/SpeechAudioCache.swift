//
//  SpeechAudioCache.swift
//  Weekly Plan
//

import CryptoKit
import Foundation

enum SpeechAudioCache {
    private static let folderName = "CoachVoiceCache"

    static func cacheURL(for text: String, voice: String = CoachTTSConfig.cloudVoiceName) -> URL {
        cacheDirectory.appendingPathComponent("\(cacheKey(for: text, voice: voice)).mp3")
    }

    static func cachedFileURL(for text: String, voice: String = CoachTTSConfig.cloudVoiceName) -> URL? {
        let url = cacheURL(for: text, voice: voice)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    static func save(_ data: Data, for text: String, voice: String = CoachTTSConfig.cloudVoiceName) throws -> URL {
        let url = cacheURL(for: text, voice: voice)
        try ensureCacheDirectory()
        try data.write(to: url, options: .atomic)
        return url
    }

    static func cacheKey(for text: String, voice: String) -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let input = "\(voice)|\(normalized)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    private static func ensureCacheDirectory() throws {
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
    }
}
