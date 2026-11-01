//
//  GaitaCoach.swift
//  RunRightApp
//
//  "Gaita" — the AI running coach. Drives the validated RunCoachEngine with the
//  app's live run data and speaks cues through VoiceAssistantSpeaker
//  (ElevenLabs cloud voice with on-device fallback). Gives start cues, mile
//  markers with pace, pace coaching (when a target pace is set), motivation, and
//  a finish cue. Works on any run; can be toggled on/off.
//

import Foundation
import Combine

@MainActor
final class GaitaCoach: ObservableObject {
    static let shared = GaitaCoach()

    /// User toggle — persisted. Turning off silences Gaita immediately.
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            // shutdown (not just stop) so the audio session is deactivated and the
            // user's music/podcast un-ducks the moment they silence the coach.
            if !isEnabled {
                speaker.shutdown()
            } else if isRunning {
                // Re-arm after a mid-run toggle: shutdown() tore the speaker down,
                // so without this the coach goes silent (no more mile cues) until
                // the next run. prepare() brings it back so cues resume.
                speaker.prepare()
            }
        }
    }

    /// Per-cue mutes (persisted) so the runner can keep, say, mile markers but
    /// drop pace nagging. The engine still advances its state when a cue is muted,
    /// so mile tracking never desyncs.
    @Published var mileCuesEnabled: Bool {
        didSet { UserDefaults.standard.set(mileCuesEnabled, forKey: Self.mileKey) }
    }
    @Published var paceCuesEnabled: Bool {
        didSet { UserDefaults.standard.set(paceCuesEnabled, forKey: Self.paceKey) }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var lastSpoken: String?

    private static let enabledKey = "corsaCoachEnabled"
    private static let mileKey = "corsaCoachMileCues"
    private static let paceKey = "corsaCoachPaceCues"

    private let speaker = VoiceAssistantSpeaker()
    private var engine = RunCoachEngine()
    private var engineState = RunCoachEngineState()
    private var recent: [String] = []

    private var plannedRun = GaitaCoach.freeRun(target: nil)
    private let profile = GaitaCoach.defaultProfile()
    private let plan = GaitaCoach.defaultPlan()
    private var targetPace: Double?

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        mileCuesEnabled = UserDefaults.standard.object(forKey: Self.mileKey) as? Bool ?? true
        paceCuesEnabled = UserDefaults.standard.object(forKey: Self.paceKey) as? Bool ?? true
    }

    // MARK: - Lifecycle

    /// Begin coaching a run. Pass a target pace (sec/mile) for planned runs to
    /// enable on-pace / slow / fast coaching; nil for a free run (mile markers,
    /// pace notes, motivation only).
    func startRun(targetPaceSecPerMile: Double? = nil) {
        guard !isRunning else { return }
        engine = RunCoachEngine()
        engineState = RunCoachEngineState()
        recent = []
        targetPace = targetPaceSecPerMile
        plannedRun = GaitaCoach.freeRun(target: targetPaceSecPerMile)
        isRunning = true

        guard isEnabled else { return }
        speaker.prepare()
        // Immediate "starting out" cue.
        evaluate(LiveRunState(
            phase: .running, elapsedSeconds: 0, distanceMeters: 0,
            currentPaceSecPerMile: nil, rollingPaceSecPerMile: nil,
            targetPaceSecPerMile: targetPace
        ))
    }

    /// Feed a live update (call whenever distance / elapsed change).
    func update(distanceMeters: Double, elapsed: TimeInterval, paused: Bool, speedMetersPerSec: Double?) {
        guard isRunning, isEnabled else { return }
        let pace = Self.paceSecPerMile(fromSpeed: speedMetersPerSec)
        evaluate(LiveRunState(
            phase: paused ? .paused : .running,
            elapsedSeconds: elapsed,
            distanceMeters: distanceMeters,
            currentPaceSecPerMile: pace,
            rollingPaceSecPerMile: pace,
            targetPaceSecPerMile: targetPace
        ))
    }

    /// Speak the closing cue and end the session.
    func finishRun(distanceMeters: Double, elapsed: TimeInterval) {
        guard isRunning else { return }
        if isEnabled {
            evaluate(LiveRunState(
                phase: .finished, elapsedSeconds: elapsed, distanceMeters: distanceMeters,
                currentPaceSecPerMile: nil, rollingPaceSecPerMile: nil,
                targetPaceSecPerMile: targetPace
            ))
        }
        isRunning = false
    }

    /// End the session (called after the finish/discard screen). Lets any in-flight
    /// closing cue play out, then deactivates the audio session so the user's music
    /// un-ducks — without clipping the cue on a fast Save. Skips deactivation if a
    /// new run has already started.
    func stop() {
        isRunning = false
        speaker.finishThenDeactivate(keepActiveIf: { [weak self] in self?.isRunning ?? false })
    }

    // MARK: - Engine → speech

    private func evaluate(_ state: LiveRunState) {
        guard let decision = engine.evaluate(state: state, plannedRun: plannedRun, engineState: &engineState) else {
            return
        }

        // Per-cue mutes. The engine has already advanced (mile marked / prompt
        // recorded), so returning here just drops the spoken cue — mile tracking
        // stays in sync. Start / finish / GPS cues are never muted.
        if case .mileSplit = decision.trigger, !mileCuesEnabled { return }
        if case .categoryChange = decision.trigger, !paceCuesEnabled { return }

        let excluding = Set(recent.suffix(5))
        var text = VoiceAssistantMessageProvider.message(
            for: decision.category,
            profile: profile,
            plan: plan,
            run: plannedRun,
            mile: decision.mile,
            excluding: excluding
        ).text

        // Mile markers get a spoken pace note prepended. Pace is rounded to
        // 5 seconds so every possible sentence exists as a bundled voice clip.
        if case .mileSplit = decision.trigger, let mile = decision.mile {
            if let pace = state.rollingPaceSecPerMile ?? state.currentPaceSecPerMile {
                text = "Mile \(mile). \(Self.spokenPace(pace)) per mile. " + text
            } else {
                text = "Mile \(mile). " + text
            }
        }

        recent.append(text)
        if recent.count > 10 { recent.removeFirst(recent.count - 10) }
        lastSpoken = text
        speaker.speak(text)
    }

    // MARK: - Helpers

    /// Average speed (m/s) → pace (sec/mile); nil when essentially standing still.
    static func paceSecPerMile(fromSpeed speed: Double?) -> Double? {
        guard let speed, speed > 0.4 else { return nil }
        return LiveRunState.metersPerMile / speed
    }

    /// "8:45" — read naturally by TTS as "eight forty-five". Rounded to the
    /// nearest 5 seconds and clamped to 4:00–19:55 so the phrase always maps
    /// to a pre rendered voice clip.
    static func spokenPace(_ secPerMile: Double) -> String {
        var total = Int((secPerMile / 5).rounded()) * 5
        total = min(max(total, 4 * 60), 19 * 60 + 55)
        let m = total / 60
        let s = total % 60
        return "\(m):" + String(format: "%02d", s)
    }

    // MARK: - Session defaults (free run)

    static func freeRun(target: Double?) -> PlannedRun {
        PlannedRun(
            weekday: .monday,
            runType: .easy,
            title: "Run",
            detail: "",
            distanceLabel: "",
            targetPaceSecPerMile: target.map { Int($0.rounded()) }
        )
    }

    static func defaultProfile() -> OnboardingProfile {
        OnboardingProfile(
            runningGoal: .stayActive,
            experienceLevel: .someExperience,
            availableDays: [],
            weeklyMileage: .fiveToFifteen,
            name: "",
            age: 30,
            sex: "male"
        )
    }

    static func defaultPlan() -> WeeklyPlan {
        WeeklyPlan(
            focusTitle: "",
            focusDetail: "",
            totalMilesLabel: "",
            runs: [freeRun(target: nil)],
            notes: []
        )
    }
}
