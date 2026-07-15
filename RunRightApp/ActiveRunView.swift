//
//  ActiveRunView.swift
//  RunRightApp
//
//  Active running interface — lime theme, no voice assistant

import SwiftUI
import MapKit

struct ActiveRunView: View {
    @ObservedObject var tracker: ActivityTracker
    @Binding var elapsedTime: TimeInterval
    var shoeName: String? = nil
    /// Target pace (sec/mile) from today's plan — enables goal-based pace coaching. nil = free run.
    var plannedTargetPaceSecPerMile: Double? = nil

    @ObservedObject private var coach = GaitaCoach.shared
    // Splits live on the session so they survive minimize/restore.
    @ObservedObject private var session = RunSession.shared
    // Hands-free "Hey Gaita" voice coach (foreground only).
    @StateObject private var wake = HeyGaitaListener()

    @Environment(\.dismiss) var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var isPaused = false
    @State private var showFinishScreen = false
    @State private var savedSummary: ActivitySummary?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var isExpanded = false
    @State private var currentPage = 0
    @State private var dragOffset: CGFloat = 0
    @State private var compactDragOffset: CGFloat = 0

    private var mileSplits: [MileSplit] { session.mileSplits }
    
    private let accentOrange = AppTheme.accentColor
    private let backgroundColor = AppTheme.bgColor
    private let cardBackground = AppTheme.cardBg
    private let metersPerMile: Double = 1609.344
    
