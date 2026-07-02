//
//  RunView.swift
//  RunRightApp
//
//  Dark dashboard theme matching HomeView

import SwiftUI
import Combine
import FirebaseAuth

struct RunView: View {
    // Shared singleton — survives Run-tab teardown so a run keeps tracking after a tab switch.
    @ObservedObject private var tracker = ActivityTracker.shared
    
    @State private var todaysRunEnabled = true
    @State private var selectedShoe = ""
    @State private var shoes: [String] = []
    @State private var showAddShoeAlert = false
    @State private var newShoeName = ""
    @State private var showPlanSheet = false
    @State private var showDiagnosticSheet = false
    @State private var weeklyPlans: [DayPlan] = DayPlan.defaultWeek()
    @State private var didLoadWeeklyPlans = false
    @State private var userVDOT: Double? = nil
    @State private var userGoal: RunGoal? = nil
    @State private var pastRuns: [PastRunItem] = []
    @State private var selectedPastRun: PastRunItem?
    @State private var scrollOffset: CGFloat = 0   // drives the header fade
    @State private var planError: String?

    private let accentLime = Color(hex: "#FF8C00")
    private let backgroundColor = Color(hex: "#1A1A1C")
    private let cardBackground = Color(hex: "#2A2A2E")
    private let cardBackgroundSoft = Color(hex: "#242428")
    
    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    ScrollOffsetReader(space: "runScroll")

                    // Header — fades out as the page scrolls down
                    runHeader
                        .opacity(scrollFadeOpacity(scrollOffset))
                        .padding(.horizontal, 20)
                        .padding(.top, 20)

                    // Map + START side by side
                    HStack(spacing: 12) {
                        mapCard
                        startButton
                    }
                    .frame(height: 200)
                    .padding(.horizontal, 20)

                    // Shoe (retro green — swipe to change)
                    shoeCard
                        .padding(.horizontal, 20)

                    // Today's Run card
                    todaysRunCard
                        .padding(.horizontal, 20)

                    // Edit weekly plan — subtle secondary action
                    Button(action: { showPlanSheet = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Edit weekly plan")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundColor(.white.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .padding(.horizontal, 20)

                    // Past runs — route screenshot + short stats
                    if !pastRuns.isEmpty {
                        pastRunsSection
                    }

                    // Last run summary (if available)
                    if let summary = tracker.finalSummary {
                        lastRunCard(summary: summary)
                            .padding(.horizontal, 20)

                        Button(action: { tracker.reset() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                Text("Clear Last Run")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundColor(.white.opacity(0.35))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                    }

                    // Heart-rate training zones (moved here from Home)
                    TrainingZonesCard()
                        .padding(.horizontal, 20)

                    // Training paces — kept simple, lives at the bottom
                    diagnosticRunCard
                        .padding(.horizontal, 20)

                    // Bottom padding for tab bar
                    Spacer().frame(height: AppTheme.tabBarHeight + 24)
                }
            }
            .coordinateSpace(name: "runScroll")
            .onPreferenceChange(ScrollOffsetKey.self) { scrollOffset = $0 }
        }
        .sheet(isPresented: $showPlanSheet) {
            WeeklyPlannerSheet(weeklyPlans: $weeklyPlans)
        }
        .sheet(isPresented: $showDiagnosticSheet) {
            DiagnosticRunSheet(
                userVDOT: $userVDOT,
                userGoal: $userGoal,
                weeklyPlans: $weeklyPlans
            )
        }
        .fullScreenCover(item: $selectedPastRun) { run in
            RunDetailView(run: run.detailDTO)
        }
        .task {
            await loadWeeklyPlansIfNeeded()
            await loadShoes()
            await loadPastRuns()
        }
        .alert("Add New Shoe", isPresented: $showAddShoeAlert) {
            TextField("e.g. Nike Pegasus 40", text: $newShoeName)
                .autocorrectionDisabled()
            Button("Add") {
                let name = newShoeName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                // ── Optimistic update — instant UI, no Firestore wait ──
                if !shoes.contains(name) { shoes.append(name) }
                selectedShoe = name
                newShoeName = ""
                // ── Persist to Firestore in background ────────────────
                Task {
                    guard let uid = Auth.auth().currentUser?.uid else { return }
                    try? await ScanRepository.shared.ensureShoeExists(uid: uid, shoeName: name)
                    await loadShoes()   // refresh ordering; keeps selectedShoe if present
                }
            }
            Button("Cancel", role: .cancel) { newShoeName = "" }
        } message: {
            Text("Enter a name for your shoe.")
        }
    }

