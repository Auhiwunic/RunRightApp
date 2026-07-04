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
        return ActivitySummary(
            distance: distance,
            duration: locations.last!.timestamp.timeIntervalSince(locations.first!.timestamp),
            elevationGain: elevation.gain,
            elevationLoss: elevation.loss,
            highestPoint: elevation.highest,
            lowestPoint: elevation.lowest,
            averageSpeed: speeds.average,
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

    /// Shared singleton so the run keeps tracking even if the Run tab's view is
    /// torn down (e.g. switching tabs). The CLLocationManager lives here, not in
    /// any view, so GPS + the coach survive view lifecycle changes.
    public static let shared = ActivityTracker()

    public override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .fitness
        locationManager.distanceFilter = 5
        // Keep tracking when the screen is locked / app is backgrounded (Strava-style).
        // Requires the "location" UIBackgroundMode (present in Info.plist).
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.showsBackgroundLocationIndicator = true
    }
    
    public func startTracking() {
        // Stop any existing tracking first
        locationManager.stopUpdatingLocation()

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

        // Start fresh
        locationManager.startUpdatingLocation()
    }
    
    public func stopTracking() -> ActivitySummary? {
        locationManager.stopUpdatingLocation()
        isTracking = false
        isPaused = false
        
        let valid = ActivityCalculator.filterValidLocations(trackedLocations)
        guard valid.count > 1 else {
            liveSummary = nil
            return nil
        }
        let summary = ActivityCalculator.calculateActivitySummary(from: valid)
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
        resetLiveAccumulators()
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

    private func resetLiveAccumulators() {
        liveDistance = 0; liveGain = 0; liveLoss = 0
        liveHighest = -.greatestFiniteMagnitude
        liveLowest = .greatestFiniteMagnitude
        liveMaxSpeed = 0; liveSpeedSum = 0; liveSpeedCount = 0
    }

    /// Fold newly accepted points into the running totals. Call BEFORE they are
    /// appended to trackedLocations (the previous point anchors the deltas).
    private func accumulate(_ newLocations: [CLLocation]) {
        var prev = trackedLocations.last
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
    
    public func pauseTracking() {
        guard isTracking && !isPaused else { return }
        isPaused = true
        locationManager.stopUpdatingLocation()
    }
    
    public func resumeTracking() {
        guard isTracking && isPaused else { return }
        isPaused = false
        locationManager.startUpdatingLocation()
    }
    
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isTracking && !isPaused else { return }
        
        // Filter: only accept recent locations (within last 10 seconds) to avoid stale cache
        let recentLocations = locations.filter { location in
            let age = Date().timeIntervalSince(location.timestamp)
            return age < 10 && location.horizontalAccuracy > 0 && location.horizontalAccuracy < 100
        }
        
        guard !recentLocations.isEmpty else { return }

        accumulate(recentLocations)
        trackedLocations.append(contentsOf: recentLocations)

        if trackedLocations.count > 1,
           let first = trackedLocations.first, let last = trackedLocations.last {
            liveSummary = ActivitySummary(
                distance: liveDistance,
                duration: last.timestamp.timeIntervalSince(first.timestamp),
                elevationGain: liveGain,
                elevationLoss: liveLoss,
                highestPoint: liveHighest,
                lowestPoint: liveLowest,
                averageSpeed: liveSpeedCount > 0 ? liveSpeedSum / Double(liveSpeedCount) : 0,
                maxSpeed: liveMaxSpeed,
                startTime: first.timestamp,
                endTime: last.timestamp,
                hasHeartRate: false
            )
        }
    }
    
    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        debugLog("Location error: \(error.localizedDescription)")
    }
    
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if (status == .authorizedWhenInUse || status == .authorizedAlways) && isTracking {
            locationManager.startUpdatingLocation()
        }
    }
}
