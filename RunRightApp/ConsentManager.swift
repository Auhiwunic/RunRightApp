import Foundation

struct ConsentRecord: Codable, Equatable {
    let healthDataConsentAt: Date
    let backgroundLocationConsentAt: Date
    let runningVideoConsentAt: Date
    let ageGateConfirmedAt: Date
    let dateOfBirth: Date
    let region: AgeGateRegion

    var firestorePayload: [String: Any] {
        [
            "healthDataConsentAt": healthDataConsentAt,
            "backgroundLocationConsentAt": backgroundLocationConsentAt,
            "runningVideoConsentAt": runningVideoConsentAt,
            "ageGateConfirmedAt": ageGateConfirmedAt,
            "dateOfBirth": dateOfBirth,
            "region": region.rawValue
        ]
    }
}

enum AgeGateRegion: String, Codable, CaseIterable, Identifiable {
    case euOrUK = "eu_or_uk"
    case other = "other"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .euOrUK: return "EU / UK"
        case .other: return "Other"
        }
    }

    var minimumAge: Int {
        switch self {
        case .euOrUK: return 16
        case .other: return 13
        }
    }
}

final class ConsentManager {
    static let shared = ConsentManager()

    private let consentKey = "corsa.consentRecord.v1"

    private init() {}

    var currentRecord: ConsentRecord? {
        guard let data = UserDefaults.standard.data(forKey: consentKey) else { return nil }
        return try? JSONDecoder().decode(ConsentRecord.self, from: data)
    }

    var hasHealthDataConsent: Bool {
        currentRecord?.healthDataConsentAt != nil
    }

    func save(_ record: ConsentRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        UserDefaults.standard.set(data, forKey: consentKey)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: consentKey)
    }

    static func age(on date: Date, now: Date = Date()) -> Int {
        Calendar.current.dateComponents([.year], from: date, to: now).year ?? 0
    }
}
