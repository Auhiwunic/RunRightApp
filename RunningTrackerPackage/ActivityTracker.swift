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

// MARK: - Formatting Helpers

public struct ActivityFormatter {
    public static func formatDistance(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.2f km", meters / 1000) : String(format: "%.0f m", meters)
    }
    
    public static func formatElevation(_ meters: Double) -> String {
        String(format: "%.0f m", meters)
    }
    
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs)
                         : String(format: "%d:%02d", minutes, secs)
    }
    
    public static func formatSpeed(_ metersPerSecond: Double) -> String {
        String(format: "%.1f km/h", metersPerSecond * 3.6)
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
    
    public override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.activityType = .fitness
        locationManager.distanceFilter = 5
    }
    
    public func startTracking() {
        // Stop any existing tracking first
        locationManager.stopUpdatingLocation()
        
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
            return
        }
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            print("Location not authorized: \(status.rawValue)")
            return
        }
        
        // Clean state
        trackedLocations.removeAll()
        liveSummary = nil
        isPaused = false
        isTracking = true
        
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
        locationManager.stopUpdatingLocation()
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
        
        trackedLocations.append(contentsOf: recentLocations)
        
        if trackedLocations.count > 1 {
            liveSummary = ActivityCalculator.calculateActivitySummary(from: trackedLocations)
        }
    }
    
    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
    
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        if (status == .authorizedWhenInUse || status == .authorizedAlways) && isTracking {
            locationManager.startUpdatingLocation()
        }
    }
}

