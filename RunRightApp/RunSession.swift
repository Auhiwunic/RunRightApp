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

    let tracker = ActivityTracker.shared
    private let coach = GaitaCoach.shared

    private var timer: Timer?
    private var lastTick: Date?
    private var feed: AnyCancellable?

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

    /// Hide the run UI but keep tracking + coaching (Strava-style minimize).
    func minimize() { isPresented = false }

    /// Re-open the run UI.
    func resume() { isPresented = true }

    /// Stop the live run (user tapped Finish). Keeps the session active so the
    /// finish/save screen can stay up; call `dismissSession()` afterwards.
    func finishTracking() -> ActivitySummary? {
        stopTimer()
        feed = nil
        coach.finishRun(distanceMeters: tracker.liveSummary?.distance ?? 0, elapsed: elapsed)
        return tracker.stopTracking()
    }

    /// Fully end the session after save/discard — clears state so the banner hides.
    func dismissSession() {
        stopTimer()
        feed = nil
        tracker.reset()
        isActive = false
        isPresented = false
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
        let now = Date()
        if isActive, !tracker.isPaused, let last = lastTick {
            elapsed += now.timeIntervalSince(last)
        }
        lastTick = now
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
