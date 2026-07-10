import Foundation
import FirebaseFirestore
import CoreLocation

// MARK: - Firestore DTOs
// Uses Codable where practical; retains toFirestore() for fields that need
// FieldValue sentinels (e.g. server timestamps).

struct RunSummaryDTO: Codable {
    let runId: String
    let startTime: Date
    let distanceMeters: Double
    let durationSeconds: TimeInterval
    let avgSpeedMps: Double
    let avgHeartRateBpm: Int?
    let shoeName: String?
    /// "app" = recorded in Gaita, "healthkit" = synced from Apple Health
    let source: String?
    /// Downsampled GPS path as [lat, lng] pairs (empty when no route was
    /// recorded, e.g. HealthKit imports or treadmill runs). [[Double]] keeps
    /// the DTO Codable; Firestore stores it as a GeoPoint array.
    let routeLatLng: [[Double]]

    init(runId: String, startTime: Date, distanceMeters: Double,
         durationSeconds: TimeInterval, avgSpeedMps: Double,
         avgHeartRateBpm: Int? = nil, shoeName: String? = nil,
         source: String? = "app", routeLatLng: [[Double]] = []) {
        self.runId = runId; self.startTime = startTime
        self.distanceMeters = distanceMeters; self.durationSeconds = durationSeconds
        self.avgSpeedMps = avgSpeedMps; self.avgHeartRateBpm = avgHeartRateBpm
        self.shoeName = shoeName; self.source = source
        self.routeLatLng = routeLatLng
    }

    /// The recorded path as map coordinates (empty if none).
    var routeCoordinates: [CLLocationCoordinate2D] {
        routeLatLng.compactMap {
            $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil
        }
    }

    /// Evenly thin a raw GPS track to at most `maxPoints`, keeping the
    /// endpoints, so a run's route stays small in Firestore (doc size + cost)
    /// while still drawing a faithful thumbnail.
    static func downsampleRoute(_ coords: [CLLocationCoordinate2D], maxPoints: Int = 150) -> [[Double]] {
        let valid = coords.filter { CLLocationCoordinate2DIsValid($0) }
        guard valid.count > maxPoints, maxPoints > 2 else {
            return valid.map { [$0.latitude, $0.longitude] }
        }
        let step = Double(valid.count - 1) / Double(maxPoints - 1)
        return (0..<maxPoints).map { i in
            let c = valid[Int((Double(i) * step).rounded())]
            return [c.latitude, c.longitude]
        }
    }

    func toFirestore() -> [String: Any] {
        var dict: [String: Any] = [
            "startTime": Timestamp(date: startTime),
            "distanceMeters": distanceMeters,
            "durationSeconds": durationSeconds,
            "avgSpeedMps": avgSpeedMps,
            "source": source ?? "app"
        ]
        if let hr = avgHeartRateBpm { dict["avgHeartRateBpm"] = hr }
        if let shoe = shoeName      { dict["shoeName"] = shoe }
        if !routeLatLng.isEmpty {
            dict["route"] = routeLatLng.map { GeoPoint(latitude: $0[0], longitude: $0[1]) }
        }
        return dict
    }

    static func fromFirestore(_ data: [String: Any], runId: String) -> RunSummaryDTO? {
        let startTime: Date
        if let ts = data["startTime"] as? Timestamp {
            startTime = ts.dateValue()
        } else if let d = data["startTime"] as? Date {
            startTime = d
        } else {
            return nil
        }

        guard let distanceMeters = data["distanceMeters"] as? Double,
              let durationSeconds = data["durationSeconds"] as? TimeInterval,
              let avgSpeedMps = data["avgSpeedMps"] as? Double
        else { return nil }

        let route = (data["route"] as? [GeoPoint])?.map { [$0.latitude, $0.longitude] } ?? []

        return RunSummaryDTO(
            runId: runId,
            startTime: startTime,
            distanceMeters: distanceMeters,
            durationSeconds: durationSeconds,
            avgSpeedMps: avgSpeedMps,
            avgHeartRateBpm: data["avgHeartRateBpm"] as? Int,
            shoeName: data["shoeName"] as? String,
            source: data["source"] as? String ?? "app",
            routeLatLng: route
        )
    }