    private func loadShoes() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let fetched = (try? await ScanRepository.shared.fetchShoeNames(uid: uid)) ?? []
        shoes = fetched
        if selectedShoe.isEmpty, let first = fetched.first {
            selectedShoe = first
        }
    }

    private func loadWeeklyPlansIfNeeded() async {
        guard !didLoadWeeklyPlans else { return }
        didLoadWeeklyPlans = true

        guard let uid = Auth.auth().currentUser?.uid else {
            planError = "Not signed in — can't load plan."
            return
        }
        let weekId = PlanRepository.shared.weekId(for: Date())
        do {
            // Only accept a full 7-day week — a partial array would crash the
            // weeklyPlans[todayDayIndex] subscript elsewhere.
            if let saved = try await PlanRepository.shared.loadWeeklyPlan(uid: uid, weekId: weekId),
               saved.count == 7 {
                weeklyPlans = saved
            }
            planError = nil
        } catch {
            planError = "Couldn't load weekly plan: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Run Control
    
    /// Parse a pace label like "7:30/mi" → seconds per mile. Returns nil for
    /// "varies", "—", "" or anything non-numeric (→ free run, no pace coaching).
    static func parsePaceSecPerMile(_ label: String?) -> Double? {
        guard let label else { return nil }
        let cleaned = label.lowercased()
            .replacingOccurrences(of: "/mi", with: "")
            .trimmingCharacters(in: .whitespaces)
        let parts = cleaned.split(separator: ":")
        guard parts.count == 2, let m = Int(parts[0]), let s = Int(parts[1]) else { return nil }
        let total = Double(m * 60 + s)
        return total > 0 ? total : nil
    }

    private func startRun() {
        // If a run is already in progress (minimized), just re-open it instead of restarting.
        if RunSession.shared.isActive {
            RunSession.shared.resume()
            return
        }
        // Goal-based coaching: feed today's planned target pace to Gaita (nil on rest / "varies").
        let plan = weeklyPlans.indices.contains(todayDayIndex) ? weeklyPlans[todayDayIndex] : nil
        let target = (plan?.isRest == true) ? nil : Self.parsePaceSecPerMile(plan?.targetPace)
        // The global run session owns tracking + elapsed + the coach feed, so the
        // run survives minimizing the screen and switching tabs.
        RunSession.shared.start(shoe: selectedShoe, targetPaceSecPerMile: target)
    }
    
    // MARK: - Header (fades out on scroll — no neon)
    private var runHeader: some View {
        HStack {
            Text("Start Running")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.white)
            Spacer()
        }
    }

    // MARK: - Map Card (flexible width — pairs with START)
    private var mapCard: some View {
        RouteMapView(
            coordinates: tracker.trackedLocations.map { $0.coordinate },
            isTracking: false
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cardBackground)
        .cornerRadius(20)
    }

    // MARK: - START button (tall, sits to the right of the map)
    private var startButton: some View {
        Button(action: startRun) {
            VStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 26, weight: .bold))
                Text("START")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
            }
            .foregroundColor(.black)
            .frame(width: 76)
            .frame(maxHeight: .infinity)
            .background(accentLime)
            .cornerRadius(20)
        }
    }

    // MARK: - Past Runs (route screenshot + short stats)
    private var pastRunsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("PAST RUNS")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Text("\(pastRuns.count)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(pastRuns) { run in
                        Button(action: { selectedPastRun = run }) {
                            PastRunCard(item: run)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func loadPastRuns() async {
        if let uid = Auth.auth().currentUser?.uid,
           let real = try? await RunRepository.shared.fetchRuns(uid: uid, limit: 10),
           !real.isEmpty {
            pastRuns = real.map { PastRunItem(dto: $0) }
        } else {
            // No signed-in runs yet — show sample runs so the feature is previewable.
            pastRuns = SampleRuns.items()
        }
    }


    // MARK: - Last Run Card
    private func lastRunCard(summary: ActivitySummary) -> some View {
        runCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("LAST RUN")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                
                HStack(spacing: 0) {
                    RunStatItem(
                        value: formatMiles(summary.distance),
                        label: "mi"
                    )
                    RunStatItem(
                        value: formatDuration(summary.duration),
                        label: "time"
                    )
                    RunStatItem(
                        value: formatPace(summary.averageSpeed),
                        label: "/mi"
                    )
                }
            }
        }
    }
    
    // MARK: - Shoe Card (retro green — swipe up/down to change shoe)
    private var shoeCard: some View {
        HStack(spacing: 12) {
            // Current shoe in big retro game type
            Text(selectedShoe.isEmpty ? "ADD SHOE" : selectedShoe.uppercased())
                .font(.system(size: 26, weight: .bold, design: .monospaced))
                .foregroundColor(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.45)

            Spacer(minLength: 8)

            // Swipe affordance (left/right) + add-new
            HStack(spacing: 14) {
                if shoes.count > 1 {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.black.opacity(0.55))
                }
                Button(action: { showAddShoeAlert = true }) {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundColor(.black)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .padding(.horizontal, 18)
        .background(accentLime)
        .cornerRadius(20)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 18)
                .onEnded { value in
                    if shoes.isEmpty {
                        showAddShoeAlert = true
                    } else {
                        // Swipe left = next, swipe right = previous.
                        cycleShoe(forward: value.translation.width < 0)
                    }
                }
        )
    }

    /// Cycles selectedShoe through the list. Swipe left = next, swipe right = previous; wraps around.
    private func cycleShoe(forward: Bool) {
        guard !shoes.isEmpty else { return }
        let current = shoes.firstIndex(of: selectedShoe) ?? 0
        let next = forward
            ? (current + 1) % shoes.count
            : (current - 1 + shoes.count) % shoes.count
        withAnimation(.easeInOut(duration: 0.15)) {
            selectedShoe = shoes[next]
        }
    }
    
    // MARK: - Diagnostic Run Card (one concise line)
    private var diagnosticRunCard: some View {
        Button(action: { showDiagnosticSheet = true }) {
            HStack {
                Text(userVDOT == nil
                     ? "Find your training paces"
                     : "VDOT \(String(format: "%.1f", userVDOT!))")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(16)
            .background(cardBackground)
            .cornerRadius(20)
        }
    }
    
    // MARK: - Today's Run Card
    
    /// Index into weeklyPlans for today's day-of-week (0=Mon … 6=Sun)
    private var todayDayIndex: Int {
        let weekday = Calendar.current.component(.weekday, from: Date()) // 1=Sun, 2=Mon … 7=Sat
        // Map to Mon=0 … Sun=6
        switch weekday {
        case 2: return 0  // Monday
        case 3: return 1  // Tuesday
        case 4: return 2  // Wednesday
        case 5: return 3  // Thursday
        case 6: return 4  // Friday
        case 7: return 5  // Saturday
        default: return 6 // Sunday
        }
    }
    
    private var todaysRunCard: some View {
        let todayPlan = weeklyPlans[todayDayIndex]
        // Run type as the title — no redundant "Today's Run" / doubled "RUN".
        let title = todayPlan.isRest ? "Rest Day" : todayPlan.runType

        return VStack(alignment: .leading, spacing: 0) {
            ToggleRow(label: title, isOn: $todaysRunEnabled)

            if todaysRunEnabled {
                VStack(alignment: .leading, spacing: 18) {
                    if todayPlan.isRest {
                        Text("Recovery is part of training.")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.5))
                    } else {
                        // Distance + target — two clean stats, evenly spaced
                        HStack(spacing: 0) {
                            workoutStat(value: todayPlan.totalDistance, label: "Distance")
                            workoutStat(value: todayPlan.targetPace, label: "Target")
                        }

                        if !todayPlan.segments.isEmpty {
                            planSection(title: "Segments") {
                                ForEach(todayPlan.segments.indices, id: \.self) { i in
                                    HStack {
                                        Text(todayPlan.segments[i].name)
                                            .foregroundColor(.white)
                                        Spacer()
                                        Text("\(todayPlan.segments[i].distance) · \(todayPlan.segments[i].pace)")
                                            .foregroundColor(.white.opacity(0.5))
                                    }
                                    .font(.system(size: 13))
                                }
                            }
                        }

                        if !todayPlan.zoneTargets.isEmpty {
                            planSection(title: "Zones") {
                                ForEach(todayPlan.zoneTargets) { zone in
                                    HStack(spacing: 10) {
                                        Circle()
                                            .fill(Color(hex: zone.colorHex))
                                            .frame(width: 10, height: 10)
                                        Text(zone.zoneName)
                                            .foregroundColor(.white)
                                        Spacer()
                                        Text("\(zone.minutes) min")
                                            .foregroundColor(.white.opacity(0.5))
                                    }
                                    .font(.system(size: 13))
                                }
                            }
                        }
                    }
                }
                .padding(.top, 16)
                .transition(.opacity)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .cornerRadius(20)
        .animation(.easeInOut(duration: 0.25), value: todaysRunEnabled)
    }

    /// A labeled group of plan rows with consistent header styling.
    private func planSection<Content: View>(title: String, @ViewBuilder rows: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
            rows()
        }
    }

    private func workoutStat(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // MARK: - Card Wrapper
    private func runCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .cornerRadius(20)
        .shadow(color: Color.black.opacity(0.12), radius: 5, x: 0, y: 2)
    }
    
    // MARK: - Formatting
    private let metersPerMile: Double = 1609.344
    
    private func formatMiles(_ meters: Double) -> String {
        String(format: "%.2f", meters / metersPerMile)
    }
    
    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
    
    private func formatPace(_ speed: Double) -> String {
        guard speed > 0 else { return "--:--" }
        let secondsPerMile = metersPerMile / speed
        let mins = Int(secondsPerMile) / 60
        let secs = Int(secondsPerMile) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Run Stat Item
struct RunStatItem: View {
    let value: String
    let label: String
    private let accentLime = Color(hex: "#FF8C00")
    
    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
            
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Toggle Row
struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    private let accentLime = Color(hex: "#FF8C00")

    var body: some View {
        HStack {
            Text(label.uppercased())
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            
            Spacer()
            
            ZStack {
                Capsule()
                    .fill(isOn ? accentLime : Color(hex: "#333333"))
                    .frame(width: 50, height: 28)
                
                Circle()
                    .fill(isOn ? Color.black : Color.white)
                    .frame(width: 22, height: 22)
                    .offset(x: isOn ? 11 : -11)
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isOn.toggle()
                }
            }
        }
                                .padding(.vertical, 8)
                            }
                        }
                        
