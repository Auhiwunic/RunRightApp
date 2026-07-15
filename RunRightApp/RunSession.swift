//
//  RunSession.swift
//  RunRightApp
//
//  App-global run session so a run lives ABOVE any single tab/view. It owns the
//  shared ActivityTracker, the wall-clock elapsed timer, and the Gaita coach
//  feed — so GPS tracking AND voice cues keep running when the run screen is
//  minimized or the user switches tabs (and, with background location, when the
//  phone is locked). The active-run UI is presented from MainTabView driven by
//  `isPresented`, and a "running" banner offers to re-open it.
//

import Foundation
import Combine

@MainActor
final class RunSession: ObservableObject {
    static let shared = RunSession()

    /// A run is in progress (covers the live run AND the finish/save screen).
    @Published var isActive = false
    /// The full-screen run UI is currently shown. Toggling this minimizes/restores it.
    @Published var isPresented = false
    /// Wall-clock elapsed seconds (does not advance while paused).
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var shoeName: String = ""
    /// Per-mile splits live on the session (not the run view): minimizing the
    /// run UI destroys the view's @State, which used to wipe real splits and
    /// backfill them later as identical averages.
    @Published private(set) var mileSplits: [MileSplit] = []
    private var lastMileTime: TimeInterval = 0
    private let metersPerMile: Double = 1609.344

    /// Target pace (sec/mile) from today's plan — drives goal-based coaching. nil = free run.
    var targetPaceSecPerMile: Double?

    // MARK: - Inactivity auto-cancel
    // Auto-cancel only ever ENDS an ABANDONED run — an accidental start, or one
    // that never really got going (barely any distance). There is nothing to
    // lose by discarding it. A run that has covered real ground is LEFT ALONE:
    // GPS "no progress" cannot tell "stopped and forgot" from "running through a
    // tunnel", so auto-ending a real run would be far worse than letting it keep
    // tracking until the runner finishes it. Deliberately paused runs are also
    // left alone — a manual pause means the runner intends to come back.
    /// The inactivity warning + countdown is on screen (shown only if the run UI
    /// is open; we never force it open over another tab).
    @Published var inactivityPrompt = false
    /// Seconds left before the idle run auto-cancels (drives the countdown label).
    @Published var inactivityCountdown = 0
    /// Set true after an abandoned run was discarded, so a brief "run cancelled"
    /// note can appear. The consumer clears it.
    @Published var autoCancelledNotice = false

    /// Idle time (seconds) of no forward progress before the countdown appears.
    private let inactivityWarnAfter: TimeInterval = 150
    /// Length of the countdown shown before the run actually auto-cancels.
    private let inactivityCancelCountdown: TimeInterval = 30
    /// A run that never gets a GPS fix at all is ended after this long — the
    /// battery-saving backstop for a truly accidental start. Longer than the
    /// progress timeout so a slow first fix is never mistaken for inactivity.
    private let noGpsFixBackstop: TimeInterval = 300
    /// Forward progress (meters) that counts as "still moving" and resets the clock.
    private let progressEpsilonMeters: Double = 12
    /// Only a run under this much recorded distance can be auto-cancelled — above
    /// it the run has covered real ground and is never touched (0.05 mi).
    private let abandonedDistanceMeters: Double = 80
    private var lastProgressAt = Date()
    private var lastProgressDistance: Double = 0
    /// Guards against a second (already-queued) tick re-entering auto-cancel.
    private var autoCancelInProgress = false
    /// Set the instant finishTracking runs. A timer tick already queued at that
    /// moment (Timer.invalidate can't recall an in-flight fire) would otherwise
    /// re-enter evaluateInactivity/autoCancel and wipe the just-finished run.
    private var hasFinished = false

    let tracker = ActivityTracker.shared
    private let coach = GaitaCoach.shared

    private var timer: Timer?
    private var lastTick: Date?
    private var feed: AnyCancellable?
    private var ticksSinceCoachFeed = 0

    private init() {}

