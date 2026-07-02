//
//  RunView.swift
//  RunRightApp
//
//  Pixel-perfect match to HTML prototype with ActivityTracker backend

import SwiftUI
import Combine
import AVFoundation

struct RunView: View {
    @StateObject private var tracker = ActivityTracker()
    @StateObject private var voiceAssistant = VoiceAssistantManager.shared
    @StateObject private var zonesManager = HeartRateZonesManager.shared
    
    @State private var todaysRunEnabled = true
    @State private var selectedShoe = "Nike Pegasus 40"
    @State private var showZonesOnboarding = false
    @State private var showVoiceSettings = false
    @State private var showActiveRun = false
    @State private var updateTimer: Timer?
    @State private var uiRefreshTimer: Timer?
    @State private var elapsedTime: TimeInterval = 0
    @State private var runStartTime: Date?
    @State private var pausedElapsedTime: TimeInterval = 0
    
    var body: some View {
        ZStack {
            AppTheme.bgColor.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Top Stats Bar
                topStatsBar
                
                // Map Area with START button
                mapArea
                
                // Bottom Section
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        bottomSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 120)
                }
            }
        }
        .sheet(isPresented: $showZonesOnboarding) {
            TrainingZonesOnboarding()
        }
        .sheet(isPresented: $showVoiceSettings) {
            VoiceSettingsView()
        }
        .fullScreenCover(isPresented: $showActiveRun) {
            ActiveRunView(
                tracker: tracker,
                voiceAssistant: voiceAssistant,
                elapsedTime: $elapsedTime
            )
        }
        .onChange(of: tracker.isTracking) { _, isTracking in
            // When tracking stops (from ActiveRunView), dismiss the cover and clean up
            if !isTracking {
                showActiveRun = false
                updateTimer?.invalidate()
                uiRefreshTimer?.invalidate()
                runStartTime = nil
            }
        }
        .onDisappear {
            updateTimer?.invalidate()
            uiRefreshTimer?.invalidate()
        }
    }
    
    // MARK: - Run Control Functions
    
    private func startRun() {
        // Reset everything for a fresh run
        tracker.reset()
        tracker.startTracking()
        voiceAssistant.resetForNewRun()
        
        // Announce run start if voice is enabled
        if voiceAssistant.settings.isEnabled {
            voiceAssistant.announceRunStart()
        }
        
        // Record start time for real-time duration
        runStartTime = Date()
        elapsedTime = 0
        pausedElapsedTime = 0
        
        // UI refresh timer - updates duration every second
        uiRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [self] _ in
            if tracker.isTracking && !tracker.isPaused {
                if let startTime = runStartTime {
                    elapsedTime = pausedElapsedTime + Date().timeIntervalSince(startTime)
                }
            } else if tracker.isPaused {
                // Save elapsed time when paused and reset start time
                if runStartTime != nil {
                    pausedElapsedTime = elapsedTime
                    runStartTime = nil
                }
            } else if tracker.isTracking && runStartTime == nil {
                // Resumed - set new start time
                runStartTime = Date()
            }
        }
        
        // Voice updates timer - announces stats periodically (less frequent to save battery)
        updateTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            if let summary = tracker.liveSummary, !tracker.isPaused {
                voiceAssistant.updateRunProgress(
                    distance: summary.distance,
                    duration: elapsedTime,
                    pace: summary.averageSpeed,
                    heartRate: nil
                )
            }
        }
        
        // Show the full-screen active run view
        showActiveRun = true
    }
    
    
    // MARK: - Top Stats Bar
    private var topStatsBar: some View {
        ZStack {
            // Gradient background
            ZStack {
                RadialGradient(
                    colors: [Color(hex: "#1a1a1a"), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 200
                )
                RadialGradient(
                    colors: [Color(hex: "#181818"), .clear],
                    center: .bottomTrailing,
                    startRadius: 0,
                    endRadius: 120
                )
                RadialGradient(
                    colors: [Color(hex: "#151515"), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: 100
                )
            }
            .background(AppTheme.bgColor)
            
            VStack(spacing: 8) {
                Text("Run")
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(.white)
                
                // Show last run summary or ready state
                if let summary = tracker.finalSummary {
                    HStack(spacing: 20) {
                        Text(formatMiles(summary.distance) + " mi")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                        
                        Text(formatDuration(summary.duration))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                        
                        Text(formatPace(summary.averageSpeed) + "/mi")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                } else {
                    Text("Ready to run")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .frame(height: 100)
    }
    
    // MARK: - Map Area
    private var mapArea: some View {
        ZStack {
            // Always show map (user's current location when not tracking)
            RouteMapView(
                coordinates: tracker.trackedLocations.map { $0.coordinate },
                isTracking: false
            )
            
            // Simple START Button
            VStack {
                Spacer()
                
                Button(action: startRun) {
                    Text("START")
                        .font(.system(size: 18, weight: .bold))
                        .tracking(2)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 30)
            }
        }
        .frame(height: 320)
    }
    
    // MARK: - Bottom Section
    private var bottomSection: some View {
        VStack(spacing: 0) {
            // Weather & Shoe Widgets
            HStack(spacing: 12) {
                // Weather Widget
                VStack(alignment: .leading, spacing: 4) {
                    Text("52°F")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(AppTheme.primaryText)
                    
                    Text("Wind 8 mph")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(AppTheme.cardGradient)
                .cornerRadius(16)
                
                // Shoe Widget
                VStack(alignment: .leading, spacing: 4) {
                    Text("Running Shoe")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.secondaryText)
                    
                    HStack {
                        Text(selectedShoe)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(AppTheme.primaryText)
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.secondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(AppTheme.cardGradient)
                .cornerRadius(16)
            }
            .padding(.bottom, 20)
            
            // Today's Run Toggle
            ToggleRow(
                label: "Today's Run",
                isOn: $todaysRunEnabled
            )
            
            // Voice Assistant Toggle
            ToggleRow(
                label: "Voice Assistant",
                isOn: $voiceAssistant.settings.isEnabled
            )
            
            // Show zone setup if voice is enabled but zones not calibrated
            if voiceAssistant.settings.isEnabled && !zonesManager.isOnboardingComplete {
                Button(action: { showZonesOnboarding = true }) {
                    HStack {
                        Image(systemName: "heart.text.square")
                            .foregroundColor(AppTheme.accentColor)
                        
                        Text("Setup Training Zones")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(AppTheme.accentColor)
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.accentColor.opacity(0.6))
                    }
                    .padding(.vertical, 12)
                }
            }
            
            // Voice Settings when enabled
            if voiceAssistant.settings.isEnabled {
                Button(action: { showVoiceSettings = true }) {
                    HStack {
                        Image(systemName: "speaker.wave.2")
                            .foregroundColor(AppTheme.secondaryText)
                        
                        Text("Voice Settings")
                            .font(.system(size: 14))
                            .foregroundColor(AppTheme.secondaryText)
                        
                        Spacer()
                        
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.secondaryText.opacity(0.6))
                    }
                    .padding(.vertical, 8)
                }
            }
            
            // Plan a Run Button
            Button(action: {}) {
                Text("Plan a Run")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppTheme.primaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(AppTheme.subtleBorder, lineWidth: 1)
                    )
                    .cornerRadius(12)
            }
            .padding(.top, 10)
            
            // Clear last run data
            if tracker.finalSummary != nil {
                Button(action: { tracker.reset() }) {
                    HStack {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                        Text("Clear Last Run")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .padding(.top, 10)
            }
        }
    }
    
    // MARK: - Formatting Helpers
    private let metersPerMile: Double = 1609.344
    
    private func formatMiles(_ meters: Double) -> String {
        let miles = meters / metersPerMile
        return String(format: "%.2f", miles)
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
    
    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .regular))
                .foregroundColor(AppTheme.primaryText)
            
            Text(label)
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Toggle Row
struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    
    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(AppTheme.primaryText)
            
            Spacer()
            
            // Custom Toggle
            ZStack {
                Capsule()
                    .fill(isOn ? AppTheme.accentColor : Color(hex: "#333333"))
                    .frame(width: 50, height: 28)
                
                Circle()
                    .fill(Color.white)
                    .frame(width: 22, height: 22)
                    .offset(x: isOn ? 11 : -11)
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isOn.toggle()
                }
            }
        }
        .padding(.vertical, 16)
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

// MARK: - Voice Settings View
struct VoiceSettingsView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var voiceAssistant = VoiceAssistantManager.shared
    
    var body: some View {
        ZStack {
            AppTheme.bgColor.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    
                    Text("Voice Settings")
                        .font(.system(size: 20, weight: .light))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                    
                    // Test button
                    Button(action: {
                        voiceAssistant.speak("Voice assistant is working. Your settings are configured.")
                    }) {
                        Image(systemName: "speaker.wave.2")
                            .font(.system(size: 16))
                            .foregroundColor(AppTheme.accentColor)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        // Announcements Section
                        settingsSection(title: "Announcements") {
                            settingsToggle("Distance Updates", isOn: $voiceAssistant.settings.announceDistance)
                            settingsToggle("Pace Updates", isOn: $voiceAssistant.settings.announcePace)
                            settingsToggle("Heart Rate Zones", isOn: $voiceAssistant.settings.announceHeartRate)
                            settingsToggle("Zone Changes", isOn: $voiceAssistant.settings.announceZoneChanges)
                        }
                        
                        // Intervals Section
                        settingsSection(title: "Update Frequency") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Distance Interval")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                                
                                Picker("", selection: $voiceAssistant.settings.distanceInterval) {
                                    Text("0.5 mi").tag(0.5)
                                    Text("1 mi").tag(1.0)
                                    Text("2 mi").tag(2.0)
                                }
                                .pickerStyle(.segmented)
                            }
                            .padding(.vertical, 8)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Time Interval")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                                
                                Picker("", selection: $voiceAssistant.settings.timeInterval) {
                                    Text("5 min").tag(TimeInterval(300))
                                    Text("10 min").tag(TimeInterval(600))
                                    Text("15 min").tag(TimeInterval(900))
                                }
                                .pickerStyle(.segmented)
                            }
                            .padding(.vertical, 8)
                        }
                        
                        // Voice Selection Section
                        settingsSection(title: "Siri Voice") {
                            // Current voice display
                            HStack {
                                Image(systemName: "person.wave.2.fill")
                                    .foregroundColor(AppTheme.accentColor)
                                
                                Text("Current: \(voiceAssistant.getCurrentVoiceName())")
                                    .font(.system(size: 14))
                                    .foregroundColor(.white)
                                
                                Spacer()
                            }
                            .padding(.vertical, 8)
                            
                            // Voice picker with scroll
                            let premiumVoices = voiceAssistant.getPremiumVoices()
                            if !premiumVoices.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Available Voices")
                                            .font(.system(size: 12))
                                            .foregroundColor(.white.opacity(0.5))
                                        
                                        Spacer()
                                        
                                        Text("\(premiumVoices.count) voices")
                                            .font(.system(size: 11))
                                            .foregroundColor(.white.opacity(0.3))
                                    }
                                    
                                    // Scrollable voice list
                                    ScrollView(.vertical, showsIndicators: true) {
                                        VStack(spacing: 0) {
                                            ForEach(premiumVoices, id: \.identifier) { voice in
                                                Button(action: {
                                                    voiceAssistant.setVoice(voice)
                                                    voiceAssistant.speak("Hello, I'm \(voice.name).")
                                                }) {
                                                    HStack {
                                                        VStack(alignment: .leading, spacing: 2) {
                                                            Text(voice.name)
                                                                .font(.system(size: 14, weight: .medium))
                                                                .foregroundColor(.white)
                                                            
                                                            Text(voiceQualityLabel(voice))
                                                                .font(.system(size: 11))
                                                                .foregroundColor(AppTheme.accentColor.opacity(0.7))
                                                        }
                                                        
                                                        Spacer()
                                                        
                                                        if voiceAssistant.getCurrentVoiceName() == voice.name {
                                                            Image(systemName: "checkmark.circle.fill")
                                                                .font(.system(size: 18))
                                                                .foregroundColor(AppTheme.accentColor)
                                                        } else {
                                                            Image(systemName: "play.circle")
                                                                .font(.system(size: 18))
                                                                .foregroundColor(.white.opacity(0.3))
                                                        }
                                                    }
                                                    .padding(.vertical, 12)
                                                    .padding(.horizontal, 12)
                                                    .background(
                                                        voiceAssistant.getCurrentVoiceName() == voice.name 
                                                            ? AppTheme.accentColor.opacity(0.1) 
                                                            : Color.clear
                                                    )
                                                    .cornerRadius(8)
                                                }
                                                
                                                if voice.identifier != premiumVoices.last?.identifier {
                                                    Divider()
                                                        .background(Color.white.opacity(0.1))
                                                }
                                            }
                                        }
                                    }
                                    .frame(maxHeight: 250) // Scrollable area
                                    .background(Color.white.opacity(0.02))
                                    .cornerRadius(10)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Image(systemName: "exclamationmark.triangle")
                                            .foregroundColor(.yellow)
                                        Text("No premium voices found")
                                            .font(.system(size: 14))
                                            .foregroundColor(.white)
                                    }
                                    
                                    Text("Download Siri-quality voices:")
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.5))
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("1. Open Settings app")
                                        Text("2. Accessibility → Spoken Content")
                                        Text("3. Voices → English")
                                        Text("4. Download Enhanced voices")
                                    }
                                    .font(.system(size: 12))
                                    .foregroundColor(AppTheme.accentColor)
                                }
                                .padding(.vertical, 8)
                            }
                        }
                        
                        // Voice Settings Section
                        settingsSection(title: "Voice Settings") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Volume")
                                        .font(.system(size: 14))
                                        .foregroundColor(.white)
                                    Spacer()
                                    Text("\(Int(voiceAssistant.settings.volume * 100))%")
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.5))
                                }
                                Slider(value: $voiceAssistant.settings.volume, in: 0...1)
                                    .accentColor(AppTheme.accentColor)
                            }
                            .padding(.vertical, 8)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Speed")
                                        .font(.system(size: 14))
                                        .foregroundColor(.white)
                                    Spacer()
                                    Text(speedLabel)
                                        .font(.system(size: 12))
                                        .foregroundColor(.white.opacity(0.5))
                                }
                                Slider(value: $voiceAssistant.settings.rate, in: 0.3...0.7)
                                    .accentColor(AppTheme.accentColor)
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
            }
        }
        .onDisappear {
            voiceAssistant.saveSettings()
        }
    }
    
    private var speedLabel: String {
        if voiceAssistant.settings.rate < 0.4 { return "Slow" }
        else if voiceAssistant.settings.rate > 0.6 { return "Fast" }
        else { return "Normal" }
    }
    
    private func voiceQualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium:
            return "Premium • Siri Quality"
        case .enhanced:
            return "Enhanced • High Quality"
        default:
            return "Standard"
        }
    }
    
    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
                .textCase(.uppercase)
            
            VStack(spacing: 0) {
                content()
            }
            .padding(16)
            .background(Color.white.opacity(0.03))
            .cornerRadius(12)
        }
    }
    
    private func settingsToggle(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(.white)
            
            Spacer()
            
            Toggle("", isOn: isOn)
                .toggleStyle(SwitchToggleStyle(tint: AppTheme.accentColor))
                .labelsHidden()
        }
        .padding(.vertical, 6)
    }
}

#Preview {
    RunView()
}

