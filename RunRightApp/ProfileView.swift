//
//  ProfileView.swift
//  RunRightApp
//
//  Dark dashboard theme matching HomeView

import SwiftUI
import FirebaseAuth

struct ProfileView: View {
    @StateObject private var auth = FirebaseAuthManager.shared
    // The one real unit setting (drives Analyze and settings everywhere).
    // The old local @State here was decorative and reset on every tab switch.
    @AppStorage("useImperialUnits") private var useImperialUnits: Bool = true
    @AppStorage("gaita.appearance") private var appearance = "dark"
    @State private var showAuthSheet = false
    @ObservedObject private var subscriptions = SubscriptionManager.shared
    @State private var showPaywall = false
    @State private var stats: RunRepository.RunStats = .init()
    @State private var isLoading = true
    @State private var monthlyRunsByDay: [Int: Double] = [:]
    @State private var weeklyMiles: [Double] = Array(repeating: 0, count: 7)
    @State private var runStreak: Int = 0
    @State private var dailyGoalMiles: Double = 3.0
    @State private var scrollOffset: CGFloat = 0   // drives the header fade

    // Account deletion (App Store Guideline 5.1.1(v))
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var showPasswordReauth = false
    @State private var reauthPassword = ""
    @State private var deleteError: String?

    // Data export (GDPR / CCPA right to access)
    @State private var isExporting = false
    @State private var exportFile: ExportFile?
    @State private var exportError: String?

    private let accentLime = AppTheme.accentColor
    private let backgroundColor = AppTheme.bgColor
    @State private var legalDoc: LegalDoc?
    private let cardBackground = AppTheme.cardBg
    private let cardBackgroundSoft = AppTheme.cardBgAlt
    
