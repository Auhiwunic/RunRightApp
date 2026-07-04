//
//  RunDetailView.swift
//  RunRightApp
//
//  Detailed view of a single run: stats, pace breakdown, shoe used

import SwiftUI

struct RunDetailView: View {
    let run: RunSummaryDTO
    @Environment(\.dismiss) var dismiss

    private let accentLime = AppTheme.accentColor
    private let backgroundColor = AppTheme.bgColor
    private let cardBackground = AppTheme.cardBg
    private let cardBackgroundSoft = AppTheme.cardBgAlt

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    // Header
                    header
                        .padding(.horizontal, 20)
                        .padding(.top, 16)

                    // Big distance hero
                    distanceHero
                        .padding(.horizontal, 20)

                    // Stats grid
                    statsGrid
                        .padding(.horizontal, 20)

                    // Pace analysis card
                    paceCard
                        .padding(.horizontal, 20)

                    // Shoe card (if applicable)
                    if let shoe = run.shoeName, !shoe.isEmpty {
                        shoeCard(shoe)
                            .padding(.horizontal, 20)
                    }

                    // Timestamp card
                    timestampCard
                        .padding(.horizontal, 20)

                    Spacer().frame(height: AppTheme.tabBarHeight + 24)
                }
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(AppTheme.bodyMedium(16))
                    .foregroundColor(AppTheme.primaryText)
                    .padding(8)
            }

            Text("Run Details")
                .font(AppTheme.head(24))
                .foregroundColor(AppTheme.primaryText)

            Spacer()

            Text(formattedDate)
                .font(AppTheme.bodyMedium(12))
                .foregroundColor(AppTheme.primaryText.opacity(0.4))
        }
    }

    // MARK: - Distance Hero

    private var distanceHero: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.2f", run.distanceMiles))
                    .font(AppTheme.display(64))
                    .foregroundColor(AppTheme.primaryText)
                Text("mi")
                    .font(AppTheme.bodyMedium(22))
                    .foregroundColor(AppTheme.primaryText.opacity(0.5))
            }
            Text("Total Distance")
                .font(AppTheme.body(13))
                .foregroundColor(AppTheme.primaryText.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .appRaisedSurface(fill: cardBackground, cornerRadius: 20)
    }

    // MARK: - Stats Grid

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            statCell(value: formattedDuration, label: "Duration", icon: "clock")
            statCell(value: formattedPace, label: "Avg Pace", icon: "speedometer")
            statCell(value: formattedSpeed, label: "Avg Speed", icon: "gauge.with.dots.needle.67percent")
            statCell(value: String(format: "%.0f", run.distanceMeters), label: "Meters", icon: "ruler")
            statCell(value: run.avgHeartRateBpm.map { "\($0)" } ?? "—", label: "Avg HR", icon: "heart.fill")
            statCell(value: formattedCalories, label: "Est. Cal", icon: "flame.fill")
        }
    }

    private func statCell(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(AppTheme.body(14))
                .foregroundColor(accentLime.opacity(0.7))
            Text(value)
                .font(AppTheme.head(18))
                .foregroundColor(AppTheme.primaryText)
            Text(label)
                .font(AppTheme.bodyMedium(10))
                .foregroundColor(AppTheme.primaryText.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .appRaisedSurface(fill: cardBackground, cornerRadius: 14, shadowRadius: 9, x: 5, y: 5)
    }

    // MARK: - Pace card

    private var paceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pace Breakdown")
                .font(AppTheme.bodySemibold(16))
                .foregroundColor(AppTheme.primaryText)

            HStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text(formattedPace)
                        .font(AppTheme.display(28))
                        .foregroundColor(accentLime)
                    Text("per mile")
                        .font(AppTheme.body(11))
                        .foregroundColor(AppTheme.primaryText.opacity(0.4))
                }

                Spacer()

                VStack(spacing: 4) {
                    Text(formattedPacePerKm)
                        .font(AppTheme.display(28))
                        .foregroundColor(AppTheme.primaryText)
                    Text("per km")
                        .font(AppTheme.body(11))
                        .foregroundColor(AppTheme.primaryText.opacity(0.4))
                }

                Spacer()
            }
        }
        .padding(16)
        .appRaisedSurface(fill: cardBackground, cornerRadius: 20)
    }

    // MARK: - Shoe card

    private func shoeCard(_ shoe: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(accentLime.opacity(0.12))
                    .frame(width: 42, height: 42)
                Image(systemName: "shoe.fill")
                    .font(AppTheme.bodySemibold(16))
                    .foregroundColor(accentLime)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Shoe Used")
                    .font(AppTheme.body(11))
                    .foregroundColor(AppTheme.primaryText.opacity(0.4))
                Text(shoe)
                    .font(AppTheme.bodySemibold(15))
                    .foregroundColor(AppTheme.primaryText)
            }

            Spacer()
        }
        .padding(16)
        .appRaisedSurface(fill: cardBackground, cornerRadius: 16, shadowRadius: 9, x: 5, y: 5)
    }

    // MARK: - Timestamp card

    private var timestampCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(AppTheme.primaryText.opacity(0.06))
                    .frame(width: 42, height: 42)
                Image(systemName: "calendar")
                    .font(AppTheme.body(16))
                    .foregroundColor(AppTheme.primaryText.opacity(0.5))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(formattedFullDate)
                    .font(AppTheme.bodySemibold(14))
                    .foregroundColor(AppTheme.primaryText)
                Text(formattedTime)
                    .font(AppTheme.body(12))
                    .foregroundColor(AppTheme.primaryText.opacity(0.4))
            }

            Spacer()
        }
        .padding(16)
        .appRaisedSurface(fill: cardBackground, cornerRadius: 16, shadowRadius: 9, x: 5, y: 5)
    }

    // MARK: - Formatters

    private var formattedDate: String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: run.startTime)
    }

    private var formattedFullDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy"
        return f.string(from: run.startTime)
    }

    private var formattedTime: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: run.startTime)
    }

    private var formattedDuration: String {
        let total = Int(run.durationSeconds)
        let hrs = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hrs > 0 {
            return String(format: "%d:%02d:%02d", hrs, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
    }

    private var formattedPace: String {
        guard run.avgSpeedMps > 0.5 else { return "--:--" }
        let secondsPerMile = 1609.344 / run.avgSpeedMps
        guard secondsPerMile < 1800 else { return "--:--" }
        let mins = Int(secondsPerMile) / 60
        let secs = Int(secondsPerMile) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private var formattedPacePerKm: String {
        guard run.avgSpeedMps > 0.5 else { return "--:--" }
        let secondsPerKm = 1000.0 / run.avgSpeedMps
        guard secondsPerKm < 1200 else { return "--:--" }
        let mins = Int(secondsPerKm) / 60
        let secs = Int(secondsPerKm) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private var formattedSpeed: String {
        guard run.avgSpeedMps > 0.3 else { return "—" }
        let mph = run.avgSpeedMps * 2.23694
        return String(format: "%.1f", mph)
    }

    private var formattedCalories: String {
        // Rough estimate: ~100 cal per mile
        let cal = run.distanceMiles * 100
        return "\(Int(cal))"
    }
}

#Preview {
    RunDetailView(run: RunSummaryDTO(
        runId: "preview",
        startTime: Date(),
        distanceMeters: 5200,
        durationSeconds: 1680,
        avgSpeedMps: 3.1,
        avgHeartRateBpm: 155,
        shoeName: "Nike Pegasus 40"
    ))
}
