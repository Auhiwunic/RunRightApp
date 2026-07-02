//
//  ActiveRunView.swift
//  RunRightApp
//
//  Strava-exact running interface
//

import SwiftUI
import MapKit

struct ActiveRunView: View {
    @ObservedObject var tracker: ActivityTracker
    @ObservedObject var voiceAssistant: VoiceAssistantManager
    @Binding var elapsedTime: TimeInterval
    
    @Environment(\.dismiss) var dismiss
    
    @State private var isPaused = false
    @State private var showFinishScreen = false
    @State private var savedSummary: ActivitySummary?
    @State private var isExpanded = false // Full screen stats mode
    @State private var currentPage = 0
    @State private var mileSplits: [MileSplit] = []
    @State private var lastMileTime: TimeInterval = 0
    @State private var dragOffset: CGFloat = 0
    @State private var compactDragOffset: CGFloat = 0
    
    private let accentColor = Color(hex: "#00CED1")
    private let metersPerMile: Double = 1609.344
    
    var body: some View {
        ZStack {
            if showFinishScreen {
                finishScreen
            } else if isExpanded || isPaused {
                // Full screen stats mode (Strava style)
                expandedStatsView
            } else {
                // Normal running view with map
                runningMapView
            }
        }
        .ignoresSafeArea(.all)
        .statusBar(hidden: !isExpanded && !isPaused)
        .onChange(of: tracker.liveSummary?.distance) { _, newDistance in
            checkForMileSplit(distance: newDistance ?? 0)
        }
    }
    
