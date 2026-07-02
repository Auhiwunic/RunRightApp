import Foundation
import FirebaseFirestore

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

    func toFirestore() -> [String: Any] {
        var dict: [String: Any] = [
            "startTime": Timestamp(date: startTime),
            "distanceMeters": distanceMeters,
            "durationSeconds": durationSeconds,
            "avgSpeedMps": avgSpeedMps
        ]
        if let hr = avgHeartRateBpm {
            dict["avgHeartRateBpm"] = hr
        }
        return dict
    }

    static func fromFirestore(_ data: [String: Any], runId: String) -> RunSummaryDTO? {
        // Accept both Timestamp and Date for startTime
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

        let avgHeartRateBpm = data["avgHeartRateBpm"] as? Int
        return RunSummaryDTO(
            runId: runId,
            startTime: startTime,
            distanceMeters: distanceMeters,
            durationSeconds: durationSeconds,
            avgSpeedMps: avgSpeedMps,
            avgHeartRateBpm: avgHeartRateBpm
        )
    }
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

        return dict
    }
}
