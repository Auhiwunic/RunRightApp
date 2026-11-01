//
//  ActivityTracker.swift
//  ActivityTrackerApp
//
//  Core GPS tracking algorithms converted from CubeTrek
//

import Foundation
import Combine
import CoreLocation

// MARK: - Data Models

public struct ElevationStats {
    public let gain: Double
    public let loss: Double
    public let highest: Double
    public let lowest: Double
}

public struct ActivitySummary {
    public let distance: Double
    public let duration: TimeInterval
    public let elevationGain: Double
    public let elevationLoss: Double
    public let highestPoint: Double
    public let lowestPoint: Double
    public let averageSpeed: Double
    public let maxSpeed: Double
    public let startTime: Date
    public let endTime: Date
    public let hasHeartRate: Bool
}

public enum ActivityType: String, CaseIterable {
    case unknown, run, hike, biking, skimountaineering, crosscountryski, mountaineering, snowshoeing, walking
    
    public static func detect(from sportString: String) -> ActivityType {
        let sport = sportString.trimmingCharacters(in: .whitespaces).lowercased()
        if sport.contains("cross_country_ski") { return .crosscountryski }
        if sport.contains("ski") { return .skimountaineering }
        if sport.contains("mountaineering") { return .mountaineering }
        if sport.contains("running") { return .run }
        if sport.contains("hiking") { return .hike }
        if sport.contains("cycling") { return .biking }
        if sport.contains("snowshoeing") { return .snowshoeing }
        if sport.contains("walk") { return .walking }
        return .unknown
    }
}

// MARK: - Core Calculation Functions

public struct ActivityCalculator {
    
    public static func calculateTotalDistance(from locations: [CLLocation]) -> Double {
        guard locations.count > 1 else { return 0 }
        var totalDistance: Double = 0
        for i in 1..<locations.count {
            totalDistance += locations[i].distance(from: locations[i-1])
        }
        return totalDistance
    }
    
    public static func calculateElevationStats(from locations: [CLLocation]) -> ElevationStats {
        guard let first = locations.first else {
            return ElevationStats(gain: 0, loss: 0, highest: 0, lowest: 0)
        }
        var gain: Double = 0
        var loss: Double = 0
        var highest = first.altitude
        var lowest = first.altitude
        
        for i in 1..<locations.count {
            let diff = locations[i].altitude - locations[i-1].altitude
            if diff > 0 { gain += diff } else { loss += abs(diff) }
            highest = max(highest, locations[i].altitude)
            lowest = min(lowest, locations[i].altitude)
        }
        return ElevationStats(gain: gain, loss: loss, highest: highest, lowest: lowest)
    }
    
    public static func calculateSpeedStats(from locations: [CLLocation]) -> (average: Double, max: Double) {
        guard locations.count > 1 else { return (0, 0) }
        var speeds: [Double] = []
        for i in 1..<locations.count {
            let timeDiff = locations[i].timestamp.timeIntervalSince(locations[i-1].timestamp)
            guard timeDiff > 0 && timeDiff < 3600 else { continue }
            let speed = locations[i].distance(from: locations[i-1]) / timeDiff
            if speed <= 50 { speeds.append(speed) }
        }
        guard !speeds.isEmpty else { return (0, 0) }
        let average = speeds.reduce(0, +) / Double(speeds.count)
        return (average, speeds.max() ?? 0)
    }
    
