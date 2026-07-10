//
//  MainTabView.swift
//  RunRightApp
//

import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 2 // Home is center (index 2)
    @ObservedObject private var run = RunSession.shared
    @ObservedObject private var remoteConfig = RemoteConfigManager.shared
    @State private var showCancelToast = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            // Always-visible app background — never exposes the black UIKit window
            AppTheme.bgColor.ignoresSafeArea()

            // Tabs are built once on first visit and kept alive (see
            // PersistentTabContent). Previously this was a `switch` that destroyed
            // and rebuilt the whole tab view tree on every tap — that teardown +
            // reconstruction (plus each view's data reload) was the visible freeze
            // when switching tabs. Now a repeat switch is just an opacity toggle.
            PersistentTabContent(selectedTab: $selectedTab)
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

            // Ops maintenance banner (Remote Config `maintenance_message`). Empty
            // string = hidden. This is what makes that kill-switch actually visible.
            if !remoteConfig.maintenanceMessage.isEmpty {
                VStack(spacing: 0) {
                    maintenanceBanner(remoteConfig.maintenanceMessage)
                    Spacer()
                }
            }

            // Brief note when an idle run was auto-cancelled (nothing to save).
            if showCancelToast {
                VStack(spacing: 0) {
                    cancelToast
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Adaptive plan: reconcile the week with what actually happened — on
        // launch, on every return to foreground, and after each saved run.
        .task { await AdaptivePlanEngine.shared.evaluateIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await AdaptivePlanEngine.shared.evaluateIfNeeded() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .runSaved)) { _ in
            Task { await AdaptivePlanEngine.shared.evaluateIfNeeded() }
        }
        .onChange(of: run.autoCancelledNotice) { _, cancelled in
            guard cancelled else { return }
            run.autoCancelledNotice = false
            withAnimation { showCancelToast = true }
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await MainActor.run { withAnimation { showCancelToast = false } }
            }
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

    // MARK: - Maintenance banner (ops-set via Remote Config)
    private func maintenanceBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(AppTheme.meta(12))
            Text(text)
                .font(AppTheme.meta(12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(.black)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppTheme.accentColor)
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    // MARK: - Idle auto-cancel toast
    private var cancelToast: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz.fill")
                .font(AppTheme.meta(12))
            Text("Run cancelled after inactivity")
                .font(AppTheme.meta(12))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundColor(AppTheme.primaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppTheme.tabBarBg)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppTheme.accentColor.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - Running banner (shown across tabs while a run is minimized)
    private var runningBanner: some View {
        let orange = AppTheme.accentColor
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

// MARK: - Persistent tab content
//
// Keeps each tab alive after its first visit instead of destroying and
// rebuilding it on every switch. A tab is built lazily the first time it is
// selected (no upfront cost for tabs you never open), then held in the ZStack
// and shown/hidden by opacity — so returning to a tab is instant and its data
// loads run once, not on every tap.
//
// Refresh after persistence stays correct because each tab is event-driven:
// Home (HomeViewModel.shared) and Profile observe `.runSaved`; Coach observes
// `.analysisSaved`; Run observes `.runSaved`; Analyze reads live shared
// singletons (VideoProcessor/AnalysisHistoryStore). Nothing relies on the old
// "rebuilt on every switch" behavior to refresh.
private struct PersistentTabContent: View {
    @Binding var selectedTab: Int
    // Home (index 2) is the launch tab, so it is loaded from the start.
    @State private var loaded: Set<Int> = [2]

    var body: some View {
        ZStack {
            ForEach(loaded.sorted(), id: \.self) { index in
                tab(index)
                    .opacity(index == selectedTab ? 1 : 0)
                    .allowsHitTesting(index == selectedTab)
                    .zIndex(index == selectedTab ? 1 : 0)
                    .accessibilityHidden(index != selectedTab)
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            loaded.insert(newValue)
        }
    }

    @ViewBuilder
    private func tab(_ index: Int) -> some View {
        switch index {
        case 0: AnalyzeView()
        case 1: CoachTabView()
        case 3: RunView()
        case 4: ProfileView()
        default: HomeView(onOpenCoach: { selectedTab = 1 })
        }
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

    // Single unified UI accent — one signature cyan across every tab. The
    // per-tab zone colors were retired: color now lives only in data (charts,
    // dials, heatmaps, zones, cue tiles), never in the chrome.
    private let tabColors: [Color] = [
        AppTheme.accentColor,   // Analyze
        AppTheme.accentColor,   // Coach
        AppTheme.accentColor,   // Home
        AppTheme.accentColor,   // Run
        AppTheme.accentColor    // Profile
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    MainTabView()
}
