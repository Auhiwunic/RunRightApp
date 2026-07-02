//
//  HeartRateZonesManager.swift
//  RunRightApp
//
//  Heart Rate Zone calculations and management
//

import Foundation
import SwiftUI

// MARK: - User Profile for Zone Calculation
struct UserFitnessProfile: Codable {
    var age: Int
    var restingHeartRate: Int?
    var knownMaxHeartRate: Int?
    var fitnessLevel: FitnessLevel
    var weight: Double? // kg
    var sex: Sex
    
    enum FitnessLevel: String, Codable, CaseIterable {
        case beginner = "Beginner"
        case intermediate = "Intermediate"
        case advanced = "Advanced"
        case elite = "Elite"
        
        var description: String {
            switch self {
            case .beginner: return "New to running (< 1 year)"
            case .intermediate: return "Regular runner (1-3 years)"
            case .advanced: return "Experienced (3-5 years)"
            case .elite: return "Competitive runner (5+ years)"
            }
        }
    }
    
    enum Sex: String, Codable, CaseIterable {
        case male = "Male"
        case female = "Female"
        case other = "Other"
    }
}

// MARK: - Heart Rate Zone
struct HeartRateZone: Identifiable {
    let id: Int
    let name: String
    let shortName: String
    let range: ClosedRange<Int>
    let percentRange: ClosedRange<Double>
    let color: Color
    let description: String
    let benefit: String
    
    static let zone1 = HeartRateZone(
        id: 1,
        name: "Recovery",
        shortName: "Z1",
        range: 0...0, // Calculated dynamically
        percentRange: 50...60,
        color: Color(hex: "#00CED1"),
        description: "Very easy, conversational pace",
        benefit: "Active recovery, fat burning"
    )
    
    static let zone2 = HeartRateZone(
        id: 2,
        name: "Aerobic",
        shortName: "Z2",
        range: 0...0,
        percentRange: 60...70,
        color: Color(hex: "#00FF7F"),
        description: "Easy, can hold conversation",
        benefit: "Build endurance, improve efficiency"
    )
    
    static let zone3 = HeartRateZone(
        id: 3,
        name: "Tempo",
        shortName: "Z3",
        range: 0...0,
        percentRange: 70...80,
        color: Color(hex: "#FFD700"),
        description: "Moderate, challenging to talk",
        benefit: "Increase aerobic capacity"
    )
    
    static let zone4 = HeartRateZone(
        id: 4,
        name: "Threshold",
        shortName: "Z4",
        range: 0...0,
        percentRange: 80...90,
        color: Color(hex: "#FF8C00"),
        description: "Hard, can only say few words",
        benefit: "Increase lactate threshold"
    )
    
    static let zone5 = HeartRateZone(
        id: 5,
        name: "Maximum",
        shortName: "Z5",
        range: 0...0,
        percentRange: 90...100,
        color: Color(hex: "#FF0000"),
        description: "All-out effort, can't speak",
        benefit: "Increase speed and power"
    )
}

// MARK: - Calculated Zones Result
struct CalculatedZones {
    let maxHeartRate: Int
    let restingHeartRate: Int
    let zones: [HeartRateZone]
    let estimatedVO2Max: Double?
    
    func currentZone(for heartRate: Int) -> HeartRateZone? {
        zones.first { $0.range.contains(heartRate) }
    }
    
    func zoneForPercentage(_ percent: Double) -> HeartRateZone? {
        zones.first { $0.percentRange.contains(percent) }
    }
}

// MARK: - Heart Rate Zones Manager
class HeartRateZonesManager: ObservableObject {
    static let shared = HeartRateZonesManager()
    
    @Published var userProfile: UserFitnessProfile?
    @Published var calculatedZones: CalculatedZones?
    @Published var isOnboardingComplete: Bool = false
    
    private let userDefaultsKey = "userFitnessProfile"
    
    private init() {
        loadProfile()
    }
    
    // MARK: - Max Heart Rate Calculation
    
    /// Standard formula: 220 - age
    func calculateMaxHR_Standard(age: Int) -> Int {
        return 220 - age
    }
    
    /// Tanaka formula (more accurate for older adults): 208 - (0.7 × age)
    func calculateMaxHR_Tanaka(age: Int) -> Int {
        return Int(208 - (0.7 * Double(age)))
    }
    
    /// Gulati formula (for women): 206 - (0.88 × age)
    func calculateMaxHR_Gulati(age: Int) -> Int {
        return Int(206 - (0.88 * Double(age)))
    }
    
    /// Best estimate based on profile
    func estimateMaxHeartRate(for profile: UserFitnessProfile) -> Int {
        // If user knows their max HR, use it
        if let knownMax = profile.knownMaxHeartRate {
            return knownMax
        }
        
        // Use appropriate formula based on sex
        switch profile.sex {
        case .female:
            return calculateMaxHR_Gulati(age: profile.age)
        case .male, .other:
            return calculateMaxHR_Tanaka(age: profile.age)
        }
    }
    
    // MARK: - Zone Calculation
    