    public static func calculateActivitySummary(from locations: [CLLocation], hasHeartRate: Bool = false) -> ActivitySummary {
        guard locations.count > 1 else {
            return ActivitySummary(
                distance: 0,
                duration: 0,
                elevationGain: 0,
                elevationLoss: 0,
                highestPoint: locations.first?.altitude ?? 0,
                lowestPoint: locations.first?.altitude ?? 0,
                averageSpeed: 0,
                maxSpeed: 0,
                startTime: locations.first?.timestamp ?? Date(),
                endTime: locations.last?.timestamp ?? Date(),
                hasHeartRate: hasHeartRate
            )
        }
        let distance = calculateTotalDistance(from: locations)
        let elevation = calculateElevationStats(from: locations)
        let speeds = calculateSpeedStats(from: locations)
        let duration = locations.last!.timestamp.timeIntervalSince(locations.first!.timestamp)
        return ActivitySummary(
            distance: distance,
            duration: duration,
            elevationGain: elevation.gain,
            elevationLoss: elevation.loss,
            highestPoint: elevation.highest,
            lowestPoint: elevation.lowest,
            // Time-weighted (distance over time), not a per-segment mean — the
            // segment mean let short jittery segments dominate the average.
            averageSpeed: duration > 0 ? distance / duration : speeds.average,
            maxSpeed: speeds.max,
            startTime: locations.first!.timestamp,
            endTime: locations.last!.timestamp,
            hasHeartRate: hasHeartRate
        )
    }
    
    public static func filterValidLocations(_ locations: [CLLocation]) -> [CLLocation] {
        locations.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy < 100 }
    }
}

// MARK: - GPS Tracker