    // MARK: - Lifecycle

    /// Begin a run: reset + start GPS, start the coach, and begin feeding it.
    func start(shoe: String, targetPaceSecPerMile target: Double?) {
        shoeName = shoe
        targetPaceSecPerMile = target

        tracker.reset()
        tracker.startTracking()

        elapsed = 0
        mileSplits = []
        lastMileTime = 0
        lastTick = Date()
        resetInactivity()
        hasFinished = false
        isActive = true
        isPresented = true

        coach.startRun(targetPaceSecPerMile: target)
        startTimer()

        // Feed the coach on every GPS update so mile / pace / motivation cues fire
        // regardless of whether the run screen is on-screen (location updates keep
        // arriving in the background). Capture only Sendable primitives across the hop.
        feed = tracker.$liveSummary.sink { [weak self] summary in
            let distance = summary?.distance ?? 0
            let speed = summary?.averageSpeed
            Task { @MainActor in self?.feedCoach(distance: distance, speed: speed) }
        }
    }

    /// Hide the run UI but keep tracking + coaching (minimize, run stays live).
    func minimize() { isPresented = false }

    /// Re-open the run UI.
    func resume() { isPresented = true; noteActivity() }

    /// Stop the live run (user tapped Finish). Keeps the session active so the
    /// finish/save screen can stay up; call `dismissSession()` afterwards.
    private static var didAttemptRecovery = false

    /// Recover a run interrupted by a force-quit / crash / background-kill by saving
    /// it to history so it isn't silently lost. Runs at most once per launch, and
    /// never while a run is active (the live snapshot would be misread as one that
    /// was interrupted).
    static func recoverInterruptedRunIfNeeded(uid: String) async {
        guard !didAttemptRecovery, !shared.isActive else { return }
        didAttemptRecovery = true
        guard let recovered = ActivityTracker.recoverInterruptedRun() else { return }
        try? await RunRepository.shared.saveRunSummary(
            recovered.summary, shoeName: nil, route: recovered.route)
        NotificationCenter.default.post(name: .runSaved, object: nil)
    }

    func finishTracking() -> ActivitySummary? {
        hasFinished = true
        stopTimer()
        feed = nil
        clearInactivityPrompt()
        coach.finishRun(distanceMeters: tracker.liveSummary?.distance ?? 0, elapsed: elapsed)
        return tracker.stopTracking()
    }

    /// Fully end the session after save/discard — clears state so the banner hides.
    func dismissSession() {
        stopTimer()
        feed = nil
        // End the coach cleanly: this deactivates the audio session so the user's
        // music/podcast un-ducks now that the run is truly over (the closing cue
        // has already played by the time the finish screen is dismissed).
        coach.stop()
        tracker.reset()
        clearInactivityPrompt()
        isActive = false
        isPresented = false
    }

    // MARK: - Inactivity auto-cancel

    /// The runner tapped "I'm still running", paused/resumed, or reopened the run:
    /// treat any deliberate interaction as activity and reset the idle clock.
    func noteActivity() {
        lastProgressDistance = tracker.liveSummary?.distance ?? 0
        lastProgressAt = Date()
        clearInactivityPrompt()
    }

    private func resetInactivity() {
        lastProgressDistance = 0
        lastProgressAt = Date()
        autoCancelInProgress = false
        autoCancelledNotice = false
        clearInactivityPrompt()
    }

    private func clearInactivityPrompt() {
        inactivityPrompt = false
        inactivityCountdown = 0
    }

