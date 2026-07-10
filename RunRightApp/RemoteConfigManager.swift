//
//  RemoteConfigManager.swift
//  RunRightApp
//
//  Backend kill-switches via Firebase Remote Config. Bundled defaults mean the
//  app behaves correctly on first launch and fully offline, before any fetch
//  completes — so a missing network never disables features by accident.
//
//  Server keys (all optional; defaults below are used until fetched):
//    coach_enabled        Bool  — turn the AI coach off if its backend is down
//    scan_enabled         Bool  — turn the shoe scan off if its backend is down
//    min_supported_build  Int   — force-update gate (below this build = update)
//    maintenance_message  String— optional banner text ("" = no banner)
//

import Foundation
import FirebaseRemoteConfig

@MainActor
final class RemoteConfigManager: ObservableObject {
    static let shared = RemoteConfigManager()

    @Published private(set) var coachEnabled = true
    @Published private(set) var scanEnabled = true
    @Published private(set) var minSupportedBuild = 0
    @Published private(set) var maintenanceMessage = ""

    private let rc = RemoteConfig.remoteConfig()

    private init() {
        // Default scoring config = the shipped constants, encoded to JSON. Until a
        // server value arrives, the store already holds ScoringConfig.default, so
        // this default mainly documents the schema and keeps first-launch honest.
        let scoringDefault = (try? JSONEncoder().encode(ScoringConfig.default))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        rc.setDefaults([
            "coach_enabled": true as NSObject,
            "scan_enabled": true as NSObject,
            "min_supported_build": 0 as NSObject,
            "maintenance_message": "" as NSObject,
            "scoring_config": scoringDefault as NSObject
        ])
        let settings = RemoteConfigSettings()
        #if DEBUG
        settings.minimumFetchInterval = 0        // always fresh while developing
        #else
        settings.minimumFetchInterval = 1800     // at most every 30 min in production
        #endif
        rc.configSettings = settings
        apply()   // publish the bundled defaults immediately
    }

    /// Kick off a fetch. Call once at launch, after FirebaseApp.configure().
    func start() {
        rc.fetchAndActivate { [weak self] _, _ in
            Task { @MainActor in self?.apply() }
        }
    }

    private func apply() {
        coachEnabled = rc["coach_enabled"].boolValue
        scanEnabled = rc["scan_enabled"].boolValue
        minSupportedBuild = rc["min_supported_build"].numberValue.intValue
        maintenanceMessage = rc["maintenance_message"].stringValue

        // Live scoring calibration: decode the JSON blob and push it to the
        // engine's thread-safe store. A malformed / empty value leaves the last
        // good config in place (never crashes the pipeline over a typo).
        let json = rc["scoring_config"].stringValue
        if let data = json.data(using: .utf8), !data.isEmpty,
           let cfg = try? JSONDecoder().decode(ScoringConfig.self, from: data) {
            ScoringConfigStore.shared.update(cfg)
        }
    }

    /// True when this build is below the server-mandated minimum (force-update).
    var needsForcedUpdate: Bool {
        guard let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
              let current = Int(build) else { return false }
        return current < minSupportedBuild
    }
}