    // MARK: - Running Map View (Normal mode)
    private var runningMapView: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                // Full screen map
                StravaMapView(
                    coordinates: tracker.trackedLocations.map { $0.coordinate },
                    isTracking: true
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                
                // GPS indicator - top right
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "location.fill")
                                .font(.system(size: 12))
                            Text("GPS")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.green.opacity(0.9))
                        .cornerRadius(12)
                        .padding(.trailing, 16)
                        .padding(.top, 50)
                    }
                    Spacer()
                }
                
                // Bottom compact stats bar
                compactStatsBar
            }
        }
    }
    
    // MARK: - Compact Stats Bar (bottom of map view)
    private var compactStatsBar: some View {
        VStack(spacing: 0) {
            // Swipe up indicator (drag handle)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white.opacity(0.4))
                .frame(width: 40, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 8)
            
            // Time display
            Text(formatTime(elapsedTime))
                .font(.system(size: 48, weight: .light))
                .monospacedDigit()
                .foregroundColor(.white)
            
            // Stats row
            HStack(spacing: 32) {
                VStack(spacing: 2) {
                    Text(formatMiles(tracker.liveSummary?.distance ?? 0))
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.white)
                    Text("mi")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                }
                
                VStack(spacing: 2) {
                    Text(formatPacePerMile(tracker.liveSummary?.averageSpeed ?? 0))
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.white)
                    Text("/mi")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(.top, 8)
            
            // Pause button
            Button(action: pauseRun) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 72, height: 72)
                    .overlay(
                        Image(systemName: "pause.fill")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.black)
                    )
            }
            .padding(.top, 16)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity)
        .background(Color(hex: "#1C1C1E"))
        .cornerRadius(20, corners: [.topLeft, .topRight])
        .offset(y: compactDragOffset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    // Only allow upward drag (negative translation)
                    if value.translation.height < 0 {
                        compactDragOffset = value.translation.height * 0.3
                    }
                }
                .onEnded { value in
                    // If dragged up more than 80px, expand
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
    
    // MARK: - Expanded Stats View (Full Screen - Strava style)
    private var expandedStatsView: some View {
        VStack(spacing: 0) {
            // Yellow/Cyan header with time - draggable to dismiss
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
            
            // Main content - swipeable pages
            TabView(selection: $currentPage) {
                // Page 1: Pace & Distance
                paceDistancePage
                    .tag(0)
                
                // Page 2: Splits
                splitsPage
                    .tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .background(Color.black)
            
            // Bottom control bar
            bottomControlBar
        }
        .background(Color.black)
        .offset(y: dragOffset)
        .animation(.interactiveSpring(), value: dragOffset)
    }
    
    // MARK: - Header Section (Yellow in Strava, Cyan for us)
    private var headerSection: some View {
        VStack(spacing: 4) {
            // Swipe down indicator (only when not paused)
            if !isPaused {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.black.opacity(0.3))
                    .frame(width: 40, height: 5)
                    .padding(.top, 8)
            }
            
            // Status text
            Text(isPaused ? "Paused" : "Running")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.black)
            
            // Large time
            Text(formatTimeWithHours(elapsedTime))
                .font(.system(size: 56, weight: .bold, design: .default))
                .monospacedDigit()
                .foregroundColor(.black)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, isPaused ? 60 : 50)
        .padding(.bottom, 20)
        .background(accentColor)
        .overlay(
            // Collapse button (top right)
            Button(action: { 
                if !isPaused {
                    withAnimation(.easeInOut(duration: 0.3)) { isExpanded = false }
                }
            }) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.black.opacity(0.7))
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
            
            // Avg Pace
            VStack(spacing: 8) {
                // Pace display with dots animation if calculating
                if tracker.liveSummary?.averageSpeed ?? 0 < 0.5 {
                    HStack(spacing: 4) {
                        Text("--")
                            .font(.system(size: 72, weight: .light))
                            .foregroundColor(.white)
                        Text(":")
                            .font(.system(size: 72, weight: .light))
                            .foregroundColor(.white)
                        Text("--")
                            .font(.system(size: 72, weight: .light))
                            .foregroundColor(.white)
                    }
                } else {
                    Text(formatPacePerMile(tracker.liveSummary?.averageSpeed ?? 0))
                        .font(.system(size: 72, weight: .light))
                        .monospacedDigit()
                        .foregroundColor(.white)
                }
                
                Text("Avg. pace (/mi)")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(Color(hex: "#8E8E93"))
            }
            
            // Distance
            VStack(spacing: 8) {
                Text(formatMiles(tracker.liveSummary?.distance ?? 0))
                    .font(.system(size: 96, weight: .light))
                    .monospacedDigit()
                    .foregroundColor(.white)
                
                Text("Distance (mi)")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundColor(Color(hex: "#8E8E93"))
            }
            
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
                        .font(.system(size: 48))
                        .foregroundColor(Color(hex: "#3A3A3C"))
                    
                    Text("Complete your first mile to see splits")
                        .font(.system(size: 15))
                        .foregroundColor(Color(hex: "#8E8E93"))
                }
            } else {
                // Splits bar chart
                VStack(spacing: 16) {
                    Text("Splits (mi)")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                    
                    // Bar chart
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(mileSplits.indices, id: \.self) { index in
                            VStack(spacing: 4) {
                                // Bar
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(barColor(for: mileSplits[index].time))
                                    .frame(width: 40, height: barHeight(for: mileSplits[index].time))
                                
                                // Mile number
                                Text("\(index + 1)")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(hex: "#8E8E93"))
                            }
                        }
                    }
                    .frame(height: 150)
                    
                    // Splits list
                    VStack(spacing: 0) {
                        ForEach(mileSplits.indices, id: \.self) { index in
                            HStack {
                                Text("Mile \(index + 1)")
                                    .font(.system(size: 15))
                                    .foregroundColor(.white)
                                
                                Spacer()
                                
                                Text(formatPaceFromSplit(mileSplits[index].time))
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(paceColor(mileSplits[index].time))
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 20)
                            
                            if index < mileSplits.count - 1 {
                                Divider().background(Color(hex: "#38383A"))
                            }
                        }
                    }
                    .background(Color(hex: "#1C1C1E"))
                    .cornerRadius(12)
                    .padding(.horizontal, 20)
                }
            }
            
            Spacer()
        }
    }
    
    private func barHeight(for time: TimeInterval) -> CGFloat {
        let maxHeight: CGFloat = 120
        let minHeight: CGFloat = 30
        let avgPace = 600.0 // 10 min/mile baseline
        let ratio = avgPace / max(time, 300) // Faster = taller
        return min(maxHeight, max(minHeight, CGFloat(ratio) * 80))
    }
    
    private func barColor(for time: TimeInterval) -> Color {
        let paceMinutes = time / 60
        if paceMinutes < 8 { return Color(hex: "#007AFF") } // Fast - blue
        if paceMinutes < 10 { return Color(hex: "#34C759") } // Good - green
        return Color(hex: "#FF9500") } // Slow - orange
    
    // MARK: - Bottom Control Bar
    private var bottomControlBar: some View {
        HStack(spacing: 16) {
            if isPaused {
                // Resume button (orange/cyan)
                Button(action: resumeRun) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 18, weight: .bold))
                        Text("Resume")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(accentColor)
                    .cornerRadius(28)
                }
                
                // Finish button
                Button(action: finishRun) {
                    HStack(spacing: 8) {
                        Image(systemName: "flag.checkered")
                            .font(.system(size: 16, weight: .medium))
                        Text("Finish")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color.white)
                    .cornerRadius(28)
                }
            } else {
                // Pause button (when running in expanded mode)
                Button(action: pauseRun) {
                    HStack(spacing: 8) {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 18, weight: .bold))
                        Text("Pause")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color.white)
                    .cornerRadius(28)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 40)
        .background(Color(hex: "#1C1C1E"))
    }
    
    // MARK: - Finish Screen
    private var finishScreen: some View {
        ZStack {
            Color.black
            
            ScrollView {
                VStack(spacing: 0) {
                    if !tracker.trackedLocations.isEmpty {
                        RoutePreviewMap(coordinates: tracker.trackedLocations.map { $0.coordinate })
                            .frame(height: 200)
                            .cornerRadius(12)
                            .padding(.horizontal, 16)
                            .padding(.top, 60)
                    }
                    
                    VStack(spacing: 4) {
                        Text("Run Complete!")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                        
                        Text(Date(), style: .date)
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "#8E8E93"))
                    }
                    .padding(.top, 24)
                    
                    // Stats grid
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
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.white)
                            
                            ForEach(mileSplits.indices, id: \.self) { index in
                                HStack {
                                    Text("Mile \(index + 1)")
                                        .foregroundColor(.white)
                                    Spacer()
                                    Text(formatPaceFromSplit(mileSplits[index].time))
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(paceColor(mileSplits[index].time))
                                }
                            }
                        }
                        .padding(20)
                        .background(Color(hex: "#1C1C1E"))
                        .cornerRadius(16)
                        .padding(.horizontal, 16)
                        .padding(.top, 24)
                    }
                    
                    Spacer(minLength: 120)
                }
            }
            
            VStack {
                Spacer()
                HStack(spacing: 12) {
                    Button(action: { tracker.reset(); dismiss() }) {
                        Text("Discard")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(Color(hex: "#2C2C2E"))
                            .cornerRadius(27)
                    }
                    
                    Button(action: { dismiss() }) {
                        Text("Save")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(accentColor)
                            .cornerRadius(27)
                    }
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
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "#8E8E93"))
                }
            }
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "#8E8E93"))
        }
    }
    
    // MARK: - Actions
    private func pauseRun() {
        isPaused = true
        tracker.pauseTracking()
        voiceAssistant.announceRunPaused()
    }
    
    private func resumeRun() {
        isPaused = false
        tracker.resumeTracking()
        isExpanded = false
        voiceAssistant.announceRunResumed()
    }
    
    private func finishRun() {
        savedSummary = tracker.stopTracking()
        voiceAssistant.announceRunCompleted(
            distance: savedSummary?.distance ?? 0,
            duration: elapsedTime
        )
        showFinishScreen = true
    }
    
    private func checkForMileSplit(distance: Double) {
        let currentMiles = distance / metersPerMile
        let targetMile = Double(mileSplits.count + 1)
        if currentMiles >= targetMile {
            let splitTime = elapsedTime - lastMileTime
            mileSplits.append(MileSplit(time: splitTime))
            lastMileTime = elapsedTime
        }
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
        return String(format: "%.2f", meters / metersPerMile)
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
        if mins < 8 { return Color(hex: "#30D158") }
        if mins < 10 { return Color(hex: "#FFD60A") }
        return Color(hex: "#FF9F0A")
    }
}

struct MileSplit { let time: TimeInterval }

// MARK: - Map Views
struct StravaMapView: UIViewRepresentable {
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
        mapView.removeOverlays(mapView.overlays)
        if coordinates.count > 1 {
            let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            mapView.addOverlay(polyline)
        }
        if isTracking && mapView.userTrackingMode != .followWithHeading {
            mapView.userTrackingMode = .followWithHeading
        }
    }
    
    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polyline = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = UIColor(Color(hex: "#00CED1"))
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
                renderer.strokeColor = UIColor(Color(hex: "#00CED1"))
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
    ActiveRunView(tracker: ActivityTracker(), voiceAssistant: VoiceAssistantManager.shared, elapsedTime: .constant(754))
}