// MARK: - Workout Data Models
struct WorkoutSegment: Identifiable {
    let id = UUID()
    var name: String
    var distance: String
    var pace: String
}

struct ZoneTarget: Identifiable {
    let id = UUID()
    let zoneName: String
    let minutes: Int
    let colorHex: String
}

// MARK: - Day Plan Model
struct DayPlan: Identifiable {
    let id = UUID()
    var dayName: String           // "Monday", "Tuesday", etc.
    var runType: String           // "Easy", "Tempo", "Intervals", "Long Run", "Recovery", "Custom", "Rest"
    var isRest: Bool
    var totalDistance: String
    var targetPace: String
    var segments: [WorkoutSegment]
    var zoneTargets: [ZoneTarget]
    
    static func defaultWeek() -> [DayPlan] {
        [
            DayPlan(dayName: "Monday", runType: "Easy", isRest: false,
                    totalDistance: "3.0 mi", targetPace: "10:00/mi",
                    segments: [.init(name: "Warm Up", distance: "0.5 mi", pace: "10:30/mi"),
                               .init(name: "Easy Run", distance: "2.0 mi", pace: "10:00/mi"),
                               .init(name: "Cool Down", distance: "0.5 mi", pace: "10:30/mi")],
                    zoneTargets: [.init(zoneName: "Zone 2", minutes: 30, colorHex: "#5ECC3A")]),
            DayPlan(dayName: "Tuesday", runType: "Tempo", isRest: false,
                    totalDistance: "5.0 mi", targetPace: "7:30/mi",
                    segments: [.init(name: "Warm Up", distance: "1.0 mi", pace: "9:30/mi"),
                               .init(name: "Tempo", distance: "3.0 mi", pace: "7:15/mi"),
                               .init(name: "Cool Down", distance: "1.0 mi", pace: "9:30/mi")],
                    zoneTargets: [.init(zoneName: "Zone 2", minutes: 10, colorHex: "#5ECC3A"),
                                  .init(zoneName: "Zone 4", minutes: 22, colorHex: "#E89830"),
                                  .init(zoneName: "Zone 2", minutes: 6, colorHex: "#5ECC3A")]),
            DayPlan(dayName: "Wednesday", runType: "Rest", isRest: true,
                    totalDistance: "—", targetPace: "—", segments: [], zoneTargets: []),
            DayPlan(dayName: "Thursday", runType: "Intervals", isRest: false,
                    totalDistance: "4.0 mi", targetPace: "varies",
                    segments: [.init(name: "Warm Up", distance: "0.5 mi", pace: "9:30/mi"),
                               .init(name: "800m Hard", distance: "0.5 mi", pace: "6:30/mi"),
                               .init(name: "400m Jog", distance: "0.25 mi", pace: "10:00/mi"),
                               .init(name: "800m Hard", distance: "0.5 mi", pace: "6:30/mi"),
                               .init(name: "400m Jog", distance: "0.25 mi", pace: "10:00/mi"),
                               .init(name: "800m Hard", distance: "0.5 mi", pace: "6:30/mi"),
                               .init(name: "Cool Down", distance: "0.5 mi", pace: "9:30/mi")],
                    zoneTargets: [.init(zoneName: "Zone 2", minutes: 8, colorHex: "#5ECC3A"),
                                  .init(zoneName: "Zone 5", minutes: 18, colorHex: "#E83030"),
                                  .init(zoneName: "Zone 2", minutes: 6, colorHex: "#5ECC3A")]),
            DayPlan(dayName: "Friday", runType: "Recovery", isRest: false,
                    totalDistance: "2.0 mi", targetPace: "11:00/mi",
                    segments: [.init(name: "Easy Jog", distance: "2.0 mi", pace: "11:00/mi")],
                    zoneTargets: [.init(zoneName: "Zone 1", minutes: 22, colorHex: "#00CED1")]),
            DayPlan(dayName: "Saturday", runType: "Long Run", isRest: false,
                    totalDistance: "8.0 mi", targetPace: "9:00/mi",
                    segments: [.init(name: "Warm Up", distance: "1.0 mi", pace: "9:45/mi"),
                               .init(name: "Steady", distance: "6.0 mi", pace: "9:00/mi"),
                               .init(name: "Cool Down", distance: "1.0 mi", pace: "9:45/mi")],
                    zoneTargets: [.init(zoneName: "Zone 2", minutes: 72, colorHex: "#5ECC3A")]),
            DayPlan(dayName: "Sunday", runType: "Rest", isRest: true,
                    totalDistance: "—", targetPace: "—", segments: [], zoneTargets: [])
        ]
    }
}

