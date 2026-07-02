//
//  HomeView.swift
//  RunRightApp
//
//  Pixel-perfect match to HTML prototype

import SwiftUI
import Neumorphic

enum LastRunMetric {
    case pace, heartRate
}

struct HomeView: View {
    var onOpenCoach: () -> Void = {}
    private let accentLime = Color(hex: "#00CED1")
    private let backgroundColor = Color(hex: "#33393E")
    private let cardBackground = Color(hex: "#33393E")
    private let cardBackgroundSoft = Color(hex: "#33393E")
    @StateObject private var vm = HomeViewModel()
    @State private var lastRunGraphMetric: LastRunMetric = .pace
    @State private var visibleSections: [Bool] = Array(repeating: false, count: 4)
    @State private var scrollOffset: CGFloat = 0   // drives the header fade
    @State private var showCoach = false

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
                    
                    GeometryReader { geo in
                        let totalWidth = geo.size.width - 12
                        let cardHeight = geo.size.height
                        HStack(alignment: .top, spacing: 12) {
                            CoachHomeCard(onTap: onOpenCoach)
                                .frame(width: totalWidth * 0.78, height: cardHeight)
                            
                            VStack(spacing: 12) {
                                runningFormScoreCard
                                shoeWearStatusCard
                            }
                            .frame(width: totalWidth * 0.22, height: cardHeight)
                        }
                    }
                    .frame(height: 220)
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
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                            Spacer()
                            Text("\(vm.stats.totalRuns) runs")
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.5))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.3))
                        }
                        .padding(16)
                        .homeRaisedSurface(fill: cardBackground, cornerRadius: 16, shadowRadius: 9, x: 5, y: 6)
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
        .sheet(isPresented: $showCoach) {
            CoachChatView()
        }
        .onAppear {
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
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.white)
            + Text(vm.displayName)
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(.white)

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
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
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
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white.opacity(0.35))
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
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(unit.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .homeRaisedSurface(fill: cardBackgroundSoft, cornerRadius: 12, shadowRadius: 6, x: 3, y: 4, lightOpacity: 0.04, darkOpacity: 0.34)
    }
    
    private var runButtonBox: some View {
        VStack(spacing: 2) {
            Text("\(vm.runStreak)")
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .foregroundColor(backgroundColor)
            Text("DAY STREAK")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(backgroundColor.opacity(0.65))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .homeRaisedSurface(fill: accentLime, cornerRadius: 20, shadowRadius: 10, x: 5, y: 7, lightOpacity: 0.18, darkOpacity: 0.38)
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
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)

                // Rows flex to fill available height — no fixed row height needed
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { index in
                        let hasRun = miles[index] > 0
                        let fillRatio = hasRun ? CGFloat(miles[index] / maxMiles) : 0
                        HStack(spacing: 5) {
                            Text(dayNames[index])
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(index == todayIndex ? accentLime : .white.opacity(0.4))
                                .frame(width: 10)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.white.opacity(0.07))
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
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
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
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Spacer()
                    Text(vm.formattedLastRunTime())
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(.white.opacity(0.4))
                }
                
                // Big distance
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(distanceKmText)
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(.white)
                    Text("km")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
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
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.white.opacity(0.4))
                        Spacer()
                        Text(lastRunGraphMetric == .pace ? "Avg \(avgPaceText) " : "Avg \(avgHrText) bpm")
                            .font(.system(size: 11, weight: .medium))
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
                .font(.system(size: 12))
                .foregroundColor(accentLime.opacity(0.7))
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(.white.opacity(0.4))
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
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(backgroundColor)
            Text("\(vm.monthlyRunCount)")
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundColor(backgroundColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .homeRaisedSurface(fill: accentLime, cornerRadius: 16, shadowRadius: 9, x: 5, y: 6, lightOpacity: 0.18, darkOpacity: 0.36)
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
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(backgroundColor)
            Text(milesText)
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundColor(backgroundColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .homeRaisedSurface(fill: accentLime, cornerRadius: 16, shadowRadius: 9, x: 5, y: 6, lightOpacity: 0.18, darkOpacity: 0.36)
    }
    
    // MARK: - Weekly Goal Progress Card
    private var weeklyGoalCard: some View {
        let progress = min(vm.weeklyMilesTotal / max(vm.weeklyGoalMiles, 1), 1.0)
        let remaining = max(vm.weeklyGoalMiles - vm.weeklyMilesTotal, 0)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("WEEKLY GOAL")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Text("\(String(format: "%.1f", vm.weeklyMilesTotal)) / \(String(format: "%.0f", vm.weeklyGoalMiles)) mi")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(accentLime)
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.08))
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
                        .font(.system(size: 12))
                        .foregroundColor(accentLime)
                    Text("Goal reached!")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(accentLime)
                }
            } else {
                Text("\(String(format: "%.1f", remaining)) mi remaining")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
            }
        }
        .padding(16)
        .homeRaisedSurface(fill: cardBackground, cornerRadius: 20)
    }

    
}

