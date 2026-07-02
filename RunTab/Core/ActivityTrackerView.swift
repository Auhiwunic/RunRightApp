//
//  ActivityTrackerView.swift
//  RunRightApp
//

import SwiftUI
import CoreLocation

struct ActivityTrackerView: View {
    @StateObject private var tracker = ActivityTracker()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Map
                RouteMapView(
                    coordinates: tracker.trackedLocations.map { $0.coordinate },
                    isTracking: tracker.isTracking
                )
                .frame(height: 300)
                
                // Stats
                ScrollView {
                    VStack(spacing: 16) {
                        // Live Stats
                        if let summary = tracker.liveSummary ?? tracker.finalSummary {
                            statsGrid(summary: summary)
                        } else {
                            emptyState
                        }
                        
                        // Control Button
                        controlButton
                        
                        // Reset button (when stopped with data)
                        if !tracker.isTracking && tracker.finalSummary != nil {
                            Button("Reset") {
                                tracker.reset()
                            }
                            .foregroundColor(.red)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Activity Tracker")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "location.fill")
                .font(.system(size: 40))
                .foregroundColor(.green)
            Text("Ready to Track")
                .font(.headline)
            Text("Tap Start to begin recording your activity")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 30)
    }
    
    private func statsGrid(summary: ActivitySummary) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            StatCard(
                icon: "figure.walk",
                title: "Distance",
                value: ActivityFormatter.formatDistance(summary.distance),
                color: .blue
            )
            StatCard(
                icon: "clock",
                title: "Duration",
                value: ActivityFormatter.formatDuration(summary.duration),
                color: Color(hex: "#00CED1")
            )
            StatCard(
                icon: "speedometer",
                title: "Avg Speed",
                value: ActivityFormatter.formatSpeed(summary.averageSpeed),
                color: .green
            )
            StatCard(
                icon: "arrow.up.right",
                title: "Elevation Gain",
                value: ActivityFormatter.formatElevation(summary.elevationGain),
                color: .purple
            )
        }
    }
    
    private var controlButton: some View {
        Button(action: {
            if tracker.isTracking {
                _ = tracker.stopTracking()
            } else {
                tracker.startTracking()
            }
        }) {
            HStack {
                Image(systemName: tracker.isTracking ? "stop.fill" : "play.fill")
                Text(tracker.isTracking ? "Stop" : "Start")
            }
            .font(.headline)
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(tracker.isTracking ? Color.red : Color.green)
            .cornerRadius(12)
        }
    }
}

struct StatCard: View {
    let icon: String
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

#Preview {
    ActivityTrackerView()
}

