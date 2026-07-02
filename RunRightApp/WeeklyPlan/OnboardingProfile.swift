//
//  OnboardingProfile.swift
//  Weekly Plan
//

import Foundation

struct OnboardingProfile {
    let runningGoal: RunningGoal
    let experienceLevel: ExperienceLevel
    let availableDays: Set<Int>
    let weeklyMileage: WeeklyMileageRange
    // Display name (collected in the first onboarding step).
    var name: String = ""
    // Heart-rate-zone personalisation (collected in the final onboarding step).
    var age: Int = 30
    var sex: String = "male"   // "male" | "female" | "other"
    // Explicit privacy/legal consent captured during onboarding.
    var consentRecord: ConsentRecord = ConsentRecord(
        healthDataConsentAt: Date(),
        backgroundLocationConsentAt: Date(),
        runningVideoConsentAt: Date(),
        ageGateConfirmedAt: Date(),
        dateOfBirth: Calendar.current.date(byAdding: .year, value: -18, to: Date()) ?? Date(),
        region: .other
    )
}