    var body: some View {
        NavigationStack {
        ZStack {
            backgroundColor.ignoresSafeArea()
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    ScrollOffsetReader(space: "profileScroll")

                    // Header — fades out as the page scrolls down
                    profileHeader
                        .opacity(scrollFadeOpacity(scrollOffset))
                        .padding(.horizontal, 20)
                        .padding(.top, 20)

                    // Stats row
                    statsRow
                        .padding(.horizontal, 20)

                    // Calendar
                    calendarCard
                        .padding(.horizontal, 20)

                    // Weekly Mileage
                    weeklyMileageCard
                        .padding(.horizontal, 20)

                    // Settings
                    settingsCard
                        .padding(.horizontal, 20)

                    // Concise sign-out + delete account (only when signed in with a real account)
                    if auth.isAuthenticated && !auth.isAnonymous {
                        Button(action: {
                            auth.signOut()
                            Task { await auth.signInAnonymouslyIfNeeded() }
                        }) {
                            Text("SIGN OUT")
                                .font(AppTheme.head(13))
                                .foregroundColor(AppTheme.primaryText.opacity(0.5))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 4)

                        Button(action: { Task { await exportData() } }) {
                            HStack(spacing: 8) {
                                if isExporting { ProgressView().tint(AppTheme.primaryText.opacity(0.6)) }
                                Text(isExporting ? "PREPARING…" : "EXPORT MY DATA")
                                    .font(AppTheme.head(13))
                                    .foregroundColor(AppTheme.primaryText.opacity(0.5))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .disabled(isExporting || isDeleting)
                        .padding(.horizontal, 20)

                        Button(action: { showDeleteConfirm = true }) {
                            HStack(spacing: 8) {
                                if isDeleting { ProgressView().tint(Color(hex: "#FF453A")) }
                                Text(isDeleting ? "DELETING…" : "DELETE ACCOUNT")
                                    .font(AppTheme.head(13))
                                    .foregroundColor(Color(hex: "#FF453A"))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .disabled(isDeleting)
                        .padding(.horizontal, 20)
                    }

                    // App version
                    Text(appVersionText)
                        .font(AppTheme.bodyMedium(11))
                        .foregroundColor(AppTheme.primaryText.opacity(0.2))
                        .padding(.top, 4)

                    // Bottom padding for tab bar
                    Spacer().frame(height: AppTheme.tabBarHeight + 24)
                }
            }
            .coordinateSpace(name: "profileScroll")
            .onPreferenceChange(ScrollOffsetKey.self) { scrollOffset = $0 }
            .blur(radius: auth.isAnonymous ? 18 : 0)
            .disabled(auth.isAnonymous)

            // Locked behind sign-in: stats are hidden until the user signs in.
            if auth.isAnonymous {
                signInGate
            }
        }
        .navigationBarHidden(true)
        } // NavigationStack
        .sheet(isPresented: $showAuthSheet) {
            AuthSheet()
                .environmentObject(auth)
                .presentationDragIndicator(.visible)
        }
        .task {
            await loadStats()
        }
        .refreshable {
            await loadStats()
        }
        .onReceive(NotificationCenter.default.publisher(for: .runSaved)) { _ in
            Task { await loadStats() }
        }
        .confirmationDialog(
            "Delete your account?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                Task { await performDelete() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your account and all your runs, scans, plans, and synced data. This can't be undone.")
        }
        .alert("Confirm your password", isPresented: $showPasswordReauth) {
            SecureField("Password", text: $reauthPassword)
            Button("Delete Account", role: .destructive) {
                Task { await reauthWithPasswordAndDelete() }
            }
            Button("Cancel", role: .cancel) { reauthPassword = "" }
        } message: {
            Text("For your security, please re-enter your password to delete your account.")
        }
        .alert("Couldn't delete account", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .sheet(item: $exportFile) { file in
            ShareSheet(items: [file.url])
        }
        .alert("Couldn't export data", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Gaita v\(version) (\(build))"
    }

    // MARK: - Data export (right to access)

    /// Gather the signed-in user's data (profile, runs, shoes + scans) into a JSON
    /// file and present a share sheet so they can save or send a copy of it.
    private func exportData() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        isExporting = true
        defer { isExporting = false }

        func jsonObject<T: Encodable>(_ value: T) -> Any {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(value),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
            return obj
        }

        var export: [String: Any] = [
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "account": [
                "uid": uid,
                "email": Auth.auth().currentUser?.email ?? "",
                "displayName": Auth.auth().currentUser?.displayName ?? ""
            ]
        ]

        if let settings = try? await UserSettingsRepository.shared.load(uid: uid) {
            export["profile"] = settings.toFirestore()
        }
        if let runs = try? await RunRepository.shared.fetchAllRuns(uid: uid) {
            export["runs"] = runs.map { jsonObject($0) }
        }
        if let shoeNames = try? await ScanRepository.shared.fetchShoeNames(uid: uid) {
            var shoes: [[String: Any]] = []
            for name in shoeNames {
                let scans = (try? await ScanRepository.shared.fetchScans(uid: uid, shoeName: name)) ?? []
                shoes.append(["shoe": name, "scans": scans.map { jsonObject($0) }])
            }
            export["shoes"] = shoes
        }
        // Weekly plans are stored in Firestore and removed on account deletion, so
        // a complete export must include them too (#2).
        if let plans = try? await PlanRepository.shared.fetchAllPlansForExport(uid: uid), !plans.isEmpty {
            export["plans"] = plans
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: export, options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Gaita-data-export.json")
            try data.write(to: url, options: .atomic)
            exportFile = ExportFile(url: url)
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - Account deletion flow

    private func performDelete() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await auth.deleteAccount()
            await auth.signInAnonymouslyIfNeeded()   // return to guest state
        } catch let AccountDeletionError.requiresRecentLogin(provider) {
            switch provider {
            case "google.com":
                do {
                    try await auth.reauthenticateWithGoogle()
                    try await auth.deleteAccount(reauthenticated: true)
                    await auth.signInAnonymouslyIfNeeded()
                } catch {
                    deleteError = error.localizedDescription
                }
            case "apple.com":
                do {
                    try await auth.reauthenticateWithApple()
                    try await auth.deleteAccount(reauthenticated: true)
                    await auth.signInAnonymouslyIfNeeded()
                } catch {
                    deleteError = error.localizedDescription
                }
            case "password":
                showPasswordReauth = true
            default:
                deleteError = "Please sign out and sign back in, then delete your account."
            }
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private func reauthWithPasswordAndDelete() async {
        isDeleting = true
        defer { isDeleting = false; reauthPassword = "" }
        do {
            try await auth.reauthenticateWithEmail(password: reauthPassword)
            try await auth.deleteAccount(reauthenticated: true)
            await auth.signInAnonymouslyIfNeeded()
        } catch {
            deleteError = error.localizedDescription
        }
    }

    private func loadStats() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        isLoading = true

        async let allRunsResult = (try? await RunRepository.shared.fetchAllRuns(uid: uid))
        async let monthRunsResult = (try? await RunRepository.shared.fetchRunsForMonth(uid: uid, date: Date()))
        async let weekRunsResult = (try? await RunRepository.shared.fetchRunsForWeek(uid: uid, date: Date()))

        let (allRuns, monthRuns, weekRuns) = await (allRunsResult, monthRunsResult, weekRunsResult)

        if let allRuns {
            stats = RunRepository.computeStats(from: allRuns)
            runStreak = HomeViewModel.computeStreak(from: allRuns)
        }

        // Monthly heatmap data
        let calendar = Calendar.current
        var dayMap: [Int: Double] = [:]
        for run in (monthRuns ?? []) {
            let day = calendar.component(.day, from: run.startTime)
            dayMap[day, default: 0] += run.distanceMiles
        }
        monthlyRunsByDay = dayMap

        // Weekly miles
        weeklyMiles = RunRepository.weeklyMiles(from: weekRuns ?? [], weekOf: Date())

        // Daily goal drives the calendar heatmap intensity.
        if let settings = try? await UserSettingsRepository.shared.load(uid: uid) {
            dailyGoalMiles = settings.dailyGoalMiles
        }

        isLoading = false
    }

    // MARK: - Profile Header
    private var profileHeader: some View {
        HStack {
            Text("Profile")
                .font(AppTheme.display(32))
                .foregroundColor(AppTheme.primaryText)
            Spacer()
            if auth.isAuthenticated && !auth.isAnonymous {
                avatarBadge
            }
        }
    }

    /// Top-right avatar shown once signed in (first initial of name / email).
    private var avatarBadge: some View {
        let source = Auth.auth().currentUser?.displayName?.isEmpty == false
            ? (Auth.auth().currentUser?.displayName ?? "")
            : (Auth.auth().currentUser?.email ?? "")
        let initial = String(source.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
        return Text(initial.isEmpty ? "U" : initial)
            .font(AppTheme.head(16))
            .foregroundColor(AppTheme.bgColor)
            .frame(width: 40, height: 40)
            .background(Circle().fill(AppTheme.primaryText))
    }

    // MARK: - Sign-in gate (anonymous users)
    private var signInGate: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.crop.circle")
                .font(AppTheme.body(54))
                .foregroundColor(AppTheme.primaryText.opacity(0.9))
            Text("Sign in to view your stats")
                .font(AppTheme.head(19))
                .foregroundColor(AppTheme.primaryText)
                .multilineTextAlignment(.center)
            Button(action: { showAuthSheet = true }) {
                Text("Sign In")
                    .font(AppTheme.head(15))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(AppTheme.accentColor)
                    .cornerRadius(14)
            }
            .padding(.horizontal, 44)
        }
        .padding(.horizontal, 24)
    }

    // MARK: - Stats Row
    private var statsRow: some View {
        HStack(spacing: 10) {
            profileStatBox(value: "\(stats.totalRuns)", label: "Total Runs")
            profileStatBox(value: String(format: "%.0f", stats.totalMiles), label: "Miles")
            profileStatBox(value: String(format: "%.0f", stats.totalHours), label: "Hours")
            profileStatBox(value: "\(runStreak)", label: "Streak")
        }
    }
    
    private func profileStatBox(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(AppTheme.display(24))
                .foregroundColor(accentLime)
            Text(label.uppercased())
                .font(AppTheme.meta(10))
                .foregroundColor(AppTheme.primaryText.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .appRaisedSurface(fill: cardBackground, cornerRadius: 16, shadowRadius: 9, x: 5, y: 5)
    }
    
    // MARK: - Calendar Card
    private var calendarCard: some View {
        let monthName: String = {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMMM"
            return formatter.string(from: Date())
        }()

        return VStack(alignment: .leading, spacing: 12) {
            Text(monthName.uppercased())
                .font(AppTheme.head(16))
                .foregroundColor(AppTheme.primaryText)
            MonthlyHeatmapView(runsByDay: monthlyRunsByDay, dailyGoalMiles: dailyGoalMiles)
        }
        .padding(16)
        .appRaisedSurface(fill: cardBackground, cornerRadius: 20)
    }
    
    // MARK: - Weekly Mileage Chart
    private var weeklyMileageCard: some View {
        let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let miles: [CGFloat] = weeklyMiles.map { CGFloat($0) }
        let totalMiles = miles.reduce(0, +)
        let maxMile = max(miles.max() ?? 1, 1)

        // Highlight today (Mon=0 ... Sun=6)
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: Date())
        let todayIndex: Int = {
            switch weekday {
            case 2: return 0
            case 3: return 1
            case 4: return 2
            case 5: return 3
            case 6: return 4
            case 7: return 5
            default: return 6
            }
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("THIS WEEK")
                    .font(AppTheme.head(16))
                    .foregroundColor(AppTheme.primaryText)
                Spacer()
                Text("\(String(format: "%.1f", totalMiles)) mi")
                    .font(AppTheme.bodySemibold(13))
                    .foregroundColor(accentLime)
            }

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(0..<7, id: \.self) { i in
                    VStack(spacing: 4) {
                        if miles[i] > 0 {
                            Text(String(format: "%.1f", miles[i]))
                                .font(AppTheme.bodySemibold(9))
                                .foregroundColor(AppTheme.primaryText.opacity(0.5))
                        }

                        RoundedRectangle(cornerRadius: 4)
                            .fill(miles[i] > 0 ? accentLime : (i == todayIndex ? accentLime.opacity(0.15) : cardBackgroundSoft))
                            .frame(height: miles[i] > 0 ? max(16, CGFloat(miles[i] / maxMile) * 80) : 8)

                        Text(days[i])
                            .font(AppTheme.bodyMedium(10))
                            .foregroundColor(i == todayIndex ? accentLime : AppTheme.primaryText.opacity(0.35))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 110)
        }
        .padding(16)
        .appRaisedSurface(fill: cardBackground, cornerRadius: 20)
    }
    
    // MARK: - Settings
    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PREFERENCES")
                .font(AppTheme.head(16))
                .foregroundColor(AppTheme.primaryText)
                .padding(.bottom, 8)

            // Premium
            if subscriptions.isPremium {
                settingsRow(label: "Gaita Premium", icon: "checkmark.seal.fill") {
                    Text("Active")
                        .font(AppTheme.bodySemibold(12))
                        .foregroundColor(AppTheme.accentColor)
                }
            } else {
                Button(action: { showPaywall = true }) {
                    settingsRow(label: "Get Premium", icon: "sparkles") {
                        Text("Upgrade")
                            .font(AppTheme.bodySemibold(12))
                            .foregroundColor(AppTheme.onAccentPrimary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Capsule().fill(AppTheme.accentColor))
                    }
                }
                .buttonStyle(.plain)
            }

            Rectangle()
                .fill(AppTheme.primaryText.opacity(0.06))
                .frame(height: 1)

            // Units
            settingsRow(label: "Units", icon: "ruler") {
                HStack(spacing: 0) {
                    unitButton(text: "mi", selected: useImperialUnits) { useImperialUnits = true }
                    unitButton(text: "km", selected: !useImperialUnits) { useImperialUnits = false }
                }
                .appRaisedBox(cornerRadius: 8)
            }

            Rectangle()
                .fill(AppTheme.primaryText.opacity(0.06))
                .frame(height: 1)

            // Theme (white mode)
            settingsRow(label: "Theme", icon: "circle.lefthalf.filled") {
                HStack(spacing: 0) {
                    themeButton(text: "dark", selected: appearance != "light") { appearance = "dark" }
                    themeButton(text: "light", selected: appearance == "light") { appearance = "light" }
                }
                .appRaisedBox(cornerRadius: 8)
            }

            ForEach([LegalDoc.privacyPolicy, .terms, .licenses]) { doc in
                Rectangle()
                    .fill(AppTheme.primaryText.opacity(0.06))
                    .frame(height: 1)
                Button(action: { legalDoc = doc }) {
                    settingsRow(label: doc.title, icon: "doc.text") {
                        Image(systemName: "chevron.right").accessibilityHidden(true)
                            .font(AppTheme.bodySemibold(12))
                            .foregroundColor(AppTheme.primaryText.opacity(0.3))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .appRaisedSurface(fill: cardBackground, cornerRadius: 20)
        .sheet(item: $legalDoc) { doc in
            LegalDocView(doc: doc)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView()
        }
    }
    
    private func settingsRow<Content: View>(label: String, icon: String, @ViewBuilder trailing: () -> Content) -> some View {
        HStack {
            Image(systemName: icon)
                .font(AppTheme.body(13))
                .foregroundColor(accentLime)
                .frame(width: 24)
            Text(label)
                .font(AppTheme.bodyMedium(14))
                .foregroundColor(AppTheme.primaryText)
            Spacer()
            trailing()
        }
        .padding(.vertical, 12)
    }
    
    private func unitButton(text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { action() } }) {
            Text(text)
                .font(AppTheme.bodySemibold(12))
                .foregroundColor(selected ? AppTheme.bgColor : AppTheme.primaryText.opacity(0.5))
                .frame(width: 36, height: 28)
                .background(selected ? accentLime : Color.clear)
                .cornerRadius(6)
        }
    }

    private func themeButton(text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { action() } }) {
            Text(text)
                .font(AppTheme.bodySemibold(12))
                .foregroundColor(selected ? AppTheme.bgColor : AppTheme.secondaryText)
                .frame(width: 46, height: 28)
                .background(selected ? accentLime : Color.clear)
                .cornerRadius(6)
        }
    }
}

// MARK: - Data-export helpers

/// Identifiable wrapper so the export file can drive a `.sheet(item:)`.
struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Minimal UIActivityViewController bridge for sharing the export file.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#Preview {
    ProfileView()
}
