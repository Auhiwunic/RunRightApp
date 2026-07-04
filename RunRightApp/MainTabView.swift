//
//  MainTabView.swift
//  RunRightApp
//

import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 2 // Home is center (index 2)
    @ObservedObject private var run = RunSession.shared

    var body: some View {
        ZStack {
            // Always-visible app background — never exposes the black UIKit window
            AppTheme.bgColor.ignoresSafeArea()

            // Only the active tab renders. The Group fills the full ZStack so
            // GeometryReaders and NavigationStacks in each view get the correct
            // available frame (NOT bottom-aligned like ZStack(alignment:.bottom)).
            Group {
                switch selectedTab {
                case 0: AnalyzeView()
                case 1: CoachTabView()
                case 3: RunView()
                case 4: ProfileView()
                default: HomeView(onOpenCoach: { selectedTab = 1 })
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Custom tab bar pinned to the very bottom. Only the BAR ignores the
            // keyboard (so it doesn't ride up) — putting the modifier on the whole
            // ZStack killed keyboard avoidance app-wide and left the Coach chat
            // input buried under the keyboard.
            VStack(spacing: 0) {
                Spacer()
                if run.isActive && !run.isPresented {
                    runningBanner
                }
                CustomTabBar(selectedTab: $selectedTab)
            }
            .ignoresSafeArea(.keyboard)
        }
        // The live run lives above every tab, so it keeps tracking + coaching when
        // minimized or when the user switches tabs.
        .fullScreenCover(isPresented: $run.isPresented) {
            ActiveRunView(
                tracker: run.tracker,
                elapsedTime: Binding(get: { run.elapsed }, set: { _ in }),
                shoeName: run.shoeName,
                plannedTargetPaceSecPerMile: run.targetPaceSecPerMile
            )
        }
    }

    // MARK: - Running banner (shown across tabs while a run is minimized)
    private var runningBanner: some View {
        let orange = Color(hex: "#FF8C00")
        let miles = (run.tracker.liveSummary?.distance ?? 0) / 1609.344
        let secs = Int(run.elapsed)
        let time = String(format: "%d:%02d", secs / 60, secs % 60)
        return Button(action: { run.resume() }) {
            HStack(spacing: 10) {
                Circle().fill(orange).frame(width: 9, height: 9)
                Text("RUNNING")
                    .font(AppTheme.meta(12))
                    .foregroundColor(AppTheme.primaryText)
                Text("\(time) · \(String(format: "%.2f", miles)) mi")
                    .font(AppTheme.meta(12))
                    .foregroundColor(AppTheme.primaryText.opacity(0.65))
                Spacer()
                Text("RESUME")
                    .font(AppTheme.meta(11))
                    .foregroundColor(.black)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(orange)
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(AppTheme.tabBarBg)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(orange.opacity(0.45), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Custom Tab Bar (respects safe area, doesn't block swipe up)
struct CustomTabBar: View {
    @Binding var selectedTab: Int

    private let tabs: [(icon: String, label: String)] = [
        ("chart.bar.fill", "Analyze"),
        ("bubble.left.fill", "Coach"),
        ("house.fill", "Home"),
        ("figure.run", "Run"),
        ("person.fill", "Profile")
    ]

    // Per-tab accent — matches each screen's theme color.
    private let tabColors: [Color] = [
        AppTheme.analyzePink,   // Analyze — hot pink
        Color(hex: "#00FF7F"),  // Coach — green (Z2)
        Color(hex: "#00CED1"),  // Home — blue (Z1)
        Color(hex: "#FF8C00"),  // Run — orange (Z4)
        Color.white             // Profile — white
    ]

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(AppTheme.primaryText.opacity(0.08))
                .frame(height: 1)

            HStack(spacing: 0) {
                ForEach(0..<tabs.count, id: \.self) { index in
                    TabBarItem(
                        icon: tabs[index].icon,
                        label: tabs[index].label,
                        color: tabColors[index],
                        isSelected: selectedTab == index
                    )
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTab = index
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .offset(y: 8)
        }
        .background(AppTheme.tabBarBg)
        .padding(.bottom, 0)
        .ignoresSafeArea(edges: .bottom)
        .offset(y: 10)
    }
}

struct TabBarItem: View {
    let icon: String
    let label: String
    let color: Color
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(AppTheme.bodyMedium(20))
                .foregroundColor(isSelected ? color : AppTheme.primaryText.opacity(0.58))
                .frame(width: 52, height: 32)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? color.opacity(0.22) : Color.clear)
                )

            Text(label)
                .font(AppTheme.tabBarLabelFont)
                .foregroundColor(isSelected ? color : AppTheme.primaryText.opacity(0.58))
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.18), value: isSelected)
    }
}

#Preview {
    MainTabView()
}
