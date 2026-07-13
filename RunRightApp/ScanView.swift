//
//  ScanView.swift
//  RunRightApp
//
//  Pixel-perfect match to HTML prototype with OpenAIService backend

import SwiftUI
import FirebaseAuth
import PhotosUI

struct ScanView: View {
    /// Which shoe the guided camera is currently capturing.
    private enum CameraSide: String, Identifiable {
        case left, right
        var id: String { rawValue }
    }

    // Persisted so the chosen shoe survives tab switches and app relaunches.
    @Environment(\.dismiss) private var dismiss
    @AppStorage("scan.selectedShoe") private var selectedShoe = ""

    // Shoe list loaded from Firestore
    @State private var shoes: [String] = []
    @State private var isLoadingShoes = true   // true until first Firestore fetch completes
    @State private var showAddShoeAlert = false
    @State private var newShoeName = ""

    // Separate state for left and right shoe
    @State private var cameraSide: CameraSide?
    @State private var pendingRightPrompt = false
    // Take Photo vs Choose from Library
    @State private var chooseSide: CameraSide?
    @State private var showLibrary = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var librarySide: CameraSide?
    @State private var isAnalyzingLeft = false
    @State private var isAnalyzingRight = false
    @State private var leftStatus  = ""   // step label shown inside button while analyzing
    @State private var rightStatus = ""
    @State private var leftError: String?
    @State private var rightError: String?
    @State private var currentPage = 0   // selected page in the wear-pattern history carousel
    @State private var scrollOffset: CGFloat = 0   // drives the header fade
    @ObservedObject private var scanVM = ScanViewModel.shared
    @ObservedObject private var subscriptions = SubscriptionManager.shared
    @ObservedObject private var usage = UsageLimits.shared

    private let accentLime = AppTheme.accentColor
    private let backgroundColor = AppTheme.bgColor
    private let cardBackground = AppTheme.cardBg
    private let cardBackgroundSoft = AppTheme.cardBgAlt
    
    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    ScrollOffsetReader(space: "scanScroll")