    /// Called each tick while a run is live and NOT paused. Resets the idle clock
    /// on real forward progress; otherwise, for an ABANDONED run only, counts down
    /// and discards it. A deliberately paused run never reaches here (see tick()).
    private func evaluateInactivity() {
        // Once auto-cancel has begun, an already-queued tick must not re-enter.
        guard !autoCancelInProgress else { return }

        let now = Date()

        // Before the first accepted GPS fix, "moving but GPS still acquiring" and
        // "stationary" look identical, so don't start the idle clock — a slow first
        // fix must never read as inactivity. A run that NEVER fixes (distance stays
        // nil) recorded nothing, so the longer no-fix backstop discards it.
        guard let distance = tracker.liveSummary?.distance else {
            lastProgressAt = now
            lastProgressDistance = 0
            // Measure against active elapsed time (which does not advance while
            // paused), so a run paused before its first fix is not cancelled for
            // time spent paused (#7).
            if elapsed >= noGpsFixBackstop {
                autoCancel()
            }
            return
        }

        // Real forward progress resets the idle clock.
        if distance - lastProgressDistance >= progressEpsilonMeters {
            lastProgressDistance = distance
            lastProgressAt = now
            clearInactivityPrompt()
            return
        }

        // A run that has covered real ground is never auto-cancelled — we can't
        // tell "stopped and forgot" from "GPS blackout while still running", and
        // ending a real run would be far worse than letting it keep tracking.
        guard distance < abandonedDistanceMeters else {
            clearInactivityPrompt()
            return
        }

        let idle = now.timeIntervalSince(lastProgressAt)
        let cancelAt = inactivityWarnAfter + inactivityCancelCountdown
        if idle >= cancelAt {
            autoCancel()
        } else if idle >= inactivityWarnAfter {
            // Only surface the prompt; never force the run UI open over another
            // tab. If the run screen is up the runner sees the countdown and can
            // tap "I'm still running"; if minimized it just discards (nothing lost).
            inactivityCountdown = max(1, Int((cancelAt - idle).rounded(.up)))
            inactivityPrompt = true
        }
    }

    /// Discard an abandoned run — nothing was worth saving, so end the session
    /// and post a brief note.
    private func autoCancel() {
        guard !autoCancelInProgress else { return }
        autoCancelInProgress = true
        clearInactivityPrompt()
        dismissSession()
        autoCancelledNotice = true
    }

    // MARK: - Internals

    private func feedCoach(distance: Double, speed: Double?) {
        guard isActive else { return }
        recordMileSplits(distance: distance)
        coach.update(
            distanceMeters: distance,
            elapsed: elapsed,
            paused: tracker.isPaused,
            speedMetersPerSec: speed
        )
    }

    private func recordMileSplits(distance: Double) {
        let currentMiles = distance / metersPerMile
        // One update can cross more than one mile boundary (GPS resume after
        // background, coarse updates). Record every crossed mile and split the
        // elapsed time evenly across the miles it covered.
        var crossed = Int(currentMiles) - mileSplits.count
        guard crossed > 0 else { return }
        while crossed > 0 {
            let splitTime = (elapsed - lastMileTime) / Double(crossed)
            mileSplits.append(MileSplit(time: splitTime))
            lastMileTime += splitTime
            crossed -= 1
        }
    }

    private func startTimer() {
        timer?.invalidate()
        lastTick = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard !hasFinished else { return }   // drop ticks queued before Finish
        let now = Date()
        if isActive, !tracker.isPaused, let last = lastTick {
            elapsed += now.timeIntervalSince(last)
        }
        lastTick = now

        // Idle detection only while actively tracking. A deliberately paused run
        // is left alone — the runner paused on purpose and means to come back, so
        // auto-cancelling it would throw away a run they still want.
        if isActive, !tracker.isPaused { evaluateInactivity() }

        // Feed the coach on a timer too, not only on GPS updates. When GPS never
        // fixes (indoors / no sky) `liveSummary` never emits again, so the "GPS is
        // weak" cue — which needs a re-evaluation ~30s after GPS goes quiet — could
        // never fire. ~every 2s is plenty; coach.update no-ops once the run ends.
        if isActive, !tracker.isPaused {
            ticksSinceCoachFeed += 1
            if ticksSinceCoachFeed >= 4 {
                ticksSinceCoachFeed = 0
                feedCoach(distance: tracker.liveSummary?.distance ?? 0,
                          speed: tracker.liveSummary?.averageSpeed)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
