import Foundation
import FirebaseAuth
import FirebaseFirestore

final class PlanRepository {
    static let shared = PlanRepository()
    private init() {}

    private func plansCollection(uid: String) -> CollectionReference {
        Firestore.firestore().collection("users").document(uid).collection("plans")
    }

    // Week starts on Monday.
    func weekStart(for date: Date) -> Date {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: date) // 1=Sun...7=Sat

        // Convert to offset from Monday. Monday => 0 ... Sunday => 6
        let mondayBasedIndex: Int
        switch weekday {
        case 2: mondayBasedIndex = 0 // Monday
        case 3: mondayBasedIndex = 1 // Tuesday
        case 4: mondayBasedIndex = 2 // Wednesday
        case 5: mondayBasedIndex = 3 // Thursday
        case 6: mondayBasedIndex = 4 // Friday
        case 7: mondayBasedIndex = 5 // Saturday
        default: mondayBasedIndex = 6 // Sunday
        }

        let start = calendar.date(byAdding: .day, value: -mondayBasedIndex, to: date) ?? date
        return calendar.startOfDay(for: start)
    }

    func weekId(for date: Date = Date()) -> String {
        let start = weekStart(for: date)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: start)
    }

    func loadWeeklyPlan(uid: String, weekId: String) async throws -> [DayPlan]? {
        let doc = plansCollection(uid: uid).document(weekId)
        let snapshot = try await doc.getDocument()
        guard snapshot.exists, let data = snapshot.data() else { return nil }

        guard let daysData = data["days"] as? [[String: Any]] else { return nil }

        var days: [DayPlan] = []
        days.reserveCapacity(daysData.count)

        for dayDict in daysData {
            guard let dayName = dayDict["dayName"] as? String,
                  let runType = dayDict["runType"] as? String,
                  let isRest = dayDict["isRest"] as? Bool,
                  let totalDistance = dayDict["totalDistance"] as? String,
                  let targetPace = dayDict["targetPace"] as? String
            else { continue }

            let segments: [WorkoutSegment] = (dayDict["segments"] as? [[String: Any]] ?? []).compactMap { seg in
                guard let name = seg["name"] as? String,
                      let distance = seg["distance"] as? String,
                      let pace = seg["pace"] as? String
                else { return nil }
                return WorkoutSegment(name: name, distance: distance, pace: pace)
            }

            let zoneTargets: [ZoneTarget] = (dayDict["zoneTargets"] as? [[String: Any]] ?? []).compactMap { zone in
                guard let zoneName = zone["zoneName"] as? String,
                      let minutes = zone["minutes"] as? Int,
                      let colorHex = zone["colorHex"] as? String
                else { return nil }
                return ZoneTarget(zoneName: zoneName, minutes: minutes, colorHex: colorHex)
            }

            days.append(DayPlan(
                dayName: dayName,
                runType: runType,
                isRest: isRest,
                totalDistance: totalDistance,
                targetPace: targetPace,
                segments: segments,
                zoneTargets: zoneTargets
            ))
        }

        return days.isEmpty ? nil : days
    }

    func saveWeeklyPlan(uid: String, weekId: String, days: [DayPlan]) async throws {
        let weekStartData: Date = weekStart(for: Date())

        let dtoDays: [DayPlanDTO] = days.map { day in
            DayPlanDTO(
                dayName: day.dayName,
                runType: day.runType,
                isRest: day.isRest,
                totalDistance: day.totalDistance,
                targetPace: day.targetPace,
                segments: day.segments.map { WorkoutSegmentDTO(name: $0.name, distance: $0.distance, pace: $0.pace) },
                zoneTargets: day.zoneTargets.map { ZoneTargetDTO(zoneName: $0.zoneName, minutes: $0.minutes, colorHex: $0.colorHex) }
            )
        }

        let dto = WeeklyPlanDTO(weekId: weekId, weekStart: weekStartData, days: dtoDays)

        let doc = plansCollection(uid: uid).document(weekId)
        try await doc.setData(dto.toFirestore(), merge: true)
    }
}