// MARK: - Weekly Planner Sheet
struct WeeklyPlannerSheet: View {
    @Binding var weeklyPlans: [DayPlan]
    @Environment(\.dismiss) var dismiss
    @State private var expandedDay: Int? = nil
    @State private var saveError: String?
    
    private let accentLime = Color(hex: "#FF8C00")
    private let backgroundColor = Color(hex: "#1A1A1C")
    private let cardBackground = Color(hex: "#2A2A2E")
    private let cardBackgroundSoft = Color(hex: "#242428")
    
    private let runTypes = ["Easy", "Tempo", "Intervals", "Long Run", "Recovery", "Rest"]
    
    private let distanceOptions = [
        "1.0 mi", "1.5 mi", "2.0 mi", "2.5 mi", "3.0 mi", "3.5 mi", "4.0 mi", "4.5 mi",
        "5.0 mi", "6.0 mi", "7.0 mi", "8.0 mi", "10.0 mi", "12.0 mi", "14.0 mi", "16.0 mi", "18.0 mi", "20.0 mi"
    ]
    
    private let paceOptions = [
        "6:00/mi", "6:15/mi", "6:30/mi", "6:45/mi", "7:00/mi", "7:15/mi", "7:30/mi", "7:45/mi",
        "8:00/mi", "8:15/mi", "8:30/mi", "8:45/mi", "9:00/mi", "9:15/mi", "9:30/mi", "9:45/mi",
        "10:00/mi", "10:15/mi", "10:30/mi", "10:45/mi", "11:00/mi", "11:30/mi", "12:00/mi", "varies"
    ]
    
    private let segmentNameOptions = [
        "Warm Up", "Cool Down", "Easy Run", "Tempo", "Steady", "Easy Jog",
        "800m Hard", "400m Jog", "1000m Hard", "Mile Repeat", "Sprint",
        "Marathon Pace", "Threshold", "Recovery Jog", "Fartlek", "Hills"
    ]
    
