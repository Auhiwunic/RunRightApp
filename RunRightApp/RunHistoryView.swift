//
//  RunHistoryView.swift
//  RunRightApp
//
//  Displays all past runs grouped by month, tapping opens RunDetailView

import SwiftUI
import FirebaseAuth

struct RunHistoryView: View {
    @Environment(\.dismiss) var dismiss
    @State private var runs: [RunSummaryDTO] = []
    @State private var isLoading = true

    private let accentLime = AppTheme.accentColor
    private let backgroundColor = AppTheme.bgColor
    private let cardBackground = AppTheme.cardBg

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                            .font(AppTheme.bodyMedium(16))
                            .foregroundColor(AppTheme.primaryText)
                            .padding(8)
                    }

                    Text("Run History")
                        .font(AppTheme.head(24))
                        .foregroundColor(AppTheme.primaryText)

                    Spacer()

                    Text("\(runs.count) runs")
                        .font(AppTheme.bodyMedium(13))
                        .foregroundColor(AppTheme.primaryText.opacity(0.4))
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                if isLoading {
                    Spacer()
                    ProgressView()
                        .tint(accentLime)
                    Spacer()
                } else if runs.isEmpty {
                    Spacer()
                    emptyState
                    Spacer()
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 8) {
                            ForEach(groupedRuns, id: \.month) { group in
                                // Month header
                                Text(group.month)
                                    .font(AppTheme.bodySemibold(13))
                                    .foregroundColor(accentLime)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 20)
                                    .padding(.top, 12)

                                ForEach(group.runs, id: \.runId) { run in
                                    NavigationLink(destination: RunDetailView(run: run)) {
                                        runRow(run)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            Spacer().frame(height: AppTheme.tabBarHeight + 24)
                        }
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .task {
            await loadRuns()
        }
    }

    private func loadRuns() async {
        // Clear the spinner on every exit path — a nil currentUser (transient
        // signed-out window) used to return before isLoading was reset, leaving
        // the view stuck on an infinite ProgressView with no empty state.
        defer { isLoading = false }
        isLoading = true
        guard let uid = Auth.auth().currentUser?.uid else { return }
        runs = (try? await RunRepository.shared.fetchAllRuns(uid: uid)) ?? []
    }

    // MARK: - Grouped runs by month

    private struct MonthGroup {
        let month: String
        let runs: [RunSummaryDTO]
    }

    private var groupedRuns: [MonthGroup] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        var groups: [(key: String, runs: [RunSummaryDTO])] = []
        var currentKey = ""
        var currentRuns: [RunSummaryDTO] = []

        for run in runs {
            let key = formatter.string(from: run.startTime)
            if key != currentKey {
                if !currentRuns.isEmpty {
                    groups.append((key: currentKey, runs: currentRuns))
                }
                currentKey = key
                currentRuns = [run]
            } else {
                currentRuns.append(run)
            }
        }
        if !currentRuns.isEmpty {
            groups.append((key: currentKey, runs: currentRuns))
        }

        return groups.map { MonthGroup(month: $0.key, runs: $0.runs) }
    }

    // MARK: - Row

    private func runRow(_ run: RunSummaryDTO) -> some View {
        HStack(spacing: 14) {
            // Run icon
            ZStack {
                Circle()
                    .fill(accentLime.opacity(0.12))
                    .frame(width: 42, height: 42)
                Image(systemName: "figure.run")
                    .font(AppTheme.bodySemibold(16))
                    .foregroundColor(accentLime)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(dateLabel(run.startTime))
                    .font(AppTheme.bodySemibold(14))
                    .foregroundColor(AppTheme.primaryText)

                HStack(spacing: 12) {
                    Label(String(format: "%.2f mi", run.distanceMiles), systemImage: "location.fill")
                    Label(formatDuration(run.durationSeconds), systemImage: "clock")
                    if let shoe = run.shoeName, !shoe.isEmpty {
                        Label(shoe, systemImage: "shoe.fill")
                    }
                }
                .font(AppTheme.bodyMedium(11))
                .foregroundColor(AppTheme.primaryText.opacity(0.4))
            }

            Spacer()

            // Pace
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatPace(run.avgSpeedMps))
                    .font(AppTheme.head(15))
                    .foregroundColor(AppTheme.primaryText)
                Text("/mi")
                    .font(AppTheme.body(10))
                    .foregroundColor(AppTheme.primaryText.opacity(0.35))
            }

            Image(systemName: "chevron.right")
                .font(AppTheme.bodyMedium(12))
                .foregroundColor(AppTheme.primaryText.opacity(0.2))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .appRaisedSurface(fill: cardBackground, cornerRadius: 14, shadowRadius: 9, x: 5, y: 5)
        .padding(.horizontal, 16)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.run.circle")
                .font(AppTheme.body(56))
                .foregroundColor(accentLime.opacity(0.3))
            Text("No runs yet")
                .font(AppTheme.bodySemibold(18))
                .foregroundColor(AppTheme.primaryText)
            Text("Complete your first run to see it here!")
                .font(AppTheme.body(13))
                .foregroundColor(AppTheme.primaryText.opacity(0.4))
        }
    }

    // MARK: - Helpers

    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "'Today,' h:mm a"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "'Yesterday,' h:mm a"
        } else {
            formatter.dateFormat = "EEE, MMM d 'at' h:mm a"
        }
        return formatter.string(from: date)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatPace(_ speedMps: Double) -> String {
        guard speedMps > 0.5 else { return "--:--" }
        let secondsPerMile = 1609.344 / speedMps
        guard secondsPerMile < 1800 else { return "--:--" }
        let mins = Int(secondsPerMile) / 60
        let secs = Int(secondsPerMile) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

#Preview {
    RunHistoryView()
}