private struct HomeRaisedSurface: ViewModifier {
    let fill: Color
    let cornerRadius: CGFloat
    let shadowRadius: CGFloat
    let x: CGFloat
    let y: CGFloat
    let lightOpacity: Double
    let darkOpacity: Double

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background(
                shape
                    .fill(fill)
                    .softOuterShadow(
                        darkShadow: Color(hex: "#1C1919").opacity(darkOpacity),
                        lightShadow: Color.white.opacity(lightOpacity),
                        offset: max(x, y),
                        radius: shadowRadius
                    )
                    .softInnerShadow(
                        shape,
                        darkShadow: Color(hex: "#1C1919").opacity(darkOpacity * 0.26),
                        lightShadow: Color.white.opacity(lightOpacity * 0.7),
                        spread: 0.03,
                        radius: max(2, shadowRadius * 0.16)
                    )
            )
    }
}

extension View {
    func homeRaisedSurface(
        fill: Color,
        cornerRadius: CGFloat,
        shadowRadius: CGFloat = 22,
        x: CGFloat = 12,
        y: CGFloat = 12,
        lightOpacity: Double = 0.20,
        darkOpacity: Double = 0.86
    ) -> some View {
        modifier(
            HomeRaisedSurface(
                fill: fill,
                cornerRadius: cornerRadius,
                shadowRadius: shadowRadius,
                x: x,
                y: y,
                lightOpacity: lightOpacity,
                darkOpacity: darkOpacity
            )
        )
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
            .homeRaisedSurface(fill: background, cornerRadius: 20)
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
                .stroke(Color.white.opacity(0.1), lineWidth: ringLineWidth)

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
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)
                    Text("steps")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.white.opacity(0.5))
                    if progress >= 1.0 {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(accent)
                    }
                }
            } else {
                Image(systemName: "heart.slash")
                    .font(.system(size: 22))
                    .foregroundColor(.white.opacity(0.2))
            }
        }
    }
}


// MARK: - Circular Progress View
struct CircularProgressView: View {
    private let ringSize: CGFloat = 280
    private let strokeWidth: CGFloat = 20
    private let progress: CGFloat = 0.75 // 75% progress
    private let outerRingSize: CGFloat = 324  // Outer circle for week markers
    