    var body: some View {
        ZStack {
            if showFinishScreen {
                finishScreen
            } else if isExpanded || isPaused {
                expandedStatsView
            } else {
                runningMapView
            }

            // Idle warning + countdown before the run auto-cancels.
            if session.inactivityPrompt && !showFinishScreen {
                inactivityOverlay
            }
        }
        .ignoresSafeArea(.all)
        .statusBar(hidden: !isExpanded && !isPaused)
        // The global RunSession starts the coach and feeds it on GPS updates, so
        // cues continue when this screen is minimized. Here we only sync the local
        // pause UI when the screen (re)appears.
        .onAppear {
            isPaused = tracker.isPaused
        }
        // Push-to-talk: the mic is OFF unless the runner taps the mic button, so
        // their music plays uninterrupted. We only ever STOP the listener here
        // (on disappear / background / coach-off) — never auto-start it.
        .onDisappear { wake.stop() }
        .onChange(of: coach.isEnabled) { _, on in
            if !on { wake.stop() }
        }
        // The mic is foreground-only. If a tap-to-talk capture is in flight when
        // the app backgrounds/locks, tear it down so nothing records behind the
        // lock screen under the `audio` background mode (App Review 5.1.1).
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { wake.stop() }
        }
    }

    // MARK: - Inactivity overlay
    private var inactivityOverlay: some View {
        ZStack {
            Color.black.opacity(0.78).ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "figure.stand")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundColor(AppTheme.accentColor)

                Text("Still running?")
                    .font(AppTheme.head(22))
                    .foregroundColor(AppTheme.primaryText)

                Text("We haven't seen you move in a while. This run ends in \(session.inactivityCountdown)s.")
                    .font(AppTheme.body(14))
                    .foregroundColor(AppTheme.primaryText.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: { session.noteActivity() }) {
                    Text("I'm still running")
                        .font(AppTheme.bodySemibold(17))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(AppTheme.accentColor)
                        .cornerRadius(27)
                }

                Button(action: { finishRun() }) {
                    Text("End run")
                        .font(AppTheme.bodySemibold(16))
                        .foregroundColor(AppTheme.primaryText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .appRaisedSurface(fill: cardBackground, cornerRadius: 27)
                }
            }
            .padding(28)
            .background(backgroundColor)
            .cornerRadius(24)
            .padding(.horizontal, 32)
        }
    }
    
    // MARK: - Running Map View
    private var runningMapView: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                LiveRunMapView(
                    coordinates: tracker.trackedLocations.map { $0.coordinate },
                    isTracking: true
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                
                // Top bar: Gaita coach toggle (left) + GPS indicator (right)
                VStack {
                    HStack(spacing: 10) {
                        minimizeButton
                            .padding(.leading, 16)
                            .padding(.top, 50)
                        corsaToggle
                            .padding(.top, 50)
                        Spacer()
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 6, height: 6)
                            Text("GPS")
                                .font(AppTheme.bodySemibold(11))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.trailing, 16)
                        .padding(.top, 50)
                    }

                    // Per-cue controls: toggle mile markers and pace updates
                    // independently, right in the run slide.
                    if coach.isEnabled {
                        HStack {
                            coachCueToggles
                                .padding(.leading, 16)
                            Spacer()
                        }
                        .padding(.top, 8)
                    }

                    // Gaita's most recent spoken cue (visible confirmation of coaching).
                    if coach.isEnabled, let cue = coach.lastSpoken {
                        Text(cue)
                            .font(AppTheme.bodyMedium(12))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.horizontal, 28)
                            .padding(.top, 8)
                            .transition(.opacity)
                    }

                    // "Hey Gaita" hands-free voice coach.
                    if coach.isEnabled && HeyGaitaListener.isSupported {
                        heyGaitaView
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                    }

                    Spacer()
                }
                // Overlays float on the dark map — force dark materials so the
                // blur chips stay legible regardless of the app's color scheme.
                .environment(\.colorScheme, .dark)
                .animation(.easeInOut(duration: 0.3), value: coach.lastSpoken)
                .animation(.spring(duration: 0.35), value: wake.phase)
                
                compactStatsBar
            }
        }
    }
    
    // MARK: - Minimize (keep running, browse other tabs)
    private var minimizeButton: some View {
        Button(action: { RunSession.shared.minimize() }) {
            Image(systemName: "chevron.down").accessibilityLabel("Minimize run")
                .font(AppTheme.meta(13))
                .foregroundColor(.white)
                .padding(9)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    // MARK: - Gaita coach toggle
    private var corsaToggle: some View {
        Button(action: { coach.isEnabled.toggle() }) {
            HStack(spacing: 5) {
                Image(systemName: coach.isEnabled ? "waveform" : "speaker.slash.fill")
                    .font(AppTheme.meta(11))
                Text("GAITA")
                    .font(AppTheme.meta(11))
            }
            .foregroundColor(.white.opacity(coach.isEnabled ? 1 : 0.45))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    // MARK: - Per-cue toggles (mile updates / pace updates)
    private var coachCueToggles: some View {
        HStack(spacing: 8) {
            cueChip(label: "Miles", on: coach.mileCuesEnabled) { coach.mileCuesEnabled.toggle() }
            cueChip(label: "Pace", on: coach.paceCuesEnabled) { coach.paceCuesEnabled.toggle() }
        }
    }

    private func cueChip(label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(AppTheme.meta(11))
                Text(label)
                    .font(AppTheme.meta(11))
            }
            .foregroundColor(.white.opacity(on ? 1 : 0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hey Gaita (hands-free voice coach)
    @ViewBuilder private var heyGaitaView: some View {
        switch wake.phase {
        case .off, .listening:
            // Big, easy push-to-talk target. Mic only turns on while you hold a
            // conversation, so music keeps playing the rest of the run.
            Button(action: { wake.tapToTalk() }) {
                HStack(spacing: 10) {
                    Image(systemName: "mic.fill")
                        .font(AppTheme.bodySemibold(18))
                    Text("Talk to Gaita")
                        .font(AppTheme.bodySemibold(17))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 58)
                .background(AppTheme.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)

        case .capturing:
            heyGaitaCard(icon: "waveform",
                         title: "Listening",
                         body: wake.heard.isEmpty ? "Go ahead, ask your coach." : wake.heard)

        case .thinking:
            heyGaitaCard(icon: "ellipsis",
                         title: "Gaita is thinking", body: wake.heard)

        case .answering:
            heyGaitaCard(icon: "waveform",
                         title: "Gaita", body: wake.answer, speaking: true)
        }
    }

    private func heyGaitaCard(icon: String, title: String, body: String, speaking: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // One clean color — a single-weight icon with a simple pulse while
                // Gaita speaks, so it reads as talking without a tacky rainbow effect.
                Image(systemName: icon)
                    .font(AppTheme.meta(10))
                    .symbolEffect(.pulse, options: speaking ? .repeating : .nonRepeating, isActive: speaking)
                Text(title.uppercased()).font(AppTheme.meta(10))
                if speaking { Text("SPEAKING").font(AppTheme.meta(9)).opacity(0.6) }
            }
            .foregroundColor(.white)
            if !body.isEmpty {
                Text(body)
                    .font(AppTheme.bodyMedium(13))
                    .foregroundColor(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: - Compact Stats Card
    // A floating rounded card with three equal data columns, the zone gauge, and
    // a full-width pause pill — deliberately not the attached bottom sheet with a
    // giant circular button every other run app uses.
    private var compactStatsBar: some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(AppTheme.primaryText.opacity(0.25))
                .frame(width: 36, height: 4)

            HStack(spacing: 0) {
                compactStat(formatTime(elapsedTime), "TIME")
                compactStat(formatMiles(tracker.liveSummary?.distance ?? 0), "MILES")
                compactStat(formatPacePerMile(tracker.liveSummary?.averageSpeed ?? 0), "PACE")
            }

            // Live effort zone — the run screen's signature element.
            zoneStrip
                .padding(.horizontal, 6)

            Button(action: pauseRun) {
                HStack(spacing: 8) {
                    Image(systemName: "pause.fill").accessibilityLabel("Pause run")
                        .font(AppTheme.head(16))
                    Text("Pause")
                        .font(AppTheme.bodySemibold(17))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(accentOrange)
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 24)
        .offset(y: compactDragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    if value.translation.height < 0 {
                        compactDragOffset = value.translation.height * 0.3
                    }
                }
                .onEnded { value in
                    if value.translation.height < -80 {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isExpanded = true
                        }
                    }
                    withAnimation(.spring()) {
                        compactDragOffset = 0
                    }
                }
        )
    }
    
    private func compactStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(AppTheme.displayTabular(30))
                .foregroundColor(AppTheme.primaryText)
            Text(label)
                .font(AppTheme.meta(10))
                .foregroundColor(AppTheme.primaryText.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Expanded Stats View
    private var expandedStatsView: some View {
        VStack(spacing: 0) {
            headerSection
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if value.translation.height > 0 && !isPaused {
                                dragOffset = value.translation.height
                            }
                        }
                        .onEnded { value in
                            if value.translation.height > 100 && !isPaused {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    isExpanded = false
                                }
                            }
                            dragOffset = 0
                        }
                )
            
            TabView(selection: $currentPage) {
                paceDistancePage.tag(0)
                splitsPage.tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .background(backgroundColor)
            
            bottomControlBar
        }
        .background(backgroundColor)
        .offset(y: dragOffset)
        .animation(.interactiveSpring(), value: dragOffset)
    }
    
    // MARK: - Header Section
    // Dark header with a small status dot — not the solid orange banner every
    // other run app puts here. The accent lives in the dot and the buttons.
    private var headerSection: some View {
        VStack(spacing: 4) {
            if !isPaused {
                RoundedRectangle(cornerRadius: 3)
                    .fill(AppTheme.primaryText.opacity(0.25))
                    .frame(width: 40, height: 5)
                    .padding(.top, 8)
            }

            HStack(spacing: 7) {
                Circle()
                    .fill(isPaused ? AppTheme.primaryText.opacity(0.4) : accentOrange)
                    .frame(width: 8, height: 8)
                Text(isPaused ? "Paused" : "Running")
                    .font(AppTheme.bodySemibold(15))
                    .foregroundColor(AppTheme.primaryText.opacity(0.6))
            }

            Text(formatTimeWithHours(elapsedTime))
                .font(AppTheme.displayTabular(56))
                .foregroundColor(AppTheme.primaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, isPaused ? 60 : 50)
        .padding(.bottom, 20)
        .background(backgroundColor)
        .overlay(
            Button(action: {
                if !isPaused {
                    withAnimation(.easeInOut(duration: 0.3)) { isExpanded = false }
                }
            }) {
                Image(systemName: "arrow.down.right.and.arrow.up.left").accessibilityLabel("Collapse run")
                    .font(AppTheme.bodyMedium(18))
                    .foregroundColor(AppTheme.primaryText.opacity(0.6))
                    .padding(12)
            }
            .opacity(isPaused ? 0 : 1)
            , alignment: .topTrailing
        )
    }
    
    // MARK: - Page 1: Pace & Distance
    private var paceDistancePage: some View {
        VStack(spacing: 40) {
            Spacer()
            
            VStack(spacing: 8) {
                if tracker.liveSummary?.averageSpeed ?? 0 < 0.5 {
                    HStack(spacing: 4) {
                        Text("--")
                            .font(AppTheme.displayTabular(72))
                            .foregroundColor(AppTheme.primaryText)
                        Text(":")
                            .font(AppTheme.displayTabular(72))
                            .foregroundColor(AppTheme.primaryText)
                        Text("--")
                            .font(AppTheme.displayTabular(72))
                            .foregroundColor(AppTheme.primaryText)
                    }
                } else {
                    Text(formatPacePerMile(tracker.liveSummary?.averageSpeed ?? 0))
                        .font(AppTheme.displayTabular(72))
                        .foregroundColor(AppTheme.primaryText)
                }
                
                Text("Avg. pace (/mi)")
                    .font(AppTheme.body(17))
                    .foregroundColor(AppTheme.primaryText.opacity(0.4))
            }
            
            VStack(spacing: 8) {
                Text(formatMiles(tracker.liveSummary?.distance ?? 0))
                    .font(AppTheme.displayTabular(96))
                    .foregroundColor(AppTheme.primaryText)

                Text("Distance (mi)")
                    .font(AppTheme.body(17))
                    .foregroundColor(AppTheme.primaryText.opacity(0.4))
            }

            zoneStrip
                .padding(.horizontal, 56)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Page 2: Splits
    private var splitsPage: some View {
        VStack(spacing: 20) {
            Spacer()
            
            if mileSplits.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "chart.bar.fill")
                        .font(AppTheme.body(48))
                        .foregroundColor(cardBackground)
                    
                    Text("Complete your first mile to see splits")
                        .font(AppTheme.body(15))
                        .foregroundColor(AppTheme.primaryText.opacity(0.4))
                }
            } else {
                VStack(spacing: 16) {
                    Text("Splits (mi)")
                        .font(AppTheme.bodySemibold(17))
                        .foregroundColor(AppTheme.primaryText)
                    
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(mileSplits.indices, id: \.self) { index in
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(barColor(for: mileSplits[index].time))
                                    .frame(width: 40, height: barHeight(for: mileSplits[index].time))
                                
                                Text("\(index + 1)")
                                    .font(AppTheme.body(12))
                                    .foregroundColor(AppTheme.primaryText.opacity(0.4))
                            }
                        }
                    }
                    .frame(height: 150)
                    
                    VStack(spacing: 0) {
                        ForEach(mileSplits.indices, id: \.self) { index in
                            HStack {
                                Text("Mile \(index + 1)")
                                    .font(AppTheme.body(15))
                                    .foregroundColor(AppTheme.primaryText)
                                
                                Spacer()
                                
                                Text(formatPaceFromSplit(mileSplits[index].time))
                                    .font(AppTheme.bodySemibold(15))
                                    .foregroundColor(paceColor(mileSplits[index].time))
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 20)
                            
                            if index < mileSplits.count - 1 {
                                Divider().background(AppTheme.primaryText.opacity(0.08))
                            }
                        }
                    }
                    .appRaisedSurface(fill: cardBackground, cornerRadius: 16, shadowRadius: 9, x: 5, y: 5)
                    .padding(.horizontal, 20)
                }
            }
            
            Spacer()
        }
    }
    
    private func barHeight(for time: TimeInterval) -> CGFloat {
        let maxHeight: CGFloat = 120
        let minHeight: CGFloat = 30
        let avgPace = 600.0
        let ratio = avgPace / max(time, 300)
        return min(maxHeight, max(minHeight, CGFloat(ratio) * 80))
    }
    
    private func barColor(for time: TimeInterval) -> Color {
        let paceMinutes = time / 60
        if paceMinutes < 8 { return Color(hex: "#FF8C00") }   // warm gradient fast end (not the app accent)
        if paceMinutes < 10 { return Color(hex: "#E0902E") }
        return Color(hex: "#A8641A")
    }
    
    // MARK: - Bottom Control Bar
    private var bottomControlBar: some View {
        HStack(spacing: 16) {
            if isPaused {
                Button(action: resumeRun) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(AppTheme.head(18))
                        Text("Resume")
                            .font(AppTheme.bodySemibold(17))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(accentOrange)
                    .cornerRadius(28)
                }
                
                Button(action: finishRun) {
                    HStack(spacing: 8) {
                        Image(systemName: "flag.checkered")
                            .font(AppTheme.bodyMedium(16))
                        Text("Finish")
                            .font(AppTheme.bodySemibold(17))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(AppTheme.accentColor)
                    .cornerRadius(28)
                }
            } else {
                Button(action: pauseRun) {
                    HStack(spacing: 8) {
                        Image(systemName: "pause.fill")
                            .font(AppTheme.head(18))
                        Text("Pause")
                            .font(AppTheme.bodySemibold(17))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(AppTheme.accentColor)
                    .cornerRadius(28)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 40)
        .background(backgroundColor)
    }
    
    // MARK: - Finish Screen
    private var finishScreen: some View {
        ZStack {
            backgroundColor
            
            ScrollView {
                VStack(spacing: 0) {
                    if !tracker.trackedLocations.isEmpty {
                        RoutePreviewMap(coordinates: tracker.trackedLocations.map { $0.coordinate })
                            .frame(height: 200)
                            .cornerRadius(16)
                            .padding(.horizontal, 16)
                            .padding(.top, 60)
                    }
                    
                    VStack(spacing: 4) {
                        Text("Run Complete!")
                            .font(AppTheme.head(24))
                            .foregroundColor(AppTheme.primaryText)
                        
                        Text(Date(), style: .date)
                            .font(AppTheme.body(14))
                            .foregroundColor(AppTheme.primaryText.opacity(0.4))
                    }
                    .padding(.top, 24)
                    
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 20) {
                        finishStat(value: formatMiles(savedSummary?.distance ?? 0), unit: "mi", label: "Distance")
                        finishStat(value: formatTimeWithHours(elapsedTime), unit: "", label: "Time")
                        finishStat(value: formatPacePerMile(savedSummary?.averageSpeed ?? 0), unit: "/mi", label: "Pace")
                    }
                    .padding(.top, 32)
                    .padding(.horizontal, 20)
                    
                    if !mileSplits.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Mile Splits")
                                .font(AppTheme.head(18))
                                .foregroundColor(AppTheme.primaryText)
                            
                            ForEach(mileSplits.indices, id: \.self) { index in
                                HStack {
                                    Text("Mile \(index + 1)")
                                        .foregroundColor(AppTheme.primaryText)
                                    Spacer()
                                    Text(formatPaceFromSplit(mileSplits[index].time))
                                        .font(AppTheme.bodySemibold(16))
                                        .foregroundColor(paceColor(mileSplits[index].time))
                                }
                            }
                        }
                        .padding(20)
                        .appRaisedSurface(fill: cardBackground, cornerRadius: 20)
                        .padding(.horizontal, 16)
                        .padding(.top, 24)
                    }
                    
                    Spacer(minLength: 120)
                }
            }
            
            VStack(spacing: 10) {
                Spacer()

                // Never fail silently: a save error (offline / Firestore) used to
                // be swallowed, and a GPS-denied run reached here with an inert
                // Save button and no explanation. Surface both.
                if let saveError {
                    Text(saveError)
                        .font(AppTheme.body(13))
                        .foregroundColor(Color(hex: "#FF453A"))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                } else if savedSummary == nil {
                    Text("No GPS distance was recorded, so there's nothing to save. Check that Location is enabled for Gaita and you have a clear view of the sky.")
                        .font(AppTheme.body(13))
                        .foregroundColor(AppTheme.primaryText.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                }

                HStack(spacing: 12) {
                    Button(action: { RunSession.shared.dismissSession() }) {
                        Text("Discard")
                            .font(AppTheme.bodySemibold(16))
                            .foregroundColor(AppTheme.primaryText)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .appRaisedSurface(fill: cardBackground, cornerRadius: 27, shadowRadius: 9, x: 5, y: 5)
                    }
                    
                    Button(action: {
                        guard !isSaving, let summary = savedSummary else { return }
                        isSaving = true
                        saveError = nil

                        Task {
                            do {
                                try await RunRepository.shared.saveRunSummary(
                                    summary,
                                    shoeName: shoeName,
                                    route: tracker.trackedLocations.map { $0.coordinate }
                                )
                                await MainActor.run {
                                    isSaving = false
                                    NotificationCenter.default.post(name: .runSaved, object: nil)
                                    RunSession.shared.dismissSession()
                                }
                            } catch {
                                await MainActor.run {
                                    isSaving = false
                                    saveError = "Could not save run: \(error.localizedDescription)"
                                }
                            }
                        }
                    }) {
                        Text(isSaving ? "Saving..." : "Save")
                            .font(AppTheme.bodySemibold(16))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(accentOrange)
                            .cornerRadius(27)
                            .opacity((!isSaving && savedSummary != nil) ? 1 : 0.7)
                    }
                    .disabled(isSaving || savedSummary == nil)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 40)
            }
        }
    }
    
    private func finishStat(value: String, unit: String, label: String) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(AppTheme.display(28))
                    .foregroundColor(AppTheme.primaryText)
                if !unit.isEmpty {
                    Text(unit)
                        .font(AppTheme.body(14))
                        .foregroundColor(AppTheme.primaryText.opacity(0.4))
                }
            }
            Text(label)
                .font(AppTheme.body(13))
                .foregroundColor(AppTheme.primaryText.opacity(0.4))
        }
    }
    
    // MARK: - Live pace zone
    //
    // A distinctive at-a-glance effort read other run apps show (Garmin, Coros,
    // Polar) but a plain map screen does not. Live heart rate isn't available
    // mid-run, so the zone comes from current pace against the runner's threshold
    // pace, set from their fitness level. Uses the app's canonical zone palette.

    /// Threshold pace (sec/mile) that anchors the zone split.
    private var thresholdPaceSecPerMile: Double {
        switch HeartRateZonesManager.shared.userProfile?.fitnessLevel {
        case .elite: return 345          // ~5:45/mi
        case .advanced: return 420       // ~7:00/mi
        case .intermediate: return 510   // ~8:30/mi
        case .beginner: return 630       // ~10:30/mi
        case .none: return 540           // ~9:00/mi default
        }
    }

    /// Current speed (m/s) from the tracker's live Doppler reading — honestly
    /// zero when the runner stops (the old trackedLocations.last read went stale
    /// while standing still and kept showing the last moving speed).
    private var currentSpeedMps: Double {
        tracker.currentSpeedMps
    }

    /// The live zone, or nil when basically stopped (warming up / paused).
    /// A zone needs REAL movement, not GPS noise: a single spurious Doppler
    /// reading while standing still used to light "Z2 Aerobic" at 0.00 miles.
    /// Require a jogging-or-faster speed AND actual distance covered before
    /// any zone shows; below that the gauge honestly says WARMING UP.
    private var currentZone: RunZone? {
        let s = currentSpeedMps
        let distance = tracker.liveSummary?.distance ?? 0
        guard s >= 1.2, distance >= 30 else { return nil }
        return RunZone.classify(currentPaceSecPerMile: metersPerMile / s,
                                thresholdSecPerMile: thresholdPaceSecPerMile)
    }

    /// Clean five-segment zone gauge: active zone lit in its color, the rest
    /// dim. One accent lives here (the zone), nowhere else in the chrome.
    private var zoneStrip: some View {
        let zone = currentZone
        return VStack(spacing: 9) {
            HStack(spacing: 4) {
                ForEach(RunZone.allCases, id: \.self) { z in
                    Capsule()
                        .fill(z == zone ? z.color : AppTheme.primaryText.opacity(0.12))
                        .frame(height: 5)
                }
            }
            HStack(spacing: 7) {
                Circle()
                    .fill(zone?.color ?? AppTheme.primaryText.opacity(0.3))
                    .frame(width: 7, height: 7)
                Text(zone.map { "\($0.shortName)   \($0.name.uppercased())" } ?? "WARMING UP")
                    .font(AppTheme.meta(12))
                    .foregroundColor(zone?.color ?? AppTheme.primaryText.opacity(0.5))
            }
        }
    }

    // MARK: - Actions
    private func pauseRun() {
        isPaused = true
        tracker.pauseTracking()
        session.noteActivity()
    }

    private func resumeRun() {
        isPaused = false
        tracker.resumeTracking()
        isExpanded = false
        session.noteActivity()
    }
    
    private func finishRun() {
        // Session stops the coach + timer + GPS and returns the summary.
        savedSummary = RunSession.shared.finishTracking()
        showFinishScreen = true
    }
    
    // MARK: - Formatters
    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
    
    private func formatTimeWithHours(_ seconds: TimeInterval) -> String {
        let hrs = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d:%02d", hrs, mins, secs)
    }
    
    private func formatMiles(_ meters: Double) -> String {
        String(format: "%.2f", meters / metersPerMile)
    }
    
    private func formatPacePerMile(_ speedMps: Double) -> String {
        guard speedMps > 0.5 else { return "--:--" }
        let secondsPerMile = metersPerMile / speedMps
        guard secondsPerMile < 1800 else { return "--:--" }
        let mins = Int(secondsPerMile) / 60
        let secs = Int(secondsPerMile) % 60
        return String(format: "%d:%02d", mins, secs)
    }
    
    private func formatPaceFromSplit(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
    
    private func paceColor(_ time: TimeInterval) -> Color {
        let mins = time / 60
        if mins < 8 { return Color(hex: "#FF8C00") }   // warm gradient fast end
        if mins < 10 { return Color(hex: "#E0902E") }
        return Color(hex: "#A8641A")
    }
}

struct MileSplit { let time: TimeInterval }

// MARK: - Live pace zone
// Five effort zones matching the app's HR-zone palette, classified from pace
// during a run (live heart rate isn't available). Slower pace = lower zone.
enum RunZone: Int, CaseIterable {
    case z1 = 1, z2, z3, z4, z5

    var shortName: String { "Z\(rawValue)" }
    var name: String {
        switch self {
        case .z1: return "Recovery"
        case .z2: return "Aerobic"
        case .z3: return "Tempo"
        case .z4: return "Threshold"
        case .z5: return "Maximum"
        }
    }
    var color: Color {
        switch self {
        case .z1: return Color(hex: "#00CED1")
        case .z2: return Color(hex: "#00FF7F")
        case .z3: return Color(hex: "#FFD700")
        case .z4: return Color(hex: "#FF8C00")
        case .z5: return Color(hex: "#FF0000")
        }
    }

    /// Classify current pace against a threshold pace (both sec/mile). Faster
    /// than threshold is Z4/Z5; each easier zone widens below it.
    static func classify(currentPaceSecPerMile pace: Double, thresholdSecPerMile t: Double) -> RunZone {
        if pace <= t - 20 { return .z5 }
        if pace <= t + 15 { return .z4 }
        if pace <= t + 55 { return .z3 }
        if pace <= t + 115 { return .z2 }
        return .z1
    }
}

// Notification posted after a run is saved so other views can refresh
extension Notification.Name {
    static let runSaved = Notification.Name("runSaved")
    /// Posted after the form-analysis history changes (a scan added or deleted),
    /// so the persisted Coach tab refreshes its TODAY insights without being
    /// rebuilt on every tab switch.
    static let analysisSaved = Notification.Name("analysisSaved")
}

// MARK: - Map Views
struct LiveRunMapView: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]
    let isTracking: Bool
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.userTrackingMode = .followWithHeading
        mapView.mapType = .standard
        mapView.overrideUserInterfaceStyle = .dark
        mapView.showsCompass = false
        return mapView
    }
    
    func updateUIView(_ mapView: MKMapView, context: Context) {
        // SwiftUI re-runs this on every observed tick (0.5s during a run);
        // only rebuild the O(route-length) polyline when new points arrived.
        if coordinates.count != context.coordinator.renderedCount {
            context.coordinator.renderedCount = coordinates.count
            mapView.removeOverlays(mapView.overlays)
            if coordinates.count > 1 {
                let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
                mapView.addOverlay(polyline)
            }
        }
        // Re-assert follow mode only when tracking STARTS — never per tick.
        // MapKit drops follow mode on any user pan/zoom; forcing it back every
        // 0.5s update re-animated the camera in an endless glitchy zoom fight.
        if isTracking != context.coordinator.wasTracking {
            context.coordinator.wasTracking = isTracking
            if isTracking {
                mapView.setUserTrackingMode(.followWithHeading, animated: true)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator: NSObject, MKMapViewDelegate {
        var renderedCount = -1
        var wasTracking = true   // makeUIView already starts in follow mode
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(AppTheme.accentColor)   // signature blue route line
                renderer.lineWidth = 5
                renderer.lineCap = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

struct RoutePreviewMap: UIViewRepresentable {
    let coordinates: [CLLocationCoordinate2D]
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.isUserInteractionEnabled = false
        mapView.overrideUserInterfaceStyle = .dark
        return mapView
    }
    
    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.removeOverlays(mapView.overlays)
        guard coordinates.count > 1 else { return }
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        mapView.addOverlay(polyline)
        mapView.setVisibleMapRect(polyline.boundingMapRect, edgePadding: UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24), animated: false)
    }
    
    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(AppTheme.accentColor)   // signature blue route line
                renderer.lineWidth = 4
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}

#Preview {
    ActiveRunView(tracker: ActivityTracker(), elapsedTime: .constant(754))
}
