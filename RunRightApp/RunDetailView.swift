//
//  RunDetailView.swift
//  RunRightApp
//
//  Detailed view of a single run: stats, pace breakdown, shoe used

import SwiftUI

struct RunDetailView: View {
    let run: RunSummaryDTO
    @Environment(\.dismiss) var dismiss

    private let accentLime = Color(hex: "#FF8C00")   // Run-tab orange (Z4)
    private let backgroundColor = Color(hex: "#1A1A1C")
    private let cardBackground = Color(hex: "#2A2A2E")
    private let cardBackgroundSoft = Color(hex: "#242428")

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
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .padding(8)
            }

            Text("Run Details")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)

            Spacer()

            Text(formattedDate)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    // MARK: - Distance Hero

    private var distanceHero: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.2f", run.distanceMiles))
                    .font(.system(size: 64, weight: .bold))
                    .foregroundColor(.white)
                Text("mi")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
            Text("Total Distance")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.4))
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
                .font(.system(size: 14))
                .foregroundColor(accentLime.opacity(0.7))
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .appRaisedSurface(fill: cardBackground, cornerRadius: 14, shadowRadius: 9, x: 5, y: 5)
    }

    // MARK: - Pace card

    private var paceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pace Breakdown")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)

            HStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text(formattedPace)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(accentLime)
                    Text("per mile")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
                }

                Spacer()

                VStack(spacing: 4) {
                    Text(formattedPacePerKm)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(.white)
                    Text("per km")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.4))
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
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(accentLime)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Shoe Used")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                Text(shoe)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
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
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 42, height: 42)
                Image(systemName: "calendar")
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.5))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(formattedFullDate)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(formattedTime)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.4))
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