    /// Calculate zones using Karvonen formula (Heart Rate Reserve method)
    /// More accurate when resting HR is known
    func calculateZones(for profile: UserFitnessProfile) -> CalculatedZones {
        let maxHR = estimateMaxHeartRate(for: profile)
        let restingHR = profile.restingHeartRate ?? estimateRestingHR(for: profile)
        let hrReserve = maxHR - restingHR
        
        // Karvonen formula: Target HR = ((Max HR − Resting HR) × %Intensity) + Resting HR
        func targetHR(percent: Double) -> Int {
            return Int(Double(hrReserve) * (percent / 100) + Double(restingHR))
        }
        
        let zones = [
            HeartRateZone(
                id: 1,
                name: "Recovery",
                shortName: "Z1",
                range: targetHR(percent: 50)...targetHR(percent: 60),
                percentRange: 50...60,
                color: Color(hex: "#00CED1"),
                description: "Very easy, conversational pace",
                benefit: "Active recovery, fat burning"
            ),
            HeartRateZone(
                id: 2,
                name: "Aerobic",
                shortName: "Z2",
                range: targetHR(percent: 60)...targetHR(percent: 70),
                percentRange: 60...70,
                color: Color(hex: "#00FF7F"),
                description: "Easy, can hold conversation",
                benefit: "Build endurance, improve efficiency"
            ),
            HeartRateZone(
                id: 3,
                name: "Tempo",
                shortName: "Z3",
                range: targetHR(percent: 70)...targetHR(percent: 80),
                percentRange: 70...80,
                color: Color(hex: "#FFD700"),
                description: "Moderate, challenging to talk",
                benefit: "Increase aerobic capacity"
            ),
            HeartRateZone(
                id: 4,
                name: "Threshold",
                shortName: "Z4",
                range: targetHR(percent: 80)...targetHR(percent: 90),
                percentRange: 80...90,
                color: Color(hex: "#FF8C00"),
                description: "Hard, can only say few words",
                benefit: "Increase lactate threshold"
            ),
            HeartRateZone(
                id: 5,
                name: "Maximum",
                shortName: "Z5",
                range: targetHR(percent: 90)...maxHR,
                percentRange: 90...100,
                color: Color(hex: "#FF0000"),
                description: "All-out effort, can't speak",
                benefit: "Increase speed and power"
            )
        ]
        
        // Estimate VO2 max based on resting HR and age
        let vo2Max = estimateVO2Max(restingHR: restingHR, age: profile.age, sex: profile.sex)
        
        return CalculatedZones(
            maxHeartRate: maxHR,
            restingHeartRate: restingHR,
            zones: zones,
            estimatedVO2Max: vo2Max
        )
    }
    
    // MARK: - Resting HR Estimation
    
    func estimateRestingHR(for profile: UserFitnessProfile) -> Int {
        // Average resting HR varies by fitness level
        switch profile.fitnessLevel {
        case .beginner:
            return profile.sex == .male ? 72 : 76
        case .intermediate:
            return profile.sex == .male ? 62 : 66
        case .advanced:
            return profile.sex == .male ? 55 : 60
        case .elite:
            return profile.sex == .male ? 48 : 52
        }
    }
    
    // MARK: - VO2 Max Estimation
    
    /// Estimate VO2 Max using the Uth–Sørensen–Overgaard–Pedersen formula
    /// VO2 max = 15.3 × (HRmax / HRrest)
    func estimateVO2Max(restingHR: Int, age: Int, sex: UserFitnessProfile.Sex) -> Double {
        let maxHR = sex == .female ? calculateMaxHR_Gulati(age: age) : calculateMaxHR_Tanaka(age: age)
        return 15.3 * (Double(maxHR) / Double(restingHR))
    }
    
    // MARK: - VO2 Max Fitness Rating
    
    func vo2MaxRating(vo2Max: Double, age: Int, sex: UserFitnessProfile.Sex) -> String {
        // Simplified rating based on age and sex
        let rating: String
        
        if sex == .female {
            if age < 30 {
                if vo2Max >= 45 { rating = "Excellent" }
                else if vo2Max >= 38 { rating = "Good" }
                else if vo2Max >= 31 { rating = "Average" }
                else { rating = "Below Average" }
            } else if age < 40 {
                if vo2Max >= 42 { rating = "Excellent" }
                else if vo2Max >= 35 { rating = "Good" }
                else if vo2Max >= 28 { rating = "Average" }
                else { rating = "Below Average" }
            } else {
                if vo2Max >= 38 { rating = "Excellent" }
                else if vo2Max >= 30 { rating = "Good" }
                else if vo2Max >= 24 { rating = "Average" }
                else { rating = "Below Average" }
            }
        } else {
            if age < 30 {
                if vo2Max >= 55 { rating = "Excellent" }
                else if vo2Max >= 46 { rating = "Good" }
                else if vo2Max >= 38 { rating = "Average" }
                else { rating = "Below Average" }
            } else if age < 40 {
                if vo2Max >= 52 { rating = "Excellent" }
                else if vo2Max >= 42 { rating = "Good" }
                else if vo2Max >= 35 { rating = "Average" }
                else { rating = "Below Average" }
            } else {
                if vo2Max >= 48 { rating = "Excellent" }
                else if vo2Max >= 38 { rating = "Good" }
                else if vo2Max >= 30 { rating = "Average" }
                else { rating = "Below Average" }
            }
        }
        
        return rating
    }
    
    // MARK: - Persistence
    
    func saveProfile(_ profile: UserFitnessProfile) {
        userProfile = profile
        calculatedZones = calculateZones(for: profile)
        isOnboardingComplete = true
        
        if let encoded = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }
    
    func loadProfile() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let profile = try? JSONDecoder().decode(UserFitnessProfile.self, from: data) else {
            return
        }
        
        userProfile = profile
        calculatedZones = calculateZones(for: profile)
        isOnboardingComplete = true
    }
    
    func resetProfile() {
        userProfile = nil
        calculatedZones = nil
        isOnboardingComplete = false
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}

