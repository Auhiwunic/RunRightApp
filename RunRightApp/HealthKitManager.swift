//
//  HealthKitManager.swift
//  RunRightApp
//
//  Reads today's metrics from HealthKit and syncs HealthKit running
//  workouts into Firestore so they appear in stats and run history.

import Foundation
import HealthKit
import FirebaseAuth

@MainActor
final class HealthKitManager: ObservableObject {
    static let shared = HealthKitManager()

    private let store = HKHealthStore()

    // MARK: - Types
    private let stepType       = HKQuantityType(.stepCount)
    private let calorieType    = HKQuantityType(.activeEnergyBurned)
    private let distanceType   = HKQuantityType(.distanceWalkingRunning)
    private let heartRateType  = HKQuantityType(.heartRate)
    private let exerciseType   = HKQuantityType(.appleExerciseTime)
    private let workoutType    = HKObjectType.workoutType()

    /// Whether HealthKit is available on this device (not in Simulator).
    let isAvailable: Bool = HKHealthStore.isHealthDataAvailable()

    // MARK: - Published metrics
    @Published private(set) var stepsToday: Int?
    @Published private(set) var caloriesToday: Int?
    @Published private(set) var activeMinutesToday: Int?
    @Published private(set) var distanceTodayMiles: Double?

    private init() {}

    // MARK: - Authorization

    func requestAuthorization() async {
        guard isAvailable else { return }
        guard ConsentManager.shared.hasHealthDataConsent else { return }
        let readTypes: Set<HKObjectType> = [
            stepType, calorieType, distanceType, heartRateType, exerciseType, workoutType
        ]
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
        } catch {
            debugLog("[HealthKit] Auth failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Full sync (call on every app open)

    /// Fetches today's metrics AND syncs any new HealthKit running workouts into Firestore.
    func syncAll() async {
        guard isAvailable else { return }
        guard ConsentManager.shared.hasHealthDataConsent else { return }
        await requestAuthorization()
        async let s: () = fetchStepsToday()
        async let c: () = fetchCaloriesToday()
        async let d: () = fetchDistanceToday()
        async let m: () = fetchActiveMinutesToday()
        _ = await (s, c, d, m)

        // Sync HealthKit workouts to the user's private Firestore subtree only
        // for app functionality. Health data is never used for ads or mining.
        if let uid = Auth.auth().currentUser?.uid {
            await syncWorkoutsToFirestore(uid: uid)
        }
    }

    // MARK: - Step count

    func fetchStepsToday() async {
        guard isAvailable else { return }
        if let steps = await fetchCumulativeSum(type: stepType, unit: HKUnit.count()) {
            self.stepsToday = Int(steps)
        }
    }

    // MARK: - Calories

    func fetchCaloriesToday() async {
        guard isAvailable else { return }
        if let kcal = await fetchCumulativeSum(type: calorieType, unit: .kilocalorie()) {
            self.caloriesToday = Int(kcal)
        }
    }

    // MARK: - Distance

    func fetchDistanceToday() async {
        guard isAvailable else { return }
        if let meters = await fetchCumulativeSum(type: distanceType, unit: .meter()) {
            self.distanceTodayMiles = meters * 0.000621371
        }
    }

    // MARK: - Active minutes (Apple exercise time)

    func fetchActiveMinutesToday() async {
        guard isAvailable else { return }
        if let mins = await fetchCumulativeSum(type: exerciseType, unit: .minute()) {
            self.activeMinutesToday = Int(mins)
        }
    }

    // MARK: - Workout sync → Firestore

    /// Fetches running workouts from the last 60 days and saves any new ones to Firestore.
    func syncWorkoutsToFirestore(uid: String) async {
        guard isAvailable else { return }

        let since = Calendar.current.date(byAdding: .day, value: -60, to: Date()) ?? Date()
        let predicate = HKQuery.predicateForSamples(withStart: since, end: Date(), options: .strictStartDate)
        let workoutPredicate = HKQuery.predicateForWorkouts(with: .running)
        let compound = NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, workoutPredicate])

        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(compound)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: 100
        )

        do {
            let workouts = try await descriptor.result(for: store)
            guard !workouts.isEmpty else { return }

            // Fetch existing run start times from Firestore to avoid duplicates
            let existingTimes = await fetchExistingRunTimes(uid: uid, since: since)

            var savedAny = false
            for workout in workouts {
                let startTime = workout.startDate
                // Skip if we already have a run within 60 seconds of this workout's start
                let isDuplicate = existingTimes.contains { abs($0.timeIntervalSince(startTime)) < 60 }
                guard !isDuplicate else { continue }

                // Pull avg heart rate from workout statistics if available
                let avgHR: Int? = workout.statistics(for: heartRateType)
                    .flatMap { $0.averageQuantity() }
                    .map { Int($0.doubleValue(for: HKUnit(from: "count/min"))) }

                let dto = RunSummaryDTO(
                    runId: UUID().uuidString,
                    startTime: startTime,
                    distanceMeters: workout.totalDistance?.doubleValue(for: .meter()) ?? 0,
                    durationSeconds: workout.duration,
                    avgSpeedMps: {
                        let d = workout.totalDistance?.doubleValue(for: .meter()) ?? 0
                        return workout.duration > 0 ? d / workout.duration : 0
                    }(),
                    avgHeartRateBpm: avgHR,
                    shoeName: nil,
                    source: "healthkit"
                )

                try? await RunRepository.shared.saveRunDTO(dto, uid: uid)
                savedAny = true
            }

            // Refresh listeners only when something was actually written —
            // posting on every app open re-ran the whole Home/Profile reload
            // cascade even when all workouts were duplicates.
            if savedAny {
                NotificationCenter.default.post(name: .runSaved, object: nil)
            }
        } catch {
            debugLog("[HealthKit] Workout sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func fetchCumulativeSum(type: HKQuantityType, unit: HKUnit) async -> Double? {
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        let samplePredicate = HKSamplePredicate.quantitySample(type: type, predicate: predicate)
        let descriptor = HKStatisticsQueryDescriptor(predicate: samplePredicate, options: .cumulativeSum)
        do {
            let result = try await descriptor.result(for: store)
            return result?.sumQuantity()?.doubleValue(for: unit)
        } catch {
            return nil
        }
    }

    /// Returns the startTime of all runs saved in Firestore since `since` date.
    private func fetchExistingRunTimes(uid: String, since: Date) async -> [Date] {
        let runs = (try? await RunRepository.shared.fetchRunsSince(uid: uid, since: since)) ?? []
        return runs.map { $0.startTime }
    }
}
