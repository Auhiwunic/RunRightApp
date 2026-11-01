//
//  HomeView.swift
//  RunRightApp
//
//  Pixel-perfect match to HTML prototype

import SwiftUI

enum LastRunMetric {
    case pace, heartRate
}

struct HomeView: View {
    var onOpenCoach: () -> Void = {}
    private let accentLime = Color(hex: "#00CED1")
    private let backgroundColor = AppTheme.cardBgAlt
    private let cardBackground = AppTheme.cardBg
    private let cardBackgroundSoft = AppTheme.cardBgAlt
    @ObservedObject private var vm = HomeViewModel.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastRunGraphMetric: LastRunMetric = .pace
    @State private var visibleSections: [Bool] = Array(repeating: false, count: 4)
    @State private var scrollOffset: CGFloat = 0   // drives the header fade
    private static var didAnimateEntrance = false

    var body: some View {
        NavigationStack {
        ZStack {
            backgroundColor.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    ScrollOffsetReader(space: "homeScroll")

                    headerRow
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .opacity(visibleSections[0] ? scrollFadeOpacity(scrollOffset) : 0)
                        .offset(y: visibleSections[0] ? 0 : 18)
                    
                    GeometryReader { geo in
                        // Streak card: square (roughly).
                        // Workouts card: remaining height — rows adapt via maxHeight: .infinity.
                        let totalWidth = geo.size.width - 12
                        let cardHeight = geo.size.height
                        let rightWidth = totalWidth * 0.35
                        let streakHeight: CGFloat = min(rightWidth, 100)   // square but cap at 100
                        let weekHeight = cardHeight - streakHeight - 12

                        HStack(alignment: .top, spacing: 12) {
                            stepsBox
                                .frame(width: totalWidth * 0.65, height: cardHeight)

                            VStack(spacing: 12) {
                                runButtonBox
                                    .frame(width: rightWidth, height: streakHeight)
                                workoutsBox
                                    .frame(width: rightWidth, height: weekHeight)
                            }
                        }
                    }
                    .frame(height: 300)
                    .padding(.horizontal, 20)
                    .opacity(visibleSections[1] ? 1 : 0)
                    .offset(y: visibleSections[1] ? 0 : 18)
                    
                    lastRunSummaryCard
                        .padding(.horizontal, 20)
                        .opacity(visibleSections[2] ? 1 : 0)
                        .offset(y: visibleSections[2] ? 0 : 18)
                    
                    // RUNS and MILES share this row at equal height; the
                    // coach card moved out — Coach has its own tab.
                    HStack(spacing: 12) {
                        runningFormScoreCard
                        shoeWearStatusCard
                    }
                    .frame(height: 104)
                    .padding(.horizontal, 20)
                    .opacity(visibleSections[3] ? 1 : 0)
                    .offset(y: visibleSections[3] ? 0 : 18)
                    

                    // Weekly Goal Progress
                    weeklyGoalCard
                        .padding(.horizontal, 20)

                    // Run History link — no logo
                    NavigationLink(destination: RunHistoryView()) {
                        HStack(spacing: 12) {
                            Text("RUN HISTORY")
                                .font(AppTheme.head(14))
                                .foregroundColor(AppTheme.primaryText)
                            Spacer()
                            Text("\(vm.stats.totalRuns) runs")
                                .font(AppTheme.body(12))
                                .foregroundColor(AppTheme.primaryText.opacity(0.5))
                            Image(systemName: "chevron.right")
                                .font(AppTheme.bodyMedium(12))
                                .foregroundColor(AppTheme.primaryText.opacity(0.3))
                        }
                        .padding(16)
                        .appRaisedSurface(fill: cardBackground, cornerRadius: 16, shadowRadius: 9, x: 5, y: 6)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)

                    Spacer().frame(height: AppTheme.tabBarHeight + 24)
                }
            }
            .coordinateSpace(name: "homeScroll")
            .onPreferenceChange(ScrollOffsetKey.self) { scrollOffset = $0 }
        }
        .task {
            await vm.load()
        }
        .refreshable {
            await vm.load()
        }
        // Refresh when the app returns to the foreground so the TODAY panel and
        // stats aren't stale after the phone sat overnight (or across midnight).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await vm.load() } }
        }
        .onAppear {
            // Stagger the entrance once per app session — the tab views are
            // rebuilt on every switch, so without the flag the whole Home page
            // blinked invisible and re-animated every time the user came back.
            if Self.didAnimateEntrance {
                visibleSections = Array(repeating: true, count: visibleSections.count)
                return
            }
            Self.didAnimateEntrance = true
            for i in 0..<visibleSections.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.15) {
                    withAnimation(.easeOut(duration: 0.4)) {
                        visibleSections[i] = true
                    }
                }
            }
        }
        .navigationBarHidden(true)
        } // NavigationStack
    }
    
    // MARK: - Header Row
    private var headerRow: some View {
        HStack {
            Text("Hello, ")
                .font(AppTheme.display(32))
                .foregroundColor(AppTheme.primaryText)
            + Text(vm.displayName)
                .font(AppTheme.display(32))
                .foregroundColor(AppTheme.primaryText)

            Spacer()
        }
    }
    
    private var stepsBox: some View {
        let goalSteps = 10_000
        let steps = vm.stepsToday
        let progress = min(CGFloat(steps) / CGFloat(goalSteps), 1.0)
        let hkAvailable = HealthKitManager.shared.isAvailable

        return DashboardCard(background: cardBackground) {
            GeometryReader { proxy in
                let spacing: CGFloat = 8
                let chipH: CGFloat = hkAvailable ? 28 : 0
                let availableWidth = proxy.size.width
                let ringSize = min(availableWidth, proxy.size.height - 24 - chipH - spacing * 2) * 0.82

                VStack(spacing: spacing) {
                    Text("TODAY")
                        .font(AppTheme.head(13))
                        .foregroundColor(AppTheme.primaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    StepsProgressRing(progress: progress, steps: steps,
                                      goal: goalSteps, accent: accentLime,
                                      hkAvailable: hkAvailable)
                        .frame(width: ringSize, height: ringSize)
                        .frame(maxWidth: .infinity, alignment: .center)

                    Spacer(minLength: 0)

                    if hkAvailable {
                        // Metrics row — active minutes · calories · distance
                        HStack(spacing: 8) {
                            hkChip(value: vm.activeMinutesToday > 0 ? "\(vm.activeMinutesToday)" : "—", unit: "min")
                            hkChip(value: vm.caloriesToday > 0 ? "\(vm.caloriesToday)" : "—", unit: "kcal")
                            hkChip(value: vm.distanceTodayMiles > 0 ? String(format: "%.1f", vm.distanceTodayMiles) : "—", unit: "mi")
                        }
                    } else {
                        Text("Health not available\non Simulator")
                            .font(AppTheme.bodyMedium(11))
                            .foregroundColor(AppTheme.primaryText.opacity(0.35))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
    }

    private func hkChip(value: String, unit: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(AppTheme.display(20))
                .foregroundColor(AppTheme.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit.uppercased())
                .font(AppTheme.meta(10))
                .foregroundColor(AppTheme.primaryText.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .appRaisedSurface(fill: cardBackgroundSoft, cornerRadius: 12, shadowRadius: 6, x: 3, y: 4, lightOpacity: 0.04, darkOpacity: 0.34)
    }
    
    private var runButtonBox: some View {
        VStack(spacing: 2) {
            Text("\(vm.runStreak)")
                .font(AppTheme.display(30))
                .foregroundColor(backgroundColor)
            Text("DAY STREAK")
                .font(AppTheme.meta(9))
                .foregroundColor(backgroundColor.opacity(0.65))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appRaisedSurface(fill: accentLime, cornerRadius: 20, shadowRadius: 8, x: 5, y: 6, lightOpacity: 0.08, darkOpacity: 0.34)
    }
    
    private var workoutsBox: some View {
        let dayNames = ["M", "T", "W", "T", "F", "S", "S"]
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: Date())
        let todayIndex: Int = {
            switch weekday {
            case 2: return 0; case 3: return 1; case 4: return 2
            case 5: return 3; case 6: return 4; case 7: return 5
            default: return 6
            }
        }()
        // Use real weekly miles from vm — index 0=Mon … 6=Sun
        let miles = vm.weeklyMiles
        let maxMiles = max(miles.max() ?? 1, 1)

        return DashboardCard(background: cardBackground) {
            VStack(alignment: .leading, spacing: 4) {
                Text("THIS WEEK")
                    .font(AppTheme.head(13))
                    .foregroundColor(AppTheme.primaryText)

                // Rows flex to fill available height — no fixed row height needed
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { index in
                        let hasRun = miles[index] > 0
                        let fillRatio = hasRun ? CGFloat(miles[index] / maxMiles) : 0
                        HStack(spacing: 5) {
                            Text(dayNames[index])
                                .font(AppTheme.bodySemibold(9))
                                .foregroundColor(index == todayIndex ? accentLime : AppTheme.primaryText.opacity(0.4))
                                .frame(width: 10)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(AppTheme.primaryText.opacity(0.07))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    if hasRun {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(accentLime)
                                            .frame(width: max(geo.size.width * fillRatio, geo.size.width * 0.12))
                                    } else if index == todayIndex {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(accentLime.opacity(0.18))
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: .infinity)  // each row shares space equally
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
    
    
    
    // MARK: - Last Run Summary (biggest card)
    private var lastRunSummaryCard: some View {
        DashboardCard(background: cardBackground) {
            if vm.lastRun == nil {
                // Empty state — clean, no icon, no subtext
                Text("NO RUNS YET")
                    .font(AppTheme.head(16))
                    .foregroundColor(AppTheme.primaryText.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {

            let distanceKmText = vm.formattedDistanceKm()
            let durationText = vm.formattedDuration()
            let avgPaceText = vm.formattedAvgPaceMinPerKm() ?? "—"
            let avgHrText = vm.formattedAvgHeartRate() ?? "—"
            let pacePoints = vm.pacePoints()
            let hrPoints = vm.heartRatePoints()
            let points = lastRunGraphMetric == .pace ? pacePoints : hrPoints

            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("LAST RUN")
                        .font(AppTheme.head(16))
                        .foregroundColor(AppTheme.primaryText)
                    Spacer()
                    Text(vm.formattedLastRunTime())
                        .font(AppTheme.body(12))
                        .foregroundColor(AppTheme.primaryText.opacity(0.4))
                }
                
                // Big distance
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(distanceKmText)
                        .font(AppTheme.display(48))
                        .foregroundColor(AppTheme.primaryText)
                    Text("km")
                        .font(AppTheme.bodyMedium(20))
                        .foregroundColor(AppTheme.primaryText.opacity(0.5))
                }
                
                // Stats row
                HStack(spacing: 0) {
                    lastRunStat(value: durationText, label: "Duration", icon: "clock", isSelected: false)
                    Spacer()
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) { lastRunGraphMetric = .pace }
                    }) {
                        lastRunStat(value: avgPaceText, label: "Avg Pace", icon: "speedometer", isSelected: lastRunGraphMetric == .pace)
                    }
                    Spacer()
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.3)) { lastRunGraphMetric = .heartRate }
                    }) {
                        lastRunStat(value: avgHrText, label: "Avg HR", icon: "heart.fill", isSelected: lastRunGraphMetric == .heartRate)
                    }
                    Spacer()
                    lastRunStat(value: "—", label: "Cadence", icon: "metronome", isSelected: false)
                }
                
                // Switchable graph
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(lastRunGraphMetric == .pace ? "Pace (min/km)" : "Heart Rate (bpm)")
                            .font(AppTheme.body(11))
                            .foregroundColor(AppTheme.primaryText.opacity(0.4))
                        Spacer()
                        Text(lastRunGraphMetric == .pace ? "Avg \(avgPaceText) " : "Avg \(avgHrText) bpm")
                            .font(AppTheme.bodyMedium(11))
                            .foregroundColor(lastRunGraphMetric == .pace ? accentLime : Color(hex: "#FF6B6B"))
                    }
                    
                    GeometryReader { geo in
                        let lineColor = lastRunGraphMetric == .pace ? accentLime : Color(hex: "#FF6B6B")
                        
                        // Fill
                        Path { path in
                            let w = geo.size.width
                            let h = geo.size.height
                            guard points.count >= 2 else {
                                // If we don't have enough data, draw an empty baseline.
                                path.move(to: CGPoint(x: 0, y: h))
                                path.addLine(to: CGPoint(x: w, y: h))
                                return
                            }

                            let step = w / CGFloat(points.count - 1)
                            path.move(to: CGPoint(x: 0, y: h * (1 - points[0])))
                            for i in 1..<points.count {
                                path.addLine(to: CGPoint(x: step * CGFloat(i), y: h * (1 - points[i])))
                            }
                            path.addLine(to: CGPoint(x: w, y: h))
                            path.addLine(to: CGPoint(x: 0, y: h))
                            path.closeSubpath()
                        }
                        .fill(
                            LinearGradient(colors: [lineColor.opacity(0.3), lineColor.opacity(0.05)],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        
                        // Line
                        Path { path in
                            let w = geo.size.width
                            let h = geo.size.height
                            guard points.count >= 2 else {
                                path.move(to: CGPoint(x: 0, y: h))
                                path.addLine(to: CGPoint(x: w, y: h))
                                return
                            }

                            let step = w / CGFloat(points.count - 1)
                            path.move(to: CGPoint(x: 0, y: h * (1 - points[0])))
                            for i in 1..<points.count {
                                path.addLine(to: CGPoint(x: step * CGFloat(i), y: h * (1 - points[i])))
                            }
                        }
                        .stroke(lineColor.opacity(0.8), lineWidth: 1.5)
                    }
                    .frame(height: 40)
                    .animation(.easeInOut(duration: 0.3), value: lastRunGraphMetric)
                }
            }
            } // else (has last run)
        }
    }
    
    private func lastRunStat(value: String, label: String, icon: String, isSelected: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(AppTheme.body(12))
                .foregroundColor(accentLime.opacity(0.7))
            Text(value)
                .font(AppTheme.bodySemibold(16))
                .foregroundColor(AppTheme.primaryText)
            Text(label)
                .font(AppTheme.body(10))
                .foregroundColor(AppTheme.primaryText.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? accentLime.opacity(0.1) : Color.clear)
        )
    }
    
    // MARK: - Running Form Score (compact green card)
    private var runningFormScoreCard: some View {
        VStack(spacing: 4) {
            Text("RUNS")
                .font(AppTheme.meta(10))
                .foregroundColor(backgroundColor)
            Text("\(vm.monthlyRunCount)")
                .font(AppTheme.display(28))
                .foregroundColor(backgroundColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appRaisedSurface(fill: accentLime, cornerRadius: 16, shadowRadius: 8, x: 5, y: 6, lightOpacity: 0.08, darkOpacity: 0.34)
    }

    // MARK: - Shoe Wear Status (compact green card)
    private var shoeWearStatusCard: some View {
        let milesText: String = {
            let mi = vm.monthlyMiles
            if mi >= 100 { return String(format: "%.0f", mi) }
            return String(format: "%.1f", mi)
        }()
        return VStack(spacing: 4) {
            Text("MILES")
                .font(AppTheme.meta(10))
                .foregroundColor(backgroundColor)
            Text(milesText)
                .font(AppTheme.display(28))
                .foregroundColor(backgroundColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appRaisedSurface(fill: accentLime, cornerRadius: 16, shadowRadius: 8, x: 5, y: 6, lightOpacity: 0.08, darkOpacity: 0.34)
    }
    
    // MARK: - Weekly Goal Progress Card
    private var weeklyGoalCard: some View {
        let progress = min(vm.weeklyMilesTotal / max(vm.weeklyGoalMiles, 1), 1.0)
        let remaining = max(vm.weeklyGoalMiles - vm.weeklyMilesTotal, 0)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("WEEKLY GOAL")
                    .font(AppTheme.head(14))
                    .foregroundColor(AppTheme.primaryText)
                Spacer()
                Text("\(String(format: "%.1f", vm.weeklyMilesTotal)) / \(String(format: "%.0f", vm.weeklyGoalMiles)) mi")
                    .font(AppTheme.bodySemibold(12))
                    .foregroundColor(accentLime)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(AppTheme.primaryText.opacity(0.08))
                        .frame(height: 10)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(
                            LinearGradient(
                                colors: [accentLime.opacity(0.7), accentLime],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geo.size.width * CGFloat(progress), height: 10)
                }
            }
            .frame(height: 10)

            if progress >= 1.0 {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(AppTheme.body(12))
                        .foregroundColor(accentLime)
                    Text("Goal reached!")
                        .font(AppTheme.bodyMedium(12))
                        .foregroundColor(accentLime)
                }
            } else {
                Text("\(String(format: "%.1f", remaining)) mi remaining")
                    .font(AppTheme.body(11))
                    .foregroundColor(AppTheme.primaryText.opacity(0.35))
            }
        }
        .padding(16)
        .appRaisedSurface(fill: cardBackground, cornerRadius: 20)
    }

    
}


// MARK: - Dashboard Card
struct DashboardCard<Content: View>: View {
    let background: Color
    @ViewBuilder let content: Content
    
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .appRaisedSurface(fill: background, cornerRadius: 20)
    }
}

// MARK: - Steps Progress Ring
struct StepsProgressRing: View {
    let progress: CGFloat
    let steps: Int
    let goal: Int
    let accent: Color
    let hkAvailable: Bool

    var body: some View {
        let ringLineWidth: CGFloat = 16
        ZStack {
            Circle()
                .stroke(AppTheme.primaryText.opacity(0.1), lineWidth: ringLineWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(accent, style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: progress)

            if hkAvailable {
                VStack(spacing: 2) {
                    Text(steps >= 1000
                         ? String(format: "%.1fk", Double(steps) / 1000)
                         : "\(steps)")
                        .font(AppTheme.head(20))
                        .foregroundColor(AppTheme.primaryText)
                    Text("steps")
                        .font(AppTheme.body(11))
                        .foregroundColor(AppTheme.primaryText.opacity(0.5))
                    if progress >= 1.0 {
                        Image(systemName: "checkmark.circle.fill")
                            .font(AppTheme.body(12))
                            .foregroundColor(accent)
                    }
                }
            } else {
                Image(systemName: "heart.slash")
                    .font(AppTheme.body(22))
                    .foregroundColor(AppTheme.primaryText.opacity(0.2))
            }
        }
    }
}


// MARK: - Monthly Heatmap View
struct MonthlyHeatmapView: View {
    /// Miles ran per day-of-month (key = day number 1...31, value = miles)
    var runsByDay: [Int: Double] = [:]
    /// Daily mile goal for full-intensity color (default 3 mi)
    var dailyGoalMiles: Double = 3.0

    private let accentLime = Color(hex: "#00CED1")
    private let accentBright = Color(lightHex: "#141412", darkHex: "#FFFFFF")
    private let dayLabels = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        let calendar = Calendar.current
        let now = Date()
        let todayDay = calendar.component(.day, from: now)

        // First day of current month
        let comps = calendar.dateComponents([.year, .month], from: now)
        let firstOfMonth = calendar.date(from: comps)!
        let daysInMonth = calendar.range(of: .day, in: .month, for: firstOfMonth)!.count

        // Weekday of the 1st: convert to Monday-based offset (Mon=0 ... Sun=6)
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth) // 1=Sun...7=Sat
        let dayOffset: Int = {
            switch firstWeekday {
            case 2: return 0 // Mon
            case 3: return 1
            case 4: return 2
            case 5: return 3
            case 6: return 4
            case 7: return 5
            default: return 6 // Sun
            }
        }()

        let totalCells = dayOffset + daysInMonth
        let rows = (totalCells + 6) / 7
        let cellCount = rows * 7

        VStack(alignment: .leading, spacing: 8) {
            // Day labels header
            HStack(spacing: 4) {
                ForEach(dayLabels, id: \.self) { label in
                    Text(label)
                        .font(AppTheme.bodyMedium(10))
                        .foregroundColor(AppTheme.primaryText.opacity(0.4))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Heatmap grid
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(0..<cellCount, id: \.self) { index in
                    let dayNum = index - dayOffset + 1
                    let isValidDay = dayNum >= 1 && dayNum <= daysInMonth
                    let isToday = dayNum == todayDay && isValidDay
                    let miles = isValidDay ? (runsByDay[dayNum] ?? 0) : 0

                    RoundedRectangle(cornerRadius: 4)
                        .fill(isValidDay ? heatmapColor(miles: miles) : Color.clear)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay(
                            Group {
                                if isToday {
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(accentBright, lineWidth: 1.5)
                                }
                            }
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Intensity: 0 = no run, low = just started, medium = partial goal, full = hit goal
    private func heatmapColor(miles: Double) -> Color {
        guard miles > 0 else { return AppTheme.primaryText.opacity(0.05) }
        let ratio = min(miles / max(dailyGoalMiles, 0.1), 1.0)
        if ratio >= 0.9 {
            return accentLime                // Hit the goal — full lime
        } else if ratio >= 0.5 {
            return accentLime.opacity(0.55)  // Good effort — medium
        } else {
            return accentLime.opacity(0.25)  // Just started — light
        }
    }
}

#Preview {
    HomeView()
}