    private let segmentDistanceOptions = [
        "0.25 mi", "0.5 mi", "0.62 mi", "0.75 mi", "1.0 mi", "1.5 mi",
        "2.0 mi", "2.5 mi", "3.0 mi", "4.0 mi", "5.0 mi", "6.0 mi", "8.0 mi", "10.0 mi"
    ]
    
    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    
                    Spacer()
                    
                    Text("Weekly Plan")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                    
                    Spacer()
                    
                    Button(action: {
                        Task {
                            guard let uid = Auth.auth().currentUser?.uid else {
                                saveError = "Not signed in — can't save plan."
                                dismiss()
                                return
                            }
                            let weekId = PlanRepository.shared.weekId(for: Date())
                            do {
                                try await PlanRepository.shared.saveWeeklyPlan(uid: uid, weekId: weekId, days: weeklyPlans)
                                saveError = nil
                            } catch {
                                saveError = "Failed to save plan: \(error.localizedDescription)"
                            }
                            await MainActor.run { dismiss() }
                        }
                    }) {
                        Text("Done")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(accentLime)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) {
                        ForEach(weeklyPlans.indices, id: \.self) { index in
                            dayRow(index: index)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
            }
        }
    }
    
    // MARK: - Day Row
    @ViewBuilder
    private func dayRow(index: Int) -> some View {
        let plan = weeklyPlans[index]
        let isExpanded = expandedDay == index
        
        VStack(alignment: .leading, spacing: 0) {
            // Collapsed row — always visible
            Button(action: {
                withAnimation(.easeInOut(duration: 0.25)) {
                    expandedDay = isExpanded ? nil : index
                }
            }) {
                                    HStack {
                    Text(plan.dayName)
                        .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                
                                        Spacer()
                                        
                    if plan.isRest {
                        Text("Rest")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.35))
                    } else {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(plan.runType)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(accentLime)
                            Text(plan.totalDistance)
                                            .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                                                .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.3))
                        .padding(.leading, 6)
                }
                .padding(.vertical, 14)
            }
            
            // Expanded editor
            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 1)
                    
                    // Run type picker
                    Text("RUN TYPE")
                        .font(.system(size: 10, weight: .semibold))
                                                                .foregroundColor(.white.opacity(0.3))
                        .tracking(1)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(runTypes, id: \.self) { type in
                                Button(action: {
                                    applyPreset(type: type, at: index)
                                }) {
                                    Text(type)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(plan.runType == type ? .black : .white.opacity(0.6))
                                                    .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(plan.runType == type ? accentLime : cardBackgroundSoft)
                                        .cornerRadius(12)
                                }
                            }
                        }
                    }
                    
                    if !plan.isRest {
                        // Distance & Pace dropdowns
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Distance")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.3))
                                dropdownPicker(
                                    value: $weeklyPlans[index].totalDistance,
                                    options: distanceOptions
                                )
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Target Pace")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.3))
                                dropdownPicker(
                                    value: $weeklyPlans[index].targetPace,
                                    options: paceOptions
                                )
                            }
                        }
                        
                        // Segments
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                Text("SEGMENTS")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.3))
                                    .tracking(1)
                                        
                                        Spacer()
                                        
                                                Button(action: {
                                    weeklyPlans[index].segments.append(
                                        WorkoutSegment(name: "Warm Up", distance: "0.5 mi", pace: "9:00/mi")
                                    )
                                }) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundColor(accentLime)
                                }
                            }
                            
                            ForEach(weeklyPlans[index].segments.indices, id: \.self) { si in
                                HStack(spacing: 4) {
                                    // Segment name dropdown
                                    Menu {
                                        ForEach(segmentNameOptions, id: \.self) { name in
                                            Button(name) { weeklyPlans[index].segments[si].name = name }
                                        }
                                    } label: {
                                        Text(weeklyPlans[index].segments[si].name)
                                            .font(.system(size: 11, weight: .medium))
                                                                .foregroundColor(.white)
                                            .lineLimit(1)
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 7))
                                            .foregroundColor(.white.opacity(0.3))
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    
                                    // Segment distance dropdown
                                    Menu {
                                        ForEach(segmentDistanceOptions, id: \.self) { dist in
                                            Button(dist) { weeklyPlans[index].segments[si].distance = dist }
                                        }
                                    } label: {
                                        Text(weeklyPlans[index].segments[si].distance)
                                                                .font(.system(size: 11))
                                            .foregroundColor(.white.opacity(0.7))
                                    }
                                    .frame(width: 52, alignment: .trailing)
                                    
                                    // Segment pace dropdown
                                    Menu {
                                        ForEach(paceOptions, id: \.self) { pace in
                                            Button(pace) { weeklyPlans[index].segments[si].pace = pace }
                                        }
                                    } label: {
                                        Text(weeklyPlans[index].segments[si].pace)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.white.opacity(0.7))
                                    }
                                    .frame(width: 62, alignment: .trailing)
                                    
                                                Button(action: {
                                        weeklyPlans[index].segments.remove(at: si)
                                    }) {
                                        Image(systemName: "minus.circle")
                                            .font(.system(size: 14))
                                            .foregroundColor(Color(hex: "#E83030").opacity(0.6))
                                    }
                                }
                                .padding(8)
                                .background(cardBackgroundSoft)
                                                    .cornerRadius(8)
                            }
                        }
                        
                        // Zone targets display
                        if !plan.zoneTargets.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("ZONE TARGETS")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.3))
                                    .tracking(1)
                                
                                ForEach(plan.zoneTargets) { zone in
                                    HStack(spacing: 8) {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Color(hex: zone.colorHex))
                                            .frame(width: 12, height: 12)
                                        Text(zone.zoneName)
                                            .font(.system(size: 12, weight: .medium))
                                                                .foregroundColor(.white)
                                    Spacer()
                                        Text("\(zone.minutes) min")
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.5))
                                }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .background(cardBackground)
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 3)
    }
    
    // MARK: - Apply Preset
    private func applyPreset(type: String, at index: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if type == "Rest" {
                weeklyPlans[index].runType = "Rest"
                weeklyPlans[index].isRest = true
                weeklyPlans[index].totalDistance = "—"
                weeklyPlans[index].targetPace = "—"
                weeklyPlans[index].segments = []
                weeklyPlans[index].zoneTargets = []
                            } else {
                weeklyPlans[index].isRest = false
                weeklyPlans[index].runType = type
                switch type {
                case "Easy":
                    weeklyPlans[index].totalDistance = "3.0 mi"
                    weeklyPlans[index].targetPace = "10:00/mi"
                    weeklyPlans[index].segments = [
                        .init(name: "Warm Up", distance: "0.5 mi", pace: "10:30/mi"),
                        .init(name: "Easy Run", distance: "2.0 mi", pace: "10:00/mi"),
                        .init(name: "Cool Down", distance: "0.5 mi", pace: "10:30/mi")
                    ]
                    weeklyPlans[index].zoneTargets = [.init(zoneName: "Zone 2", minutes: 30, colorHex: "#5ECC3A")]
                case "Tempo":
                    weeklyPlans[index].totalDistance = "5.0 mi"
                    weeklyPlans[index].targetPace = "7:30/mi"
                    weeklyPlans[index].segments = [
                        .init(name: "Warm Up", distance: "1.0 mi", pace: "9:30/mi"),
                        .init(name: "Tempo", distance: "3.0 mi", pace: "7:15/mi"),
                        .init(name: "Cool Down", distance: "1.0 mi", pace: "9:30/mi")
                    ]
                    weeklyPlans[index].zoneTargets = [
                        .init(zoneName: "Zone 2", minutes: 10, colorHex: "#5ECC3A"),
                        .init(zoneName: "Zone 4", minutes: 22, colorHex: "#E89830"),
                        .init(zoneName: "Zone 2", minutes: 6, colorHex: "#5ECC3A")
                    ]
                case "Intervals":
                    weeklyPlans[index].totalDistance = "4.0 mi"
                    weeklyPlans[index].targetPace = "varies"
                    weeklyPlans[index].segments = [
                        .init(name: "Warm Up", distance: "0.5 mi", pace: "9:30/mi"),
                        .init(name: "800m Hard", distance: "0.5 mi", pace: "6:30/mi"),
                        .init(name: "400m Jog", distance: "0.25 mi", pace: "10:00/mi"),
                        .init(name: "800m Hard", distance: "0.5 mi", pace: "6:30/mi"),
                        .init(name: "400m Jog", distance: "0.25 mi", pace: "10:00/mi"),
                        .init(name: "800m Hard", distance: "0.5 mi", pace: "6:30/mi"),
                        .init(name: "Cool Down", distance: "0.5 mi", pace: "9:30/mi")
                    ]
                    weeklyPlans[index].zoneTargets = [
                        .init(zoneName: "Zone 2", minutes: 8, colorHex: "#5ECC3A"),
                        .init(zoneName: "Zone 5", minutes: 18, colorHex: "#E83030"),
                        .init(zoneName: "Zone 2", minutes: 6, colorHex: "#5ECC3A")
                    ]
                case "Long Run":
                    weeklyPlans[index].totalDistance = "8.0 mi"
                    weeklyPlans[index].targetPace = "9:00/mi"
                    weeklyPlans[index].segments = [
                        .init(name: "Warm Up", distance: "1.0 mi", pace: "9:45/mi"),
                        .init(name: "Steady", distance: "6.0 mi", pace: "9:00/mi"),
                        .init(name: "Cool Down", distance: "1.0 mi", pace: "9:45/mi")
                    ]
                    weeklyPlans[index].zoneTargets = [.init(zoneName: "Zone 2", minutes: 72, colorHex: "#5ECC3A")]
                case "Recovery":
                    weeklyPlans[index].totalDistance = "2.0 mi"
                    weeklyPlans[index].targetPace = "11:00/mi"
                    weeklyPlans[index].segments = [.init(name: "Easy Jog", distance: "2.0 mi", pace: "11:00/mi")]
                    weeklyPlans[index].zoneTargets = [.init(zoneName: "Zone 1", minutes: 22, colorHex: "#00CED1")]
                default: break
                }
            }
        }
    }
    
    // MARK: - Dropdown Picker Helper
    private func dropdownPicker(value: Binding<String>, options: [String]) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button(option) { value.wrappedValue = option }
            }
        } label: {
                                                    HStack {
                Text(value.wrappedValue)
                                                                .font(.system(size: 14, weight: .medium))
                                                                .foregroundColor(.white)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
            }
            .padding(10)
            .background(cardBackgroundSoft)
            .cornerRadius(10)
        }
    }
}