public class ActivityTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let locationManager = CLLocationManager()
    @Published public var trackedLocations: [CLLocation] = []
    @Published public var isTracking = false
    @Published public var isPaused = false
    @Published public var liveSummary: ActivitySummary?
    @Published public var finalSummary: ActivitySummary?
    /// Live Doppler-derived speed (m/s) from the most recent GPS fix — updated
    /// even when the fix is rejected for distance, so "current pace" honestly
    /// reads zero when the runner stops instead of drifting on jitter.
    @Published public var currentSpeedMps: Double = 0

    // MARK: - Fix acceptance thresholds
    /// Fixes worse than this are noise, not position (was 100m — indoor/urban
    /// garbage fixes got in and their drift was counted as running).
    private static let maxAccuracyMeters: Double = 30
    /// Below this Doppler speed the runner is standing still; GPS position may
    /// still wander, but that wander must never count as distance.
    private static let stationaryDopplerFloor: Double = 0.5
    /// When the last valid Doppler reading arrived (staleness cutoff above).
    private var lastDopplerAt = Date.distantPast

    /// Shared singleton so the run keeps tracking even if the Run tab's view is
    /// torn down (e.g. switching tabs). The CLLocationManager lives here, not in
    /// any view, so GPS + the coach survive view lifecycle changes.
    public static let shared = ActivityTracker()

    public override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .fitness
        // Deliver every fix. The old 5m filter could stop callbacks entirely when
        // the runner halts with a clean GPS lock, freezing the live speed at its
        // last moving value; the movement gate now does the noise filtering, and
        // GPS hardware is already on continuously so there is no battery cost.
        locationManager.distanceFilter = kCLDistanceFilterNone
        // Background updates are enabled ONLY while a run is active (see
        // startTracking/stopTracking), so the app never holds background-location
        // permission open when the user isn't running — cleaner for App Review.
        locationManager.allowsBackgroundLocationUpdates = false
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true
    }

    public func startTracking() {
        // Stop any existing tracking first
        locationManager.stopUpdatingLocation()
        // Scope background location to the active run only (requires the
        // "location" UIBackgroundMode, present in Info.plist).
        locationManager.allowsBackgroundLocationUpdates = true

        // Clean state up front. On a first install the authorization prompt is
        // still pending here; with isTracking already true the delegate below
        // starts GPS the moment the user grants it. Bailing out before setting
        // state recorded a zero-GPS first run.
        trackedLocations.removeAll()
        liveSummary = nil
        isPaused = false
        isTracking = true
        resetLiveAccumulators()

        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
            return   // locationManagerDidChangeAuthorization starts updates
        }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            debugLog("Location not authorized: \(status.rawValue)")
            return
        }

        ensureFullAccuracy()
        // Start fresh
        locationManager.startUpdatingLocation()
    }

    /// Run distance/pace need PRECISE GPS. If the user granted only Approximate
    /// location, every fix's accuracy exceeds the acceptance gate and the run
    /// silently records 0.00 mi — so ask for temporary full accuracy for the run.
    /// Requires NSLocationTemporaryUsageDescriptionDictionary["RunTracking"].
    private func ensureFullAccuracy() {
        if locationManager.accuracyAuthorization == .reducedAccuracy {
            locationManager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "RunTracking")
        }
    }
    
    public func stopTracking() -> ActivitySummary? {
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        isTracking = false
        isPaused = false
        currentSpeedMps = 0

        // Ending WHILE paused: fold the in-progress pause's wall-clock in so the
        // final active duration matches the live one (the pause hadn't been
        // accumulated yet — resumeTracking is what normally does it).
        if let s = pauseStartedAt {
            pausedAccumulated += Date().timeIntervalSince(s)
            pauseStartedAt = nil
        }

        let valid = ActivityCalculator.filterValidLocations(trackedLocations)
        guard valid.count > 1 else {
            liveSummary = nil
            return nil
        }
        // Build from the pause-aware accumulators (NOT a raw-trace recompute, which
        // re-added distance/time spent paused). Fall back only if unavailable.
        let summary = buildSummary() ?? ActivityCalculator.calculateActivitySummary(from: valid)
        finalSummary = summary
        liveSummary = nil
        return summary
    }
    
    public func reset() {
        trackedLocations.removeAll()
        liveSummary = nil
        finalSummary = nil
        isTracking = false
        isPaused = false
        currentSpeedMps = 0
        resetLiveAccumulators()
        clearCrashSnapshot()   // run saved or discarded — no recovery needed
        locationManager.stopUpdatingLocation()
    }

    // MARK: - Live accumulators
    // Recomputing the full summary over the whole trace on every GPS update was
    // O(n^2) across a run (a half marathon is ~4200 points x 3 full walks each
    // update). These carry the running totals instead.
    private var liveDistance: Double = 0
    private var liveGain: Double = 0
    private var liveLoss: Double = 0
    private var liveHighest: Double = -.greatestFiniteMagnitude
    private var liveLowest: Double = .greatestFiniteMagnitude
    private var liveMaxSpeed: Double = 0
    private var liveSpeedSum: Double = 0
    private var liveSpeedCount: Int = 0
    /// After a pause the previous point is stale by the whole pause duration, so
    /// the first post-resume update must re-anchor rather than fold the paused
    /// displacement into distance/speed (#6).
    private var resetAnchorOnNextUpdate = false
    /// Wall-clock time spent paused, summed across every pause, so duration and
    /// average pace reflect ACTIVE running only — the raw first→last fix span
    /// still includes each pause gap.
    private var pausedAccumulated: TimeInterval = 0
    private var pauseStartedAt: Date?

    private func resetLiveAccumulators() {
        liveDistance = 0; liveGain = 0; liveLoss = 0
        liveHighest = -.greatestFiniteMagnitude
        liveLowest = .greatestFiniteMagnitude
        liveMaxSpeed = 0; liveSpeedSum = 0; liveSpeedCount = 0
        resetAnchorOnNextUpdate = false
        pausedAccumulated = 0
        pauseStartedAt = nil
    }

    /// Single source of truth for a run summary, built from the pause-aware live
    /// accumulators. Both the live tick AND stopTracking use it, so the saved
    /// run can never diverge from what was shown live. (stopTracking used to
    /// recompute over the raw trace, re-adding paused travel + pause time.)
    private func buildSummary() -> ActivitySummary? {
        guard let first = trackedLocations.first, let last = trackedLocations.last else { return nil }
        let raw = last.timestamp.timeIntervalSince(first.timestamp)
        let duration = max(0, raw - pausedAccumulated)
        return ActivitySummary(
            distance: liveDistance,
            duration: duration,
            elevationGain: liveGain,
            elevationLoss: liveLoss,
            highestPoint: liveHighest,
            lowestPoint: liveLowest,
            averageSpeed: duration > 0 ? liveDistance / duration : 0,
            maxSpeed: liveMaxSpeed,
            startTime: first.timestamp,
            endTime: last.timestamp,
            hasHeartRate: false
        )
    }

    /// Fold newly accepted points into the running totals. Call BEFORE they are
    /// appended to trackedLocations (the previous point anchors the deltas).
    private func accumulate(_ newLocations: [CLLocation]) {
        var prev = trackedLocations.last
        if resetAnchorOnNextUpdate {
            // Re-anchor on the first post-resume point so travel during the pause
            // is not counted as distance run (#6).
            prev = nil
            resetAnchorOnNextUpdate = false
        }
        for loc in newLocations {
            if let p = prev {
                let d = loc.distance(from: p)
                liveDistance += d
                let diff = loc.altitude - p.altitude
                if diff > 0 { liveGain += diff } else { liveLoss += abs(diff) }
                let dt = loc.timestamp.timeIntervalSince(p.timestamp)
                if dt > 0 && dt < 3600 {
                    let speed = d / dt
                    if speed <= 50 {
                        liveSpeedSum += speed
                        liveSpeedCount += 1
                        liveMaxSpeed = max(liveMaxSpeed, speed)
                    }
                }
            }
            liveHighest = max(liveHighest, loc.altitude)
            liveLowest = min(liveLowest, loc.altitude)
            prev = loc
        }
    }
    
    // MARK: - Crash recovery
    // The active run is snapshotted to disk as it progresses so a force-quit,
    // crash, or OS background-kill mid-run doesn't silently lose it. The snapshot
    // is cleared when the run is saved or discarded (reset()), and recovered on
    // the next launch if it's still there.
    private struct RunCrashSnapshot: Codable {
        var distance: Double
        var duration: TimeInterval
        var elevationGain: Double
        var elevationLoss: Double
        var highestPoint: Double
        var lowestPoint: Double
        var averageSpeed: Double
        var maxSpeed: Double
        var startTime: Date
        var endTime: Date
        var route: [[Double]]   // [lat, lng] pairs
    }

    private static var crashFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("active_run_snapshot.json")
    }
    private var lastCrashPersistAt: Date = .distantPast

    /// Write a snapshot of the run in progress, throttled to keep disk churn low.
    private func persistCrashSnapshot() {
        guard isTracking, let s = buildSummary() else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCrashPersistAt) >= 8 else { return }
        lastCrashPersistAt = now
        let snap = RunCrashSnapshot(
            distance: s.distance, duration: s.duration,
            elevationGain: s.elevationGain, elevationLoss: s.elevationLoss,
            highestPoint: s.highestPoint, lowestPoint: s.lowestPoint,
            averageSpeed: s.averageSpeed, maxSpeed: s.maxSpeed,
            startTime: s.startTime, endTime: s.endTime,
            route: trackedLocations.map { [$0.coordinate.latitude, $0.coordinate.longitude] })
        if let data = try? JSONEncoder().encode(snap) {
            try? data.write(to: Self.crashFileURL, options: .atomic)
        }
    }

    /// Remove the snapshot — the run is now saved or deliberately discarded.
    func clearCrashSnapshot() {
        lastCrashPersistAt = .distantPast
        try? FileManager.default.removeItem(at: Self.crashFileURL)
    }

    /// If a prior run was interrupted (force-quit/crash), returns its summary +
    /// route for recovery, then clears the snapshot. Returns nil when there is
    /// none or the run was too short to be worth keeping.
    static func recoverInterruptedRun() -> (summary: ActivitySummary, route: [CLLocationCoordinate2D])? {
        let url = crashFileURL
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(RunCrashSnapshot.self, from: data),
              snap.distance >= 80 else {   // ignore trivial/abandoned runs (<80m)
            return nil
        }
        let summary = ActivitySummary(
            distance: snap.distance, duration: snap.duration,
            elevationGain: snap.elevationGain, elevationLoss: snap.elevationLoss,
            highestPoint: snap.highestPoint, lowestPoint: snap.lowestPoint,
            averageSpeed: snap.averageSpeed, maxSpeed: snap.maxSpeed,
            startTime: snap.startTime, endTime: snap.endTime, hasHeartRate: false)
        let route = snap.route.compactMap {
            $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil
        }
        return (summary, route)
    }

    public func pauseTracking() {
        guard isTracking && !isPaused else { return }
        isPaused = true
        pauseStartedAt = Date()
        currentSpeedMps = 0
        locationManager.stopUpdatingLocation()
    }

    public func resumeTracking() {
        guard isTracking && isPaused else { return }
        isPaused = false
        // Fold this pause's wall-clock into the paused total so it's excluded
        // from active duration / pace.
        if let s = pauseStartedAt {
            pausedAccumulated += Date().timeIntervalSince(s)
            pauseStartedAt = nil
        }
        resetAnchorOnNextUpdate = true   // don't count distance covered while paused (#6)
        locationManager.startUpdatingLocation()
    }
    
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isTracking && !isPaused else { return }

        // Live current speed straight from the newest fix's Doppler reading —
        // published even when the fix is rejected below, so the pace/zone UI
        // drops to zero the moment the runner stops. A reading is only trusted
        // for a few seconds: under bridges/trees Doppler goes invalid (-1) and
        // holding the old value forever would show a stale running pace.
        if let doppler = locations.last?.speed, doppler >= 0 {
            currentSpeedMps = doppler
            lastDopplerAt = Date()
        } else if currentSpeedMps != 0, Date().timeIntervalSince(lastDopplerAt) > 5 {
            currentSpeedMps = 0
        }

        // Only recent, reasonably accurate fixes. 100m acceptance let indoor and
        // urban-canyon garbage in; their drift read as a 7-minute pace while the
        // runner sat still.
        let recentLocations = locations.filter { location in
            let age = Date().timeIntervalSince(location.timestamp)
            return age < 10 && location.horizontalAccuracy > 0
                && location.horizontalAccuracy < Self.maxAccuracyMeters
        }
        guard !recentLocations.isEmpty else { return }

        // Movement gate: a fix only counts when it represents real travel, not
        // jitter. Doppler is the primary signal (independent of position noise);
        // without a valid Doppler reading, the displacement must exceed the two
        // fixes' combined uncertainty to be distinguishable from noise.
        var accepted: [CLLocation] = []
        var anchor: CLLocation? = resetAnchorOnNextUpdate ? nil : trackedLocations.last
        for loc in recentLocations {
            guard let a = anchor else {   // first fix of the run / after resume
                accepted.append(loc)
                anchor = loc
                continue
            }
            if Self.isRealMovement(from: a, to: loc) {
                accepted.append(loc)
                anchor = loc
            }
        }
        guard !accepted.isEmpty else { return }

        accumulate(accepted)
        trackedLocations.append(contentsOf: accepted)

        // Publish from the FIRST accepted fix (not the second): a stationary run
        // accepts exactly one anchor fix, and without a liveSummary the
        // inactivity logic can't show its countdown before auto-cancelling.
        liveSummary = buildSummary()
        persistCrashSnapshot()   // throttled to disk — survives a crash/force-quit
    }

    /// True when the step from `a` to `b` is real travel rather than GPS jitter.
    static func isRealMovement(from a: CLLocation, to b: CLLocation) -> Bool {
        // A valid Doppler reading near zero means standing still, no matter how
        // far the position wandered.
        if b.speed >= 0 && b.speed < stationaryDopplerFloor { return false }
        // Valid Doppler says moving — trust it.
        if b.speed >= stationaryDopplerFloor { return true }
        // No Doppler: fall back to displacement vs. the fixes' combined
        // uncertainty. Anything smaller is indistinguishable from noise.
        let noiseFloor = max(10, a.horizontalAccuracy + b.horizontalAccuracy)
        return b.distance(from: a) >= noiseFloor
    }
    
    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        debugLog("Location error: \(error.localizedDescription)")
    }
    
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if (status == .authorizedWhenInUse || status == .authorizedAlways) && isTracking {
            ensureFullAccuracy()   // precise GPS needed for distance/pace
            locationManager.startUpdatingLocation()
        }
    }
}
