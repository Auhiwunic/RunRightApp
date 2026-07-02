//
//  UserSettingsRepository.swift
//  RunRightApp
//
//  Manages per-user settings: display name, daily/weekly goals, etc.
//  Stored in Firestore at users/{uid}/settings/profile

import Foundation
import FirebaseAuth
import FirebaseFirestore

struct UserSettings {
    var displayName: String = ""
    var dailyGoalMiles: Double = 3.0
    var weeklyGoalMiles: Double = 15.0
    var hasCompletedOnboarding: Bool = false
    // HR zone personalisation
    var age: Int = 30
    var sex: String = "male"          // "male" | "female" | "other"
    var fitnessLevel: String = "intermediate" // "beginner" | "intermediate" | "advanced" | "elite"
    var restingHeartRate: Int? = nil
    var consentRecord: ConsentRecord? = nil

    func toFirestore() -> [String: Any] {
        var dict: [String: Any] = [
            "displayName": displayName,
            "dailyGoalMiles": dailyGoalMiles,
            "weeklyGoalMiles": weeklyGoalMiles,
            "hasCompletedOnboarding": hasCompletedOnboarding,
            "age": age,
            "sex": sex,
            "fitnessLevel": fitnessLevel
        ]
        if let rhr = restingHeartRate { dict["restingHeartRate"] = rhr }
        if let consentRecord { dict["consents"] = consentRecord.firestorePayload }
        return dict
    }

    static func fromFirestore(_ data: [String: Any]) -> UserSettings {
        UserSettings(
            displayName: data["displayName"] as? String ?? "",
            dailyGoalMiles: data["dailyGoalMiles"] as? Double ?? 3.0,
            weeklyGoalMiles: data["weeklyGoalMiles"] as? Double ?? 15.0,
            hasCompletedOnboarding: data["hasCompletedOnboarding"] as? Bool ?? false,
            age: data["age"] as? Int ?? 30,
            sex: data["sex"] as? String ?? "male",
            fitnessLevel: data["fitnessLevel"] as? String ?? "intermediate",
            restingHeartRate: data["restingHeartRate"] as? Int,
            consentRecord: nil
        )
    }

    /// Apply this settings object to HeartRateZonesManager so zone cards stay live.
    func applyToHRZoneManager() {
        let sex: UserFitnessProfile.Sex = {
            switch self.sex.lowercased() {
            case "female": return .female
            case "other": return .other
            default: return .male
            }
        }()
        let level: UserFitnessProfile.FitnessLevel = {
            switch self.fitnessLevel.lowercased() {
            case "beginner": return .beginner
            case "advanced": return .advanced
            case "elite": return .elite
            default: return .intermediate
            }
        }()
        let profile = UserFitnessProfile(
            age: self.age,
            restingHeartRate: self.restingHeartRate,
            knownMaxHeartRate: nil,
            fitnessLevel: level,
            weight: nil,
            sex: sex
        )
        HeartRateZonesManager.shared.saveProfile(profile)
    }
}

final class UserSettingsRepository {
    static let shared = UserSettingsRepository()
    private init() {}

    private func settingsDoc(uid: String) -> DocumentReference {
        Firestore.firestore().collection("users").document(uid).collection("settings").document("profile")
    }

    func load(uid: String) async throws -> UserSettings {
        let doc = try await settingsDoc(uid: uid).getDocument()
        guard let data = doc.data() else { return UserSettings() }
        return UserSettings.fromFirestore(data)
    }

    func save(uid: String, settings: UserSettings) async throws {
        try await settingsDoc(uid: uid).setData(settings.toFirestore(), merge: true)
    }
}