// MARK: - Diagnostic Run Sheet
struct DiagnosticRunSheet: View {
    @Binding var userVDOT: Double?
    @Binding var userGoal: RunGoal?
    @Binding var weeklyPlans: [DayPlan]
    @Environment(\.dismiss) var dismiss
    
    @StateObject private var tracker = ActivityTracker()
    @State private var step = 0 // 0=goal, 1=instructions, 2=running, 3=results, 4=skip/estimate
    @State private var selectedGoal: RunGoal = .generalFitness
    @State private var elapsedTime: TimeInterval = 0
    @State private var timer: Timer?
    @State private var startTime: Date?
    @State private var finishedMileTime: Double? = nil
    @State private var calculatedVDOT: Double? = nil
    @State private var calculatedPaces: TrainingPaces? = nil
    
    private let accentLime = Color(hex: "#FF8C00")
    private let backgroundColor = Color(hex: "#1A1A1C")
    private let cardBackground = Color(hex: "#2A2A2E")
    private let cardBackgroundSoft = Color(hex: "#242428")
    private let metersPerMile: Double = 1609.344
    
    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()
            
            switch step {
            case 0: goalSelectionStep
            case 1: instructionsStep
            case 2: activeRunStep
            case 3: resultsStep
            case 4: skipEstimateStep
            default: goalSelectionStep
            }
        }
    }
    
    // MARK: - Step 0: Goal Selection
    private var goalSelectionStep: some View {
        VStack(spacing: 24) {
            // Header
                                    HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                                                        Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            
            VStack(spacing: 6) {
                Text("What are you")
                    .font(.system(size: 28, weight: .regular))
                                            .foregroundColor(.white)
                Text("training for?")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(accentLime)
            }
            .padding(.top, 10)
            
            // Goal cards
            VStack(spacing: 10) {
                ForEach(RunGoal.allCases) { goal in
                    Button(action: { selectedGoal = goal }) {
                        HStack(spacing: 14) {
                            Image(systemName: goal.icon)
                                .font(.system(size: 20))
                                .foregroundColor(selectedGoal == goal ? .black : accentLime)
                                .frame(width: 40)
                            
                            Text(goal.rawValue)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(selectedGoal == goal ? .black : .white)
                            
                            Spacer()
                            
                            if selectedGoal == goal {
                                                            Image(systemName: "checkmark.circle.fill")
                                                                .font(.system(size: 18))
                                    .foregroundColor(.black)
                            }
                        }
                        .padding(16)
                        .background(selectedGoal == goal ? accentLime : cardBackground)
                        .cornerRadius(16)
                    }
                }
            }
            .padding(.horizontal, 20)
            
            Spacer()
            
            // Next button
            Button(action: { withAnimation { step = 1 } }) {
                Text("Next")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(accentLime)
                    .cornerRadius(20)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
    }
    
    // MARK: - Step 1: Instructions
    private var instructionsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: { withAnimation { step = 0 } }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            // Title block — left-aligned, natural line flow
            VStack(alignment: .leading, spacing: 8) {
                Text("Let's find your")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(.white)
                Text("baseline")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(accentLime)

                Text("One hard mile is all it takes. Your time sets the training paces for every run in your plan.")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.55))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)

            // How it works — numbered, feels human and deliberate
            VStack(alignment: .leading, spacing: 18) {
                stepRow(number: "1", title: "Warm up first",
                        detail: "5–10 easy minutes on a flat route or track.")
                stepRow(number: "2", title: "Run one mile, hard",
                        detail: "Push a strong, even effort the whole way.")
                stepRow(number: "3", title: "We do the math",
                        detail: "Auto-stops at a mile and builds your paces.")
            }
            .padding(.horizontal, 20)
            .padding(.top, 36)

            Spacer()

            VStack(spacing: 14) {
                Button(action: { startDiagnosticRun() }) {
                    Text("Start Time Trial")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(accentLime)
                        .cornerRadius(20)
                }

                Button(action: { withAnimation { step = 4 } }) {
                    Text("Skip for now")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 30)
        }
    }

    /// A numbered step in the "how it works" list.
    private func stepRow(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(accentLime)
                .frame(width: 30, height: 30)
                .background(
                    Circle().stroke(accentLime.opacity(0.4), lineWidth: 1.5)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Step 4: Skip / Self-Estimate
    /// When the user skips the time trial we still need a starting point for paces.
    /// They pick a rough fitness level; we can refine later with a real trial.
    private var skipEstimateStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: { withAnimation { step = 1 } }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            VStack(alignment: .leading, spacing: 8) {
                Text("How would you")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(.white)
                Text("describe your running?")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(accentLime)

                Text("We'll estimate your paces from this. Run the time trial anytime to dial them in.")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.55))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)

            VStack(spacing: 10) {
                levelCard(title: "New to running",
                          detail: "Just starting out or returning after a break",
                          mileTime: "~10:00 mile", vdot: 35)
                levelCard(title: "Recreational",
                          detail: "Run regularly, comfortable with distance",
                          mileTime: "~8:00 mile", vdot: 45)
                levelCard(title: "Competitive",
                          detail: "Train hard and race for time",
                          mileTime: "~6:30 mile", vdot: 55)
            }
            .padding(.horizontal, 20)
            .padding(.top, 28)

            Spacer()
        }
    }

    /// One selectable fitness-level card on the skip step. Tapping it applies the plan.
    private func levelCard(title: String, detail: String, mileTime: String, vdot: Double) -> some View {
        Button(action: { applyEstimatedLevel(vdot: vdot) }) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(mileTime)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(accentLime)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .cornerRadius(16)
        }
    }

    /// Generates a plan from a self-estimated level, no time trial required.
    private func applyEstimatedLevel(vdot: Double) {
        userVDOT = vdot
        userGoal = selectedGoal
        weeklyPlans = VDOTCalculator.generateWeeklyPlan(vdot: vdot, goal: selectedGoal)
        dismiss()
    }
    
    // MARK: - Step 2: Active Run
    private var activeRunStep: some View {
        VStack(spacing: 20) {
                                    Spacer()
            
            // Distance remaining
            let distanceMeters = tracker.liveSummary?.distance ?? 0
            let distanceMiles = distanceMeters / metersPerMile
            let remaining = max(0, 1.0 - distanceMiles)
            
            VStack(spacing: 8) {
                Text(String(format: "%.2f", remaining))
                    .font(.system(size: 80, weight: .bold, design: .rounded))
                    .monospacedDigit()
                                        .foregroundColor(.white)
                Text("miles remaining")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            }
            
            // Timer
            Text(formatTime(elapsedTime))
                .font(.system(size: 42, weight: .regular))
                .monospacedDigit()
                .foregroundColor(accentLime)
            
            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(cardBackgroundSoft)
                        .frame(height: 12)
                    
                    RoundedRectangle(cornerRadius: 6)
                        .fill(accentLime)
                        .frame(width: geo.size.width * min(CGFloat(distanceMiles), 1.0), height: 12)
                }
            }
            .frame(height: 12)
            .padding(.horizontal, 40)
            
                                    Spacer()
            
            // GPS indicator
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.system(size: 10))
                Text("GPS Tracking Active")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundColor(accentLime)
                    .padding(.bottom, 40)
                }
        .onChange(of: tracker.liveSummary?.distance) { _, newDistance in
            guard let distance = newDistance else { return }
            if distance >= metersPerMile && finishedMileTime == nil {
                finishDiagnosticRun()
            }
        }
    }
    
    // MARK: - Step 3: Results
    private var resultsStep: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 20) {
                // Header
                                HStack {
                                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                
                // VDOT Score
                if let vdot = calculatedVDOT {
                    VStack(spacing: 8) {
                        Text("Your VDOT")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                        
                        Text(String(format: "%.1f", vdot))
                            .font(.system(size: 64, weight: .bold, design: .rounded))
                            .foregroundColor(accentLime)
                        
                        if let time = finishedMileTime {
                            Text("1-Mile Time: \(formatTime(time))")
                                .font(.system(size: 14))
                                        .foregroundColor(.white.opacity(0.5))
                                }
                    }
                    .padding(.top, 10)
                }
                
                // Training Paces
                if let paces = calculatedPaces {
        VStack(alignment: .leading, spacing: 12) {
                        Text("YOUR TRAINING PACES")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.3))
                            .tracking(1)
                        
                        paceRow(name: "Easy", pace: paces.easy, color: "#5ECC3A", desc: "Recovery & base runs")
                        paceRow(name: "Marathon", pace: paces.marathon, color: "#E8D44A", desc: "Race pace")
                        paceRow(name: "Threshold", pace: paces.threshold, color: "#E89830", desc: "Tempo runs")
                        paceRow(name: "Interval", pace: paces.interval, color: "#E83030", desc: "VO2max work")
                        paceRow(name: "Repetition", pace: paces.repetition, color: "#FF5050", desc: "Speed & form")
            }
            .padding(16)
                    .background(cardBackground)
                    .cornerRadius(20)
                    .padding(.horizontal, 20)
                }
                
                // Goal reminder
                VStack(spacing: 4) {
                    Text("Training for")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                    Text(selectedGoal.rawValue)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(accentLime)
                }
                .padding(.top, 8)
                
                // Apply button
                Button(action: applyToWeeklyPlan) {
                    Text("Apply to Weekly Plan")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(accentLime)
                        .cornerRadius(20)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                
                // Retake button
                Button(action: {
                    finishedMileTime = nil
                    calculatedVDOT = nil
                    calculatedPaces = nil
                    withAnimation { step = 1 }
                }) {
                    Text("Retake Test")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.bottom, 40)
            }
        }
    }
    
    private func paceRow(name: String, pace: String, color: String, desc: String) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(hex: color))
                .frame(width: 4, height: 36)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                Text(desc)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
            }
            
            Spacer()
            
            Text(pace)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.white)
        }
        .padding(.vertical, 2)
    }
    
    // MARK: - Run Control
    
    private func startDiagnosticRun() {
        tracker.reset()
        tracker.startTracking()
        startTime = Date()
        elapsedTime = 0
        finishedMileTime = nil
        
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if let start = startTime {
                elapsedTime = Date().timeIntervalSince(start)
            }
        }
        
        withAnimation { step = 2 }
    }
    
    private func finishDiagnosticRun() {
        let mileTime = elapsedTime
        finishedMileTime = mileTime
        timer?.invalidate()
        _ = tracker.stopTracking()
        
        let vdot = VDOTCalculator.vdotFromMileTime(mileTime)
        calculatedVDOT = vdot
        calculatedPaces = VDOTCalculator.trainingPaces(vdot: vdot)
        
        withAnimation { step = 3 }
    }
    
    private func applyToWeeklyPlan() {
        guard let vdot = calculatedVDOT else { return }
        
        userVDOT = vdot
        userGoal = selectedGoal
        weeklyPlans = VDOTCalculator.generateWeeklyPlan(vdot: vdot, goal: selectedGoal)
        
        dismiss()
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

#Preview {
    RunView()
}