    // Distance in miles
    var distanceMiles: Double { distanceMeters * 0.000621371 }
}

struct WorkoutSegmentDTO: Codable {
    var name: String
    var distance: String
    var pace: String
}

struct ZoneTargetDTO: Codable {
    var zoneName: String
    var minutes: Int
    var colorHex: String
}

struct DayPlanDTO: Codable {
    var dayName: String
    var runType: String
    var isRest: Bool
    var totalDistance: String
    var targetPace: String
    var segments: [WorkoutSegmentDTO]
    var zoneTargets: [ZoneTargetDTO]

    func toFirestore() -> [String: Any] {
        [
            "dayName": dayName,
            "runType": runType,
            "isRest": isRest,
            "totalDistance": totalDistance,
            "targetPace": targetPace,
            "segments": segments.map { ["name": $0.name, "distance": $0.distance, "pace": $0.pace] },
            "zoneTargets": zoneTargets.map { ["zoneName": $0.zoneName, "minutes": $0.minutes, "colorHex": $0.colorHex] as [String: Any] }
        ]
    }
}

struct WeeklyPlanDTO: Codable {
    var weekId: String
    var weekStart: Date

    var days: [DayPlanDTO]

    func toFirestore() -> [String: Any] {
        [
            "weekId": weekId,
            "weekStart": Timestamp(date: weekStart),
            "days": days.map { $0.toFirestore() }
        ]
    }
}

struct WearZonesDTO: Codable {
    // 10 biomechanical zones, each one: "green" | "yellow" | "orange" | "red"
    var bigToe: String
    var lesserToes: String
    var medialBall: String
    var centralBall: String
    var lateralBall: String
    var medialMidfoot: String
    var lateralMidfoot: String
    var medialHeel: String
    var centralHeel: String
    var lateralHeel: String

    func toFirestore() -> [String: Any] {
        [
            "bigToe": bigToe,
            "lesserToes": lesserToes,
            "medialBall": medialBall,
            "centralBall": centralBall,
            "lateralBall": lateralBall,
            "medialMidfoot": medialMidfoot,
            "lateralMidfoot": lateralMidfoot,
            "medialHeel": medialHeel,
            "centralHeel": centralHeel,
            "lateralHeel": lateralHeel
        ]
    }
}

struct ShoeScanDTO: Codable {
    var scanId: String
    var shoeName: String
    var side: String // "left" | "right"
    var createdAt: Date

    var wearZones: WearZonesDTO?
    var gaitType: String?
    var strikePattern: String?
    var primaryWearAreas: String?
    var gaitCause: String?
    var concern: String?
    var severity: String?

    var imageUrl: String?

    // Detailed fields from the gpt-5.6 scan upgrade (optional — older scans
    // predate them).
    var wearPercents: [String: Int]?
    var estimatedMilesRemaining: Int?
    var confidence: Int?
    var treadNote: String?

    func toFirestore() -> [String: Any] {
        var dict: [String: Any] = [
            "shoeName": shoeName,
            "side": side,
            "createdAt": Timestamp(date: createdAt)
        ]

        // Only write non-nil optional values — avoids storing NSNull in Firestore.
        if let gaitType { dict["gaitType"] = gaitType }
        if let strikePattern { dict["strikePattern"] = strikePattern }
        if let primaryWearAreas { dict["primaryWearAreas"] = primaryWearAreas }
        if let gaitCause { dict["gaitCause"] = gaitCause }
        if let concern { dict["concern"] = concern }
        if let severity { dict["severity"] = severity }
        if let imageUrl { dict["imageUrl"] = imageUrl }
        if let wearZones { dict["wearZones"] = wearZones.toFirestore() }
        if let wearPercents { dict["wearPercents"] = wearPercents }
        if let estimatedMilesRemaining { dict["estimatedMilesRemaining"] = estimatedMilesRemaining }
        if let confidence { dict["confidence"] = confidence }
        if let treadNote { dict["treadNote"] = treadNote }

        return dict
    }
}