    var body: some View {
        ZStack {
            // Outer circle connecting the week segments (white)
            Circle()
                .stroke(
                    Color.white.opacity(0.3),
                    lineWidth: 1
                )
                .frame(width: outerRingSize, height: outerRingSize)
            
            // Week segments (7 marks connecting outer circle to progress ring, white)
            ForEach(0..<7, id: \.self) { index in
                Rectangle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: 1, height: (outerRingSize - ringSize) / 2 + 2)
                    .offset(y: -((outerRingSize + ringSize) / 4))
                    .rotationEffect(.degrees(Double(index) * 51.43))
            }
            
            // Background ring (inner, for the progress)
            Circle()
                .stroke(
                    Color(hex: "#1a2a4a").opacity(0.4),
                    lineWidth: strokeWidth
                )
                .frame(width: ringSize - strokeWidth, height: ringSize - strokeWidth)
            
            // Progress ring with blue → neon green → yellow gradient
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(
                        stops: [
                            .init(color: Color(hex: "#0a1a3d"), location: 0.0),
                            .init(color: Color(hex: "#1a3a6e"), location: 0.12),
                            .init(color: Color(hex: "#2563EB"), location: 0.25),
                            .init(color: Color(hex: "#00CED1"), location: 0.4),
                            .init(color: Color(hex: "#00FF7F"), location: 0.55),
                            .init(color: Color(hex: "#39FF14"), location: 0.7),
                            .init(color: Color(hex: "#ADFF2F"), location: 0.85),
                            .init(color: Color(hex: "#FFFF00"), location: 1.0)
                        ],
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
                .frame(width: ringSize - strokeWidth, height: ringSize - strokeWidth)
                .rotationEffect(.degrees(-90))
            
            // Center content
            VStack(spacing: 0) {
                // Runs
                VStack(spacing: 2) {
                    Text("4")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white)
                    Text("Runs")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(.white.opacity(0.4))
                        .textCase(.uppercase)
                        .tracking(0.5)
                }
                .padding(.vertical, 4)
                
                // Divider
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 160, height: 1)
                
                // Miles (center, BOLD and LARGE)
                VStack(spacing: 2) {
                    Text("23 mi")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(.white)
                    Text("This Week")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(.white.opacity(0.4))
                        .textCase(.uppercase)
                        .tracking(0.5)
                }
                .padding(.vertical, 14)
                
                // Divider
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 160, height: 1)
                
                // Time
                VStack(spacing: 2) {
                    Text("3h 42m")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(.white)
                    Text("Time")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundColor(.white.opacity(0.4))
                        .textCase(.uppercase)
                        .tracking(0.5)
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: outerRingSize + 10, height: outerRingSize + 10)
    }
}

// MARK: - Home Section Card
struct HomeSectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.cardGradient)
        .cornerRadius(14)
    }
}

// MARK: - Weekly Plan Row (simplified, elegant like the dial)
struct WeeklyPlanRow: View {
    private let accentCyan = Color(hex: "#00CED1")
    
    private let days: [(day: String, workout: String, isCurrent: Bool)] = [
        ("Mon", "5K Easy", false),
        ("Tue", "Rest", false),
        ("Wed", "Intervals", false),
        ("Thu", "Rest", false),
        ("Fri", "3K Easy", false),
        ("Sat", "Long Run", true),
        ("Sun", "Rest", false)
    ]
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(days, id: \.day) { day, workout, isCurrent in
                VStack(alignment: .leading, spacing: 8) {
                    // Day
                    Text(day)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(.white.opacity(0.4))
                        .textCase(.uppercase)
                        .tracking(0.5)
                    
                    // Workout
                    Text(workout)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundColor(isCurrent ? .white : .white.opacity(0.7))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // Current day indicator (subtle)
                    if isCurrent {
                        Rectangle()
                            .fill(accentCyan)
                            .frame(height: 2)
                            .cornerRadius(1)
                    } else {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(height: 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isCurrent ? Color.white.opacity(0.05) : Color.clear)
                )
            }
        }
    }
}

// MARK: - Today's Activity Content (simplified, elegant)
struct TodaysActivityContent: View {
    private let accentCyan = Color(hex: "#00CED1")
    
    var body: some View {
        HStack(spacing: 0) {
            // Mini map with route
            RouteMapView(coordinates: [], isTracking: false)
                .frame(width: 100, height: 100)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
            
            Spacer().frame(width: 16)
            
            // Details
            VStack(alignment: .leading, spacing: 6) {
                Text("0.0 km")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(.white)
                
                Text("No activity yet")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white.opacity(0.5))
            }
            
            Spacer()
            
            // Simple Run button
            Button(action: {}) {
                Text("Run")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(accentCyan)
                    .cornerRadius(8)
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
    private let accentBright = Color(hex: "#FFFFFF")   // today highlight — white
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
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
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
        guard miles > 0 else { return Color.white.opacity(0.05) }
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

// MARK: - Diagnostic Run Content (simplified, elegant)
// MARK: - Section Header (no cyan rail, clean simple)
struct HomeSectionHeader: View {
    let title: String
    let accent: Color
    
    var body: some View {
        Text(title)
            .font(AppTheme.subtitleFont)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
    }
}

// MARK: - Section Divider
struct HomeSectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
    }
}

#Preview {
    HomeView()
}