                    // Header — fades out as the page scrolls down
                    scanHeader
                        .opacity(scrollFadeOpacity(scrollOffset))
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                    
                    // ── Shoe-required banner ─────────────────────────────
                    if isLoadingShoes {
                        HStack(spacing: 8) {
                            ProgressView().tint(accentLime).scaleEffect(0.8)
                            Text("Loading your shoes…")
                                .font(AppTheme.bodyMedium(13))
                                .foregroundColor(AppTheme.primaryText.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(12)
                        .appRaisedSurface(fill: cardBackground, cornerRadius: 14, shadowRadius: 9, x: 5, y: 5)
                        .padding(.horizontal, 20)
                    } else if selectedShoe.isEmpty {
                        // No shoe selected / none saved yet — block scanning
                        VStack(spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(accentLime)
                                Text("Select a shoe to start scanning")
                                    .font(AppTheme.bodySemibold(14))
                                    .foregroundColor(AppTheme.primaryText)
                            }
                            Text("Use the \"Wear Pattern\" dropdown above to choose a shoe, or add one first.")
                                .font(AppTheme.body(12))
                                .foregroundColor(AppTheme.primaryText.opacity(0.5))
                                .multilineTextAlignment(.center)
                            Button(action: { showAddShoeAlert = true }) {
                                Label("Add New Shoe", systemImage: "plus.circle.fill")
                                    .font(AppTheme.bodySemibold(13))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(accentLime)
                                    .cornerRadius(12)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(16)
                        .appRaisedSurface(fill: cardBackground, cornerRadius: 16, shadowRadius: 9, x: 5, y: 5)
                        .padding(.horizontal, 20)
                    }

                    // ── One guided scan button — left shoe, then right shoe,
                    // one continuous flow instead of two buttons to hunt for. ──
                    let canScan = !selectedShoe.isEmpty && !isLoadingShoes
                    let leftScanned  = currentHistoryPage?.left != nil
                    let rightScanned = currentHistoryPage?.right != nil
                    let bothScanned = leftScanned && rightScanned
                    let isAnalyzing = isAnalyzingLeft || isAnalyzingRight
                    Button(action: { chooseSide = .left }) {
                        VStack(spacing: 3) {
                            HStack(spacing: 8) {
                                if isAnalyzing {
                                    ProgressView().tint(backgroundColor).scaleEffect(0.85)
                                } else {
                                    Image(systemName: bothScanned ? "checkmark.circle.fill" : "camera.fill")
                                        .font(AppTheme.body(14))
                                }
                                Text(bothScanned ? "Rescan Shoes" : "Scan Shoes")
                                    .font(AppTheme.bodySemibold(15))
                            }
                            if isAnalyzing {
                                Text(isAnalyzingLeft
                                     ? (leftStatus.isEmpty ? "Left shoe…" : "Left — \(leftStatus)")
                                     : (rightStatus.isEmpty ? "Right shoe…" : "Right — \(rightStatus)"))
                                    .font(AppTheme.bodyMedium(10))
                                    .opacity(0.75)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                        .foregroundColor(canScan ? backgroundColor : AppTheme.primaryText.opacity(0.4))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(canScan ? accentLime : cardBackgroundSoft)
                        .cornerRadius(16)
                    }
                    .disabled(isAnalyzing || !canScan)
                    .padding(.horizontal, 20)

                    // Free-tier scan allowance (premium is unlimited).
                    if !subscriptions.isPremium {
                        Text("\(usage.scansRemaining) of \(UsageLimits.freeScansPerMonth) free scans left this month")
                            .font(AppTheme.body(11))
                            .foregroundColor(AppTheme.primaryText.opacity(0.45))
                            .padding(.top, 2)
                    }

                    // ── Per-shoe error cards ──────────────────────────────
                    if let error = leftError {
                        errorCard(title: "Left Shoe Failed", message: error)
                    }
                    if let error = rightError {
                        errorCard(title: "Right Shoe Failed", message: error)
                    }
                    
                    // Wear Pattern Card — custom header with dropdown
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Wear Pattern")
                                .font(AppTheme.bodySemibold(16))
                                .foregroundColor(AppTheme.primaryText)
                            Spacer()
                            Menu {
                                ForEach(shoes, id: \.self) { shoe in
                                    Button(shoe) { selectedShoe = shoe }
                                }
                                Divider()
                                Button(action: { showAddShoeAlert = true }) {
                                    Label("Add New Shoe", systemImage: "plus")
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(selectedShoe.isEmpty ? "Select Shoe" : selectedShoe)
                                        .font(AppTheme.bodyMedium(12))
                                        .foregroundColor(selectedShoe.isEmpty ? AppTheme.primaryText.opacity(0.4) : AppTheme.primaryText)
                                    Image(systemName: "chevron.down")
                                        .font(AppTheme.body(9))
                                        .foregroundColor(AppTheme.primaryText.opacity(0.5))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(cardBackgroundSoft)
                                .cornerRadius(10)
                            }
                        }
                        heatmapContainer
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .appRaisedSurface(fill: cardBackground, cornerRadius: 20)
                    .padding(.horizontal, 20)
                    
                    // Wear Analysis — follows whichever date is selected in the carousel
                    if let page = currentHistoryPage, page.left != nil || page.right != nil {
                        scanCard(title: "Wear Analysis") {
                            VStack(alignment: .leading, spacing: 14) {
                                if let left = page.left {
                                    shoeAnalysisSection(snapshot: left, label: "Left")
                                }
                                if let right = page.right {
                                    if page.left != nil {
                                        Rectangle()
                                            .fill(AppTheme.primaryText.opacity(0.08))
                                            .frame(height: 1)
                                    }
                                    shoeAnalysisSection(snapshot: right, label: "Right")
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    
                    // Gait Metrics Card
                    scanCard(title: "Gait Metrics") {
                        statsRow
                    }
                    .padding(.horizontal, 20)
                    
                    // Wear Trend Card
                    scanCard(title: "Wear Trend") {
                        trendContainer
                    }
                    .padding(.horizontal, 20)
                    
                    // Bottom padding for tab bar
                    Spacer().frame(height: AppTheme.tabBarHeight + 24)
                }
            }
            .coordinateSpace(name: "scanScroll")
            .onPreferenceChange(ScrollOffsetKey.self) { scrollOffset = $0 }
        }
        .fullScreenCover(item: $cameraSide, onDismiss: {
            // Present the right-shoe prompt only after the camera cover has
            // fully dismissed — requesting it on a timer while the cover was
            // still animating away made UIKit silently drop the dialog.
            if pendingRightPrompt {
                pendingRightPrompt = false
                chooseSide = .right
            }
        }) { side in
            ShoeCameraView(side: side.rawValue) { image in
                runScan(image: image, side: side.rawValue)
                if side == .left { pendingRightPrompt = true }
            }
        }
        .confirmationDialog(
            "Add \(chooseSide?.rawValue ?? "") sole photo",
            isPresented: Binding(get: { chooseSide != nil }, set: { if !$0 { chooseSide = nil } }),
            titleVisibility: .visible
        ) {
            Button("Take Photo") { let s = chooseSide; chooseSide = nil; cameraSide = s }
            Button("Choose from Library") { librarySide = chooseSide; chooseSide = nil; showLibrary = true }
            Button("Cancel", role: .cancel) { chooseSide = nil }
        }
        .photosPicker(isPresented: $showLibrary, selection: $libraryItem, matching: .images)
        .onChange(of: libraryItem) { _, item in
            guard let item, let side = librarySide else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    await MainActor.run {
                        runScan(image: img, side: side.rawValue)
                        advanceToRightIfNeeded(after: side)   // picker path: delay-based
                    }
                }
                await MainActor.run { libraryItem = nil; librarySide = nil }
            }
        }
        .task {
            await loadShoes()
            guard !selectedShoe.isEmpty else { return }
            // If the shared view model already holds this shoe's history (e.g. we
            // just came back from another tab), reuse it — reloading would briefly
            // empty the carousel and could wipe a scan still saving in the background.
            if scanVM.loadedShoe != selectedShoe || scanVM.historyPages.isEmpty {
                await scanVM.loadScanData(for: selectedShoe)
            }
            currentPage = max(scanVM.historyPages.count - 1, 0)   // open on most recent
        }
        .onChange(of: selectedShoe) { _, newValue in
            Task {
                await scanVM.loadScanData(for: newValue)
                currentPage = max(scanVM.historyPages.count - 1, 0)
            }
        }
        .onChange(of: scanVM.historyPages.count) { _, newCount in
            // Background refresh can shrink/grow the list — keep the index valid.
            if currentPage > newCount - 1 { currentPage = max(newCount - 1, 0) }
        }
        .alert("Add New Shoe", isPresented: $showAddShoeAlert) {
            TextField("e.g. Nike Pegasus 40", text: $newShoeName)
                .autocorrectionDisabled()
            Button("Add") {
                let name = newShoeName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                // ── Optimistic update — instant UI, no Firestore wait ──
                if !shoes.contains(name) { shoes.append(name) }
                selectedShoe = name
                newShoeName = ""
                // ── Persist to Firestore in background ────────────────
                Task {
                    guard let uid = FirebaseAuth.Auth.auth().currentUser?.uid else { return }
                    do { try await ScanRepository.shared.ensureShoeExists(uid: uid, shoeName: name) }
                    catch { debugLog("[Scan] ensureShoeExists failed: \(error)") }
                    await loadShoes()   // refresh ordering; keeps selectedShoe if present
                }
            }
            Button("Cancel", role: .cancel) { newShoeName = "" }
        } message: {
            Text("Enter a name for your shoe.")
        }
    }

    /// After picking the left sole from the photo library, prompt for the right
    /// automatically. The camera path uses the cover's onDismiss instead; the
    /// picker offers no dismissal hook, so this waits out its dismissal animation.
    private func advanceToRightIfNeeded(after side: CameraSide) {
        guard side == .left else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            chooseSide = .right
        }
    }

    // MARK: - Scan Pipeline

    /// Full analyze-and-save pipeline for one shoe photo. The AI result hits the
    /// screen as soon as it's ready; Firestore + Storage persistence runs in the
    /// background and never blocks the UI.
    @MainActor
    private func runScan(image: UIImage, side: String) {
        Task {
            // Meter the paid backend: never exceed the free monthly allowance,
            // even across both shoes or repeated scans within one open session.
            let premium = SubscriptionManager.shared.isPremium
            guard premium || usage.canScan(isPremium: premium) else {
                let msg = "You've used all \(UsageLimits.freeScansPerMonth) free scans this month. Go Premium for unlimited scans."
                if side == "left" { leftError = msg } else { rightError = msg }
                return
            }
            if side == "left" {
                leftError = nil;  isAnalyzingLeft = true;  leftStatus = "Sending to AI…"
            } else {
                rightError = nil; isAnalyzingRight = true; rightStatus = "Sending to AI…"
            }
            do {
                guard let uid = Auth.auth().currentUser?.uid else {
                    throw NSError(domain: "ScanView", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Not signed in. Please sign in and try again."])
                }
                let shoeName = selectedShoe.trimmingCharacters(in: .whitespaces)
                guard !shoeName.isEmpty else {
                    throw NSError(domain: "ScanView", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "Please select or add a shoe before scanning."])
                }

                let scanId = UUID().uuidString
                debugLog("[Scan] \(side) shoe — uid=\(uid) shoe=\(shoeName) scanId=\(scanId)")

                // Most recent saved zones for this side — anchors the AI so wear
                // can only progress between scans, never regress.
                let previousZones: WearZoneData? = scanVM.historyPages.reversed().compactMap {
                    side == "left" ? $0.left?.zones : $0.right?.zones
                }.first

                // Save the sole image locally for the scorecard's gait panel right away
                // — it must appear even if the cloud wear-analysis backend is offline.
                if let soleJpeg = image.jpegData(compressionQuality: 0.85) {
                    ScorecardDataStore.shared.saveGait(image: soleJpeg, gaitType: nil, strikePattern: nil)
                }

                // ── Step 1: Analyze via OpenAI (UIImage → base64, no Storage needed) ──
                if side == "left" { leftStatus = "AI analyzing… (10-20s)" }
                else              { rightStatus = "AI analyzing… (10-20s)" }
                let result = try await ShoeAnalysisService.shared.analyzeSingleShoe(
                    imageUrl: "",
                    side: side,
                    fallbackImage: image,
                    previousZones: previousZones
                )
                debugLog("[Scan] \(side) shoe analysis done — gaitType=\(result.gaitType)")
                ScorecardDataStore.shared.saveGait(image: nil, gaitType: result.gaitType, strikePattern: result.strikePattern)
                ScorecardDataStore.shared.resetWearZonesIfShoeChanged(to: shoeName)
                ScorecardDataStore.shared.saveWearZones(side: side, zones: result.wearZones)

                // Count this scan against the free monthly allowance (premium is
                // unlimited, so only meter free users). One count per side scanned.
                if !SubscriptionManager.shared.isPremium {
                    UsageLimits.shared.recordScan()
                }

                // ── Step 2: Show the heatmap NOW — nothing else gates the result ──
                if side == "left" {
                    isAnalyzingLeft = false;  leftStatus = ""
                } else {
                    isAnalyzingRight = false; rightStatus = ""
                }
                scanVM.mergeLiveScan(side: side, snapshot: ScanSnapshot(result: result))
                currentPage = max(scanVM.historyPages.count - 1, 0)   // jump to today

                // ── Step 3: Persist scan + image in background (fire-and-forget).
                // Firestore awaits a server ack with no timeout, so it must never
                // sit between the AI result and the screen.
                let safeShoeName = shoeName.replacingOccurrences(of: " ", with: "_")
                let storagePath  = "users/\(uid)/scans/\(safeShoeName)/\(scanId)_\(side).jpg"
                Task.detached(priority: .background) {
                    do {
                        try await ScanRepository.shared.saveSingleShoeScan(
                            uid: uid, scanId: scanId, shoeName: shoeName,
                            side: side, result: result, imageDownloadURL: ""
                        )
                        await scanVM.loadScanData(for: shoeName)
                        if let jpegData = image.jpegData(compressionQuality: 0.8) {
                            _ = try await FirebaseStorageService.shared
                                .uploadImageData(jpegData, path: storagePath)
                        }
                    } catch {
                        // The heatmap already rendered from the local result; tell
                        // the user the cloud copy failed instead of dropping it.
                        debugLog("[Scan] cloud sync failed for \(side): \(error)")
                        await MainActor.run {
                            if side == "left" { leftStatus = "Saved on device. Cloud sync failed." }
                            else { rightStatus = "Saved on device. Cloud sync failed." }
                        }
                    }
                }
            } catch {
                debugLog("[Scan] \(side) shoe error: \(error)")
                if side == "left" {
                    leftError = friendlyError(error);  isAnalyzingLeft = false;  leftStatus = ""
                } else {
                    rightError = friendlyError(error); isAnalyzingRight = false; rightStatus = ""
                }
            }
        }
    }

    /// Converts raw errors into readable messages.
    /// OpenAI errors come back as JSON: {"error":{"message":"...","type":"...","code":"..."}}
    private func friendlyError(_ error: Error) -> String {
        let raw = error.localizedDescription
        // Raw backend/OpenAI text (model id, quota, key state, config hints) must
        // never reach the UI — it's an info leak and reads badly to a reviewer.
        // Keep the detail in debug logs; show the user a plain, actionable line.
        debugLog("[Scan] error raw=\(raw)")
        let lower = raw.lowercased()
        // Our own pre-flight guards carry safe, user-facing copy — pass through.
        if lower.contains("not signed in") || lower.contains("select or add a shoe")
            || lower.contains("free scans this month") {
            return raw
        }
        if lower.contains("offline") || lower.contains("internet") || lower.contains("network")
            || lower.contains("timed out") || lower.contains("connection") {
            return "You appear to be offline. Reconnect and try again."
        }
        if lower.contains("429") || lower.contains("rate") || lower.contains("quota")
            || lower.contains("busy") || lower.contains("temporarily") {
            return "Shoe scanning is busy right now. Please try again in a moment."
        }
        return "Couldn't analyze that photo. Make sure the sole is well lit and centered, then try again."
    }

    private func loadShoes() async {
        isLoadingShoes = true
        defer { isLoadingShoes = false }
        guard let uid = FirebaseAuth.Auth.auth().currentUser?.uid else { return }
        let fetched = (try? await ScanRepository.shared.fetchShoeNames(uid: uid)) ?? []
        shoes = fetched
        // Auto-select the first shoe if nothing is selected yet
        if selectedShoe.isEmpty, let first = fetched.first {
            selectedShoe = first
        }
    }
    
    
    private func errorCard(title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(AppTheme.bodyMedium(14))
                .foregroundColor(Color(hex: "#FF8C00"))
            Text(message)
                .font(AppTheme.body(12))
                .foregroundColor(AppTheme.primaryText.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .appRaisedSurface(fill: cardBackground, cornerRadius: 14, shadowRadius: 9, x: 5, y: 5)
        .padding(.horizontal, 20)
    }
    
    // MARK: - Header
    private var scanHeader: some View {
        HStack {
            Text("Gait Analysis")
                .font(AppTheme.display(32))
                .foregroundColor(AppTheme.primaryText)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(AppTheme.bodySemibold(14))
                    .foregroundColor(AppTheme.primaryText.opacity(0.7))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(AppTheme.primaryText.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }
    
    // MARK: - Card wrapper
    private func scanCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(AppTheme.bodySemibold(16))
                .foregroundColor(AppTheme.primaryText)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appRaisedSurface(fill: cardBackground, cornerRadius: 20)
    }
    
    // MARK: - Heatmap History Carousel

    /// The page currently shown in the carousel (clamped to valid range).
    private var currentHistoryPage: ScanHistoryPage? {
        let pages = scanVM.historyPages
        guard !pages.isEmpty else { return nil }
        return pages[min(max(currentPage, 0), pages.count - 1)]
    }

    private var heatmapContainer: some View {
        VStack(spacing: 14) {
            if scanVM.historyPages.isEmpty {
                // Empty state — placeholder grids, no scans yet for this shoe
                HStack(spacing: 30) {
                    FootHeatmapView(isLeft: true, wearZones: nil)
                    FootHeatmapView(isLeft: false, wearZones: nil)
                }
                .frame(maxWidth: .infinity)

                Text("No scans yet. Scan each shoe above to see its wear pattern.")
                    .font(AppTheme.body(12))
                    .foregroundColor(AppTheme.primaryText.opacity(0.4))
                    .multilineTextAlignment(.center)
            } else {
                // Date of the scan being viewed
                Text(dateLabel(for: currentHistoryPage?.date))
                    .font(AppTheme.bodySemibold(13))
                    .foregroundColor(accentLime)
                    .frame(maxWidth: .infinity)
                    .animation(nil, value: currentPage)

                // Swipeable pages with arrows on either side
                ZStack {
                    TabView(selection: $currentPage) {
                        ForEach(scanVM.historyPages.indices, id: \.self) { index in
                            let page = scanVM.historyPages[index]
                            // Balance the pair for the heatmaps only; the wear
                            // analysis text below reads the raw per-shoe zones.
                            let (balL, balR) = WearSymmetry.balanced(page.left?.zones, page.right?.zones)
                            HStack(spacing: 30) {
                                FootHeatmapView(isLeft: true, wearZones: balL)
                                FootHeatmapView(isLeft: false, wearZones: balR)
                            }
                            .tag(index)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: 240)

                    HStack {
                        carouselArrow("chevron.left", enabled: currentPage > 0) {
                            withAnimation(.easeInOut) { currentPage -= 1 }
                        }
                        Spacer()
                        carouselArrow("chevron.right", enabled: currentPage < scanVM.historyPages.count - 1) {
                            withAnimation(.easeInOut) { currentPage += 1 }
                        }
                    }
                }
            }

        }
    }

    private func carouselArrow(_ systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(AppTheme.meta(13))
                .foregroundColor(enabled ? AppTheme.primaryText.opacity(0.85) : AppTheme.primaryText.opacity(0.15))
                .frame(width: 32, height: 32)
                .background(cardBackgroundSoft.opacity(enabled ? 1 : 0.4))
                .clipShape(Circle())
        }
        .disabled(!enabled)
    }

    private func dateLabel(for date: Date?) -> String {
        guard let date else { return "" }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        return formatter.string(from: date)
    }
    
    // MARK: - Stats Row
    private var statsRow: some View {
        let page = currentHistoryPage
        let pronationType = page?.left?.gaitType.capitalized ?? page?.right?.gaitType.capitalized ?? "—"
        let symmetryValue: String = {
            guard let left = page?.left?.zones,
                  let right = page?.right?.zones else {
                return "—"
            }
            // Numeric score comparison for smoother symmetry %
            let leftZones = [left.bigToe, left.lesserToes, left.medialBall, left.centralBall, left.lateralBall, left.medialMidfoot, left.lateralMidfoot, left.medialHeel, left.centralHeel, left.lateralHeel]
            let rightZones = [right.bigToe, right.lesserToes, right.medialBall, right.centralBall, right.lateralBall, right.medialMidfoot, right.lateralMidfoot, right.medialHeel, right.centralHeel, right.lateralHeel]
            var totalDiff: Double = 0
            for i in 0..<10 {
                totalDiff += abs(wearScore(leftZones[i]) - wearScore(rightZones[i]))
            }
            let avgDiff = totalDiff / 10.0
            let symmetry = Int((1.0 - avgDiff) * 100)
            return "\(max(symmetry, 0))%"
        }()
        
        // Any pronation/supination is a flag — color it; neutral stays clean.
        let pronationColor: Color = {
            switch pronationType.lowercased() {
            case "neutral", "—": return AppTheme.primaryText
            case "overpronation": return Color(hex: "#E83030")   // red
            default:              return Color(hex: "#E89830")   // orange
            }
        }()

        return HStack(spacing: 10) {
            ScanStatCard(
                label: "Pronation",
                value: pronationType,
                valueColor: pronationColor,
                guide: MetricGuide.pronation
            )

            ScanStatCard(
                icon: "arrow.left.and.right",
                label: "Symmetry",
                value: symmetryValue,
                isSymmetry: true,
                accent: accentLime,
                guide: MetricGuide.wearSymmetry
            )
        }
    }
    
    // MARK: - Trend Container
    private var trendContainer: some View {
        VStack(spacing: 12) {
            if scanVM.hasTrend {
                TrendChartView(dataPoints: scanVM.trendPoints, accent: accentLime, bg: backgroundColor)
                    .frame(height: 80)

                // First & last scan dates at the ends of the line.
                HStack {
                    if let first = scanVM.trendLabels.first {
                        Text(first)
                            .font(AppTheme.bodyMedium(10))
                            .foregroundColor(AppTheme.primaryText.opacity(0.4))
                    }
                    Spacer()
                    if let last = scanVM.trendLabels.last {
                        Text(last)
                            .font(AppTheme.bodyMedium(10))
                            .foregroundColor(AppTheme.primaryText.opacity(0.4))
                    }
                }
            } else {
                // Not enough scans yet to draw a line.
                Text("No trend yet")
                    .font(AppTheme.bodyMedium(13))
                    .foregroundColor(AppTheme.primaryText.opacity(0.3))
                    .frame(maxWidth: .infinity)
                    .frame(height: 80)
            }
        }
    }
    
    // MARK: - Structured Analysis Section
    
    @ViewBuilder
    private func shoeAnalysisSection(snapshot shoe: ScanSnapshot, label: String) -> some View {
        let health = shoeHealthPercent(snapshot: shoe)
        let strikeText = (shoe.strikePattern?.isEmpty == false) ? ", \(shoe.strikePattern!.lowercased()) strike" : ""

        // The heatmap above is the read. This is just a one line summary plus a
        // comfort first note. Coaching now lives in the Analyze FOCUS list.
        VStack(alignment: .leading, spacing: 6) {
            Text("\(label): \(shoe.gaitType.capitalized)\(strikeText)")
                .font(AppTheme.meta(13))
                .foregroundColor(accentLime)

            if let miles = shoe.estimatedMilesRemaining {
                Text("~\(miles) miles left")
                    .font(AppTheme.bodySemibold(12))
                    .foregroundColor(AppTheme.primaryText.opacity(0.75))
            }

            if let h = health {
                Text("Tread health \(h)%. Replace shoes based on how they feel, not a number.")
                    .font(AppTheme.body(11))
                    .foregroundColor(AppTheme.primaryText.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
                Text("General fitness guidance, not medical advice. See a professional for pain or injury.")
                    .font(AppTheme.body(9))
                    .foregroundColor(AppTheme.primaryText.opacity(0.3))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let conf = shoe.confidence, conf < 50 {
                Text("The photo was hard to read. Retake it in brighter light for a sharper result.")
                    .font(AppTheme.body(11))
                    .foregroundColor(Color(hex: "#E89830"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    // MARK: - On-Device Computed Stats
    
    /// Score a color string: green=1.0, yellow=0.45, orange=0.15, red=0.0
    private func wearScore(_ color: String) -> Double {
        switch color.lowercased() {
        case "green": return 1.0
        case "yellow": return 0.45
        case "orange": return 0.15
        case "red": return 0.0
        default: return 1.0
        }
    }
    
    /// Health per shoe. Scans from the gpt-5.6 upgrade carry numeric wear depth
    /// per zone (0 fresh, 100 gone) — average those for a finer read. Older
    /// scans fall back to the four color buckets.
    private func shoeHealthPercent(snapshot: ScanSnapshot) -> Int? {
        if let percents = snapshot.wearPercents, !percents.isEmpty {
            let avgWear = Double(percents.values.reduce(0, +)) / Double(percents.count)
            return Int((100 - avgWear).rounded())
        }
        return shoeHealthPercent(zones: snapshot.zones)
    }

    /// Compute shoe health % from wear zone data (0-100). Returns nil if no zones.
    private func shoeHealthPercent(zones: WearZoneData?) -> Int? {
        guard let z = zones else { return nil }
        let scores = [
            wearScore(z.bigToe), wearScore(z.lesserToes),
            wearScore(z.medialBall), wearScore(z.centralBall), wearScore(z.lateralBall),
            wearScore(z.medialMidfoot), wearScore(z.lateralMidfoot),
            wearScore(z.medialHeel), wearScore(z.centralHeel), wearScore(z.lateralHeel)
        ]
        let avg = scores.reduce(0, +) / Double(scores.count)
        return Int(avg * 100)
    }
    
    
}

// MARK: - Foot Heatmap View
struct FootHeatmapView: View {
    let isLeft: Bool
    var wearZones: WearZoneData?
    var labelDesign: Font.Design = .monospaced
    var showLabel: Bool = true
    /// Cell metrics are tunable so the map can render small (Analyze mini card)
    /// with the exact same shape and blending as the full scan sheet.
    var cellSize: CGFloat = 5
    var cellSpacing: CGFloat = 1

    private let columns = 16
    private let rows = 33
    private let cornerRadius: CGFloat = 1.5
    private let blendRadius = 3          // wider neighborhood → smoother gradient
    private let blendPasses = 3          // more passes → softer color transitions
    private let greenWearSensitivity: CGFloat = 1.2   // gentle; don't over-redden
    private let wornWearSensitivity: CGFloat = 1.6    // softened so worn != instant red
    
    private struct RGBA {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
        var a: CGFloat
    }
    
    // Shoe shape data - pre-computed for performance
    // 1 = shoe cell, 0 = empty
    private let shoeShapeData: [[Int]] = [
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
        [0,0,0,0,0,0,1,1,1,1,1,1,0,0,0,0],
        [0,0,0,0,0,1,1,1,1,1,1,1,1,0,0,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0],
        [0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
        [0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0],
        [0,0,0,1,1,1,1,1,1,1,1,1,1,1,1,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,1,1,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,0,0,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,0,0,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,1,0,0,0],
        [0,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0],
        [0,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0],
        [0,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,1,1,1,1,1,1,1,1,1,1,1,1,0,0],
        [0,0,0,1,1,1,1,1,1,1,1,1,1,0,0,0],
        [0,0,0,0,1,1,1,1,1,1,1,1,0,0,0,0],
        [0,0,0,0,0,1,1,1,1,1,1,0,0,0,0,0],
        [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]
    ]
    
    var body: some View {
        let displayGrid = buildDisplayColorGrid()
        
        VStack(spacing: 8) {
            if showLabel {
                Text(isLeft ? "Left" : "Right")
                    .font(AppTheme.meta(13))
                    .foregroundColor(AppTheme.primaryText)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }
            
            // Simple VStack + HStack grid (more reliable than LazyVGrid)
            VStack(spacing: cellSpacing) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: cellSpacing) {
                        ForEach(0..<columns, id: \.self) { col in
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .fill(displayGrid[row][col])
                                .frame(width: cellSize, height: cellSize)
                        }
                    }
                }
            }
        }
    }
    
    /// Maps a cell (row, col) to one of the 10 biomechanical gait zones.
    /// SOLE view — matches the scan photo (sole facing you, toe at top).
    /// Flipping a shoe over mirrors it: a LEFT sole's medial (big toe/arch) edge
    /// is on the LEFT of the image; a RIGHT sole's medial edge is on the RIGHT.
    private func zoneForCell(row: Int, col: Int) -> String {
        let medialSide: Bool
        if isLeft {
            medialSide = col < columns / 2   // left half = medial for left sole
        } else {
            medialSide = col >= columns / 2  // right half = medial for right sole
        }

        // For 3-way splits (ball, heel): inner third, middle third, outer third
        let innerThird: Bool
        let outerThird: Bool
        if isLeft {
            innerThird = col < columns / 3       // cols 0-4 = medial for left sole
            outerThird = col >= columns * 2 / 3  // cols 10-15 = lateral for left sole
        } else {
            innerThird = col >= columns * 2 / 3  // cols 10-15 = medial for right sole
            outerThird = col < columns / 3       // cols 0-4 = lateral for right sole
        }
        
        // TOES: rows 0-5
        if row <= 5 {
            return medialSide ? "bigToe" : "lesserToes"
        }
        
        // BALL (metatarsal heads): rows 6-12 — 3-way split
        if row <= 12 {
            if innerThird {
                return "medialBall"
            } else if outerThird {
                return "lateralBall"
            } else {
                return "centralBall"
            }
        }
        
        // MIDFOOT (arch): rows 13-24 — 2-way split
        if row <= 24 {
            return medialSide ? "medialMidfoot" : "lateralMidfoot"
        }
        
        // HEEL: rows 25-32 — 3-way split
        if innerThird {
            return "medialHeel"
        } else if outerThird {
            return "lateralHeel"
        } else {
            return "centralHeel"
        }
    }
    
    /// Converts a color string ("green", "yellow", "orange", "red") to a SwiftUI Color
    private func colorFromString(_ colorStr: String) -> Color {
        switch colorStr.lowercased() {
        case "red": return Color(hex: "#E83030")
        case "orange": return Color(hex: "#E89830")
        case "yellow": return Color(hex: "#E8D44A")
        default: return Color(hex: "#5ECC3A")
        }
    }
    
    private func buildDisplayColorGrid() -> [[Color]] {
        let baseGrid = buildBaseColorGrid()

        // No scan data: neutral placeholder grid — no blending needed.
        guard wearZones != nil else {
            return baseGrid
        }

        return buildBlendedColorGrid(from: baseGrid)
    }

    private func buildBaseColorGrid() -> [[Color]] {
        var grid = Array(
            repeating: Array(repeating: Color.clear, count: columns),
            count: rows
        )

        // Dim neutral cells when there's no scan yet — shows the shoe outline only.
        let placeholder = AppTheme.primaryText.opacity(0.08)

        for row in 0..<rows {
            for col in 0..<columns {
                guard isShoeCell(row: row, col: col) else {
                    continue
                }

                if let zones = wearZones {
                    grid[row][col] = colorFromString(zones.color(for: zoneForCell(row: row, col: col)))
                } else {
                    grid[row][col] = placeholder
                }
            }
        }

        return grid
    }
    
    private func buildBlendedColorGrid(from baseGrid: [[Color]]) -> [[Color]] {
        var currentGrid = baseGrid
        
        for _ in 0..<blendPasses {
            var nextGrid = currentGrid
            
            for row in 0..<rows {
                for col in 0..<columns {
                    guard isShoeCell(row: row, col: col) else {
                        nextGrid[row][col] = .clear
                        continue
                    }
                    nextGrid[row][col] = blendedColor(row: row, col: col, baseGrid: currentGrid)
                }
            }
            
            currentGrid = nextGrid
        }
        
        return currentGrid
    }
    
    private func blendedColor(row: Int, col: Int, baseGrid: [[Color]]) -> Color {
        var totalWeight: CGFloat = 0
        var sumR: CGFloat = 0
        var sumG: CGFloat = 0
        var sumB: CGFloat = 0
        var sumA: CGFloat = 0
        
        for dRow in -blendRadius...blendRadius {
            for dCol in -blendRadius...blendRadius {
                let nRow = row + dRow
                let nCol = col + dCol
                
                guard nRow >= 0, nRow < rows, nCol >= 0, nCol < columns,
                      isShoeCell(row: nRow, col: nCol) else {
                    continue
                }
                
                let weight = kernelWeight(dRow: dRow, dCol: dCol)
                let rgba = rgba(from: baseGrid[nRow][nCol])
                
                totalWeight += weight
                sumR += rgba.r * weight
                sumG += rgba.g * weight
                sumB += rgba.b * weight
                sumA += rgba.a * weight
            }
        }
        
        guard totalWeight > 0 else {
            return baseGrid[row][col]
        }
        
        let averaged = RGBA(
            r: sumR / totalWeight,
            g: sumG / totalWeight,
            b: sumB / totalWeight,
            a: sumA / totalWeight
        )
        
        // Post-process sensitivity curve: mildly boost early wear and aggressively boost
        // already-worn regions so red/orange emerges faster where tread is degraded.
        let adjusted = applyWearSensitivity(to: averaged)
        return color(from: adjusted)
    }
    
    private func kernelWeight(dRow: Int, dCol: Int) -> CGFloat {
        // Smooth Gaussian falloff by true distance → continuous gradient instead of
        // the old 3-tier step weighting (which left visible color banding).
        let distSq = CGFloat(dRow * dRow + dCol * dCol)
        let sigma = CGFloat(blendRadius) / 1.5
        return exp(-distSq / (2 * sigma * sigma))
    }
    
    private func isShoeCell(row: Int, col: Int) -> Bool {
        guard row >= 0, row < rows, col >= 0, col < columns else {
            return false
        }
        
        // Symmetric outline: a cell is part of the shoe only where the raw shape
        // AND its mirror agree. This forces left and right to render the SAME
        // spots (a matched, symmetric pair) instead of two differently-leaning
        // outlines. Wear colours still map per real medial/lateral side.
        guard row < shoeShapeData.count else { return false }
        let mirrorCol = columns - 1 - col
        let a = col >= 0 && col < shoeShapeData[row].count && shoeShapeData[row][col] == 1
        let b = mirrorCol >= 0 && mirrorCol < shoeShapeData[row].count && shoeShapeData[row][mirrorCol] == 1
        return a && b
    }
    
    private func rgba(from color: Color) -> RGBA {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        
        if uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return RGBA(r: red, g: green, b: blue, a: alpha)
        }
        
        return RGBA(r: 0, g: 0, b: 0, a: 0)
    }
    
    private func color(from rgba: RGBA) -> Color {
        Color(
            uiColor: UIColor(
                red: rgba.r,
                green: rgba.g,
                blue: rgba.b,
                alpha: rgba.a
            )
        )
    }
    
    private func applyWearSensitivity(to rgba: RGBA) -> RGBA {
        let score = wearScore(for: rgba)
        let adjustedScore = adjustedWearScore(from: score)
        return rgbaForWearScore(adjustedScore)
    }
    
    private func adjustedWearScore(from score: CGFloat) -> CGFloat {
        let greenBoundary: CGFloat = 1.0 / 3.0
        
        if score <= greenBoundary {
            return clamp(score * greenWearSensitivity, min: 0, max: 1)
        }
        
        let boostedTail = greenBoundary + (score - greenBoundary) * wornWearSensitivity
        return clamp(boostedTail, min: 0, max: 1)
    }
    
    private func wearScore(for rgba: RGBA) -> CGFloat {
        let stops = wearPaletteStops
        var bestDistance = CGFloat.greatestFiniteMagnitude
        var bestScore: CGFloat = 0
        
        for index in 0..<(stops.count - 1) {
            let start = stops[index]
            let end = stops[index + 1]
            
            let segment = (
                r: end.color.r - start.color.r,
                g: end.color.g - start.color.g,
                b: end.color.b - start.color.b
            )
            let point = (
                r: rgba.r - start.color.r,
                g: rgba.g - start.color.g,
                b: rgba.b - start.color.b
            )
            
            let segLenSq = segment.r * segment.r + segment.g * segment.g + segment.b * segment.b
            guard segLenSq > 0 else { continue }
            
            let projection = clamp(
                (point.r * segment.r + point.g * segment.g + point.b * segment.b) / segLenSq,
                min: 0,
                max: 1
            )
            
            let projected = RGBA(
                r: start.color.r + segment.r * projection,
                g: start.color.g + segment.g * projection,
                b: start.color.b + segment.b * projection,
                a: 1
            )
            
            let distance = colorDistanceSquared(a: rgba, b: projected)
            if distance < bestDistance {
                bestDistance = distance
                bestScore = start.t + (end.t - start.t) * projection
            }
        }
        
        return clamp(bestScore, min: 0, max: 1)
    }
    
    private func rgbaForWearScore(_ score: CGFloat) -> RGBA {
        let t = clamp(score, min: 0, max: 1)
        let stops = wearPaletteStops
        
        for index in 0..<(stops.count - 1) {
            let start = stops[index]
            let end = stops[index + 1]
            
            if t >= start.t && t <= end.t {
                let localT = (t - start.t) / (end.t - start.t)
                return lerp(a: start.color, b: end.color, t: localT)
            }
        }
        
        return stops.last?.color ?? RGBA(r: 0, g: 0, b: 0, a: 1)
    }
    
    private var wearPaletteStops: [(t: CGFloat, color: RGBA)] {
        [
            (0.0, RGBA(r: 94.0 / 255.0,  g: 204.0 / 255.0, b: 58.0 / 255.0,  a: 1)),
            (1.0 / 3.0, RGBA(r: 232.0 / 255.0, g: 212.0 / 255.0, b: 74.0 / 255.0,  a: 1)),
            (2.0 / 3.0, RGBA(r: 232.0 / 255.0, g: 152.0 / 255.0, b: 48.0 / 255.0,  a: 1)),
            (1.0, RGBA(r: 232.0 / 255.0, g: 48.0 / 255.0,  b: 48.0 / 255.0,  a: 1))
        ]
    }
    
    private func lerp(a: RGBA, b: RGBA, t: CGFloat) -> RGBA {
        RGBA(
            r: a.r + (b.r - a.r) * t,
            g: a.g + (b.g - a.g) * t,
            b: a.b + (b.b - a.b) * t,
            a: a.a + (b.a - a.a) * t
        )
    }
    
    private func colorDistanceSquared(a: RGBA, b: RGBA) -> CGFloat {
        let dr = a.r - b.r
        let dg = a.g - b.g
        let db = a.b - b.b
        return dr * dr + dg * dg + db * db
    }
    
    private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        Swift.max(lower, Swift.min(upper, value))
    }
}

// MARK: - Scan Stat Card
struct ScanStatCard: View {
    var icon: String? = nil          // optional — omit for an icon-less card
    let label: String
    let value: String
    var isSymmetry: Bool = false
    var accent: Color = AppTheme.accentColor
    var valueColor: Color = AppTheme.primaryText   // adaptive by default; callers pass red/orange for status
    var guide: MetricGuideEntry? = nil
    @State private var showGuide = false

    var body: some View {
        Button(action: { showGuide = true }) {
            VStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(AppTheme.head(16))
                        .foregroundColor(accent)
                }

                HStack(spacing: 3) {
                    Text(label)
                        .font(AppTheme.bodyMedium(11))
                        .foregroundColor(AppTheme.primaryText.opacity(0.5))
                    if guide != nil {
                        Image(systemName: "info.circle")
                            .font(AppTheme.body(8))
                            .foregroundColor(AppTheme.primaryText.opacity(0.28))
                    }
                }

                Text(value)
                    .font(AppTheme.bodySemibold(18))
                    .foregroundColor(valueColor)
            }
            .frame(maxWidth: .infinity, minHeight: 90)
            .padding(.vertical, 14)
            .appRaisedBox(cornerRadius: 14)
        }
        .buttonStyle(.plain)
        .disabled(guide == nil)
        .sheet(isPresented: $showGuide) {
            if let guide {
                MetricGuideSheet(entry: guide, accent: accent)
            }
        }
    }
}

// MARK: - Trend Chart View
struct TrendChartView: View {
    var dataPoints: [CGFloat]
    var accent: Color = AppTheme.accentColor
    var bg: Color = AppTheme.bgColor
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let stepX = dataPoints.count >= 2 ? width / CGFloat(dataPoints.count - 1) : width
            
            ZStack {
                // Grid lines
                ForEach([0.25, 0.5, 0.75], id: \.self) { y in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height * (1 - y)))
                        path.addLine(to: CGPoint(x: width, y: height * (1 - y)))
                    }
                    .stroke(AppTheme.primaryText.opacity(0.06), lineWidth: 1)
                }
                
                // Area fill
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height))
                    for (index, value) in dataPoints.enumerated() {
                        let x = CGFloat(index) * stepX
                        let y = height * (1 - value)
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.addLine(to: CGPoint(x: width, y: height))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [accent.opacity(0.3), accent.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                
                // Line (smooth, no dots)
                Path { path in
                    guard dataPoints.count >= 2 else {
                        path.move(to: CGPoint(x: 0, y: height))
                        path.addLine(to: CGPoint(x: width, y: height))
                        return
                    }
                    for (index, value) in dataPoints.enumerated() {
                        let x = CGFloat(index) * stepX
                        let y = height * (1 - value)
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(accent.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: - Section Header
struct ScanSectionHeader: View {
    let title: String
    
    var body: some View {
        Text(title)
            .font(AppTheme.bodySemibold(16))
            .foregroundColor(AppTheme.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
    }
}

// MARK: - Section Divider
struct ScanSectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(AppTheme.primaryText.opacity(0.06))
            .frame(height: 1)
    }
}

#Preview {
    ScanView()
}
