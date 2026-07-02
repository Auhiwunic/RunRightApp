import Foundation
import FirebaseAuth
import SwiftUI
import Combine

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var stepsMinutesToday: Double = 0   // run minutes (kept for legacy callers)
    @Published var stepsToday: Int = 0             // real step count from HealthKit
    @Published var caloriesToday: Int = 0          // active kcal from HealthKit
    @Published var distanceTodayMiles: Double = 0  // walking+running distance from HealthKit
    @Published var activeMinutesToday: Int = 0     // Apple exercise minutes from HealthKit
    private let hk = HealthKitManager.shared
    @Published var lastRun: RunSummaryDTO?
    @Published var recentRuns: [RunSummaryDTO] = []
    @Published var loadError: String?

    // User display name
    @Published var displayName: String = "Runner"

    // Monthly stats
    @Published var monthlyRunCount: Int = 0
    @Published var monthlyMiles: Double = 0

    // Today's runs
    @Published var todaysRuns: [RunSummaryDTO] = []

    // All-time stats
    @Published var stats: RunRepository.RunStats = .init()

    // Today's plan (from weekly plan)
    @Published var todayPlan: DayPlanDTO?

    // Weekly miles (Mon=0 ... Sun=6)
    @Published var weeklyMiles: [Double] = Array(repeating: 0, count: 7)

    // Monthly run data: for each day of the month, total miles ran
    @Published var monthlyRunsByDay: [Int: Double] = [:]

    // Run streak (consecutive days with at least one run)
    @Published var runStreak: Int = 0

    // Goals
    @Published var weeklyGoalMiles: Double = 15.0
    @Published var dailyGoalMiles: Double = 3.0
    @Published var weeklyMilesTotal: Double = 0

    // User settings
    @Published var userSettings: UserSettings = .init()

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Reload all data whenever a run is saved
        NotificationCenter.default.publisher(for: .runSaved)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { [weak self] in
                    await self?.load()
                }
            }
            .store(in: &cancellables)
    }

    func load() async {
        guard let uid = Auth.auth().currentUser?.uid else {
            loadError = "Not signed in."
            return
        }

        loadError = nil

        // Pull latest HealthKit metrics (steps, calories, distance, active minutes)
        if let steps = hk.stepsToday    { self.stepsToday = steps }
        if let cal   = hk.caloriesToday { self.caloriesToday = cal }
        if let dist  = hk.distanceTodayMiles { self.distanceTodayMiles = dist }
        if let mins  = hk.activeMinutesToday { self.activeMinutesToday = mins }

        // Resolve display name
        if let user = Auth.auth().currentUser {
            if let name = user.displayName, !name.isEmpty {
                displayName = name.components(separatedBy: " ").first ?? name
            } else if let email = user.email, !email.isEmpty {
                displayName = String(email.prefix(while: { $0 != "@" }))
            } else {
                displayName = "Runner"
            }
        }

        // Fetch all data concurrently
        async let last = (try? await RunRepository.shared.fetchLastRun(uid: uid))
        async let runs = (try? await RunRepository.shared.fetchRuns(uid: uid, limit: 10))
        async let minutes = (try? await RunRepository.shared.fetchTotalDurationSecondsForDay(uid: uid, date: Date()))
        async let allRuns = (try? await RunRepository.shared.fetchAllRuns(uid: uid))
        async let todayRunsResult = (try? await RunRepository.shared.fetchRunsForDay(uid: uid, date: Date()))
        async let plan = loadTodayPlan(uid: uid)
        async let weekRuns = (try? await RunRepository.shared.fetchRunsForWeek(uid: uid, date: Date()))
        async let monthRuns = (try? await RunRepository.shared.fetchRunsForMonth(uid: uid, date: Date()))

        let (lastRun, runList, totalSeconds, allRunList, todayList, todayPlanResult, weekRunList, monthRunList) =
            await (last, runs, minutes, allRuns, todayRunsResult, plan, weekRuns, monthRuns)

        self.lastRun = lastRun
        self.recentRuns = runList ?? []
        self.stepsMinutesToday = (totalSeconds ?? 0) / 60.0
        self.todaysRuns = todayList ?? []
        self.todayPlan = todayPlanResult

        // Weekly miles
        self.weeklyMiles = RunRepository.weeklyMiles(from: weekRunList ?? [], weekOf: Date())

        // Monthly run data — group by day-of-month
        let calendar = Calendar.current
        var dayMap: [Int: Double] = [:]
        for run in (monthRunList ?? []) {
            let day = calendar.component(.day, from: run.startTime)
            dayMap[day, default: 0] += run.distanceMiles
        }
        self.monthlyRunsByDay = dayMap

        // Compute stats from all runs
        let allRunsFinal = allRunList ?? []
        self.stats = RunRepository.computeStats(from: allRunsFinal)
        self.monthlyRunCount = stats.monthlyRuns
        self.monthlyMiles = stats.monthlyMiles

        // Weekly miles total
        self.weeklyMilesTotal = self.weeklyMiles.reduce(0, +)

        // Compute run streak from all runs
        self.runStreak = Self.computeStreak(from: allRunsFinal)

        // Refresh all HealthKit metrics after Firestore data loads
        await hk.fetchStepsToday()
        await hk.fetchCaloriesToday()
        await hk.fetchDistanceToday()
        await hk.fetchActiveMinutesToday()
        if let steps = hk.stepsToday    { self.stepsToday = steps }
        if let cal   = hk.caloriesToday { self.caloriesToday = cal }
        if let dist  = hk.distanceTodayMiles { self.distanceTodayMiles = dist }
        if let mins  = hk.activeMinutesToday { self.activeMinutesToday = mins }

        // Load user settings (goals, onboarding state, HR profile)
        if let settings = try? await UserSettingsRepository.shared.load(uid: uid) {
            self.userSettings = settings
            self.dailyGoalMiles = settings.dailyGoalMiles
            self.weeklyGoalMiles = settings.weeklyGoalMiles
            // Override display name if user set one in onboarding
            if !settings.displayName.isEmpty {
                self.displayName = settings.displayName.components(separatedBy: " ").first ?? settings.displayName
            }
            // Push age/sex/fitness into HeartRateZonesManager so zone cards are live
            settings.applyToHRZoneManager()
        }
    }

    /// Computes consecutive days with at least one run, counting backwards from today
    static func computeStreak(from runs: [RunSummaryDTO]) -> Int {
        guard !runs.isEmpty else { return 0 }
        let calendar = Calendar.current
        // Build a set of unique run dates (day granularity)
        var runDays = Set<DateComponents>()
        for run in runs {
            let comps = calendar.dateComponents([.year, .month, .day], from: run.startTime)
            runDays.insert(comps)
        }

        var streak = 0
        var checkDate = Date()

        // Check today first — if no run today, start from yesterday
        let todayComps = calendar.dateComponents([.year, .month, .day], from: checkDate)
        if !runDays.contains(todayComps) {
            // No run today yet — check if yesterday had a run (streak still valid)
            checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate)!
        }

        // Count consecutive days backwards
        while true {
            let comps = calendar.dateComponents([.year, .month, .day], from: checkDate)
            if runDays.contains(comps) {
                streak += 1
                checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate)!
            } else {
                break
            }
        }
        return streak
    }

    private func loadTodayPlan(uid: String) async -> DayPlanDTO? {
        let weekId = PlanRepository.shared.weekId(for: Date())
        guard let days = try? await PlanRepository.shared.loadWeeklyPlan(uid: uid, weekId: weekId) else {
            return nil
        }

        // Map today's weekday to plan index (Mon=0 ... Sun=6)
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: Date()) // 1=Sun...7=Sat
        let mondayIndex: Int
        switch weekday {
        case 2: mondayIndex = 0
        case 3: mondayIndex = 1
        case 4: mondayIndex = 2
        case 5: mondayIndex = 3
        case 6: mondayIndex = 4
        case 7: mondayIndex = 5
        default: mondayIndex = 6 // Sunday
        }

        guard mondayIndex < days.count else { return nil }
        let dayPlan = days[mondayIndex]

        return DayPlanDTO(
            dayName: dayPlan.dayName,
            runType: dayPlan.runType,
            isRest: dayPlan.isRest,
            totalDistance: dayPlan.totalDistance,
            targetPace: dayPlan.targetPace,
            segments: dayPlan.segments.map { WorkoutSegmentDTO(name: $0.name, distance: $0.distance, pace: $0.pace) },
            zoneTargets: dayPlan.zoneTargets.map { ZoneTargetDTO(zoneName: $0.zoneName, minutes: $0.minutes, colorHex: $0.colorHex) }
        )
    }

    // MARK: - Formatters

    func pacePoints() -> [CGFloat] {
        let paces: [Double] = recentRuns.map { run in
            let speed = run.avgSpeedMps
            guard speed > 0 else { return 0 }
            let secondsPerKm = (1000.0 / speed)
            return secondsPerKm / 60.0
        }.filter { $0 > 0 }

        guard !paces.isEmpty else { return [] }
        let minPace = paces.min() ?? 0.0
        let maxPace = paces.max() ?? 1.0
        let span = max(1e-6, maxPace - minPace)

        return paces.map { pace in
            let t = (maxPace - pace) / span
            let point = 0.3 + 0.45 * t
            return CGFloat(max(0, min(1, point)))
        }
    }

    func heartRatePoints() -> [CGFloat] {
        let hrs: [Double] = recentRuns.compactMap { $0.avgHeartRateBpm }.map { Double($0) }
        guard hrs.count >= 2 else { return [] }

        let minHr = hrs.min() ?? 0
        let maxHr = hrs.max() ?? 1
        let span = max(1e-6, maxHr - minHr)

        return hrs.map { hr in
            let t = (hr - minHr) / span
            let point = 0.25 + 0.5 * t
            return CGFloat(max(0, min(1, point)))
        }
    }

    func formattedDistanceKm() -> String {
        guard let run = lastRun else { return "0.0" }
        return String(format: "%.1f", run.distanceMeters / 1000.0)
    }

    func formattedDistanceMiles() -> String {
        guard let run = lastRun else { return "0.0" }
        return String(format: "%.1f", run.distanceMiles)
    }

    func formattedDuration() -> String {
        guard let run = lastRun else { return "--:--" }
        let seconds = Int(run.durationSeconds)
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%d:%02d", mins, secs)
    }

    func formattedAvgPaceMinPerKm() -> String? {
        guard let run = lastRun else { return nil }
        let speed = run.avgSpeedMps
        guard speed > 0 else { return nil }
        let secondsPerKm = 1000.0 / speed
        let mins = Int(secondsPerKm) / 60
        let secs = Int(secondsPerKm) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    func formattedAvgHeartRate() -> String? {
        guard let run = lastRun, let hr = run.avgHeartRateBpm else { return nil }
        return "\(hr)"
    }

    func formattedLastRunTime() -> String {
        guard let run = lastRun else { return "" }
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(run.startTime) {
            formatter.dateFormat = "'Today,' h:mm a"
        } else if calendar.isDateInYesterday(run.startTime) {
            formatter.dateFormat = "'Yesterday,' h:mm a"
        } else {
            formatter.dateFormat = "MMM d, h:mm a"
        }
        return formatter.string(from: run.startTime)
    }
}
