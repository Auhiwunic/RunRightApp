//
//  CoachChat.swift
//  RunRightApp
//
//  A scoped AI coach. The user describes what they feel; the coach answers
//  grounded in their latest analysis (form summary + gait) and recommends
//  drills FROM the in-app library. The OpenAI key stays server side: the client
//  posts to a `coachChat` Firebase function (COACH_CHAT_ENDPOINT), mirroring
//  analyzeShoe. No key ever ships in the app.
//

import SwiftUI
import FirebaseAuth
import FirebaseAppCheck

// MARK: - Model

struct CoachMessage: Identifiable, Equatable {
    enum Role { case user, coach }
    let id = UUID()
    let role: Role
    let text: String
}

// MARK: - Service

final class CoachChatService {
    static let shared = CoachChatService()

    private var endpoint: String? {
        Bundle.main.object(forInfoDictionaryKey: "COACH_CHAT_ENDPOINT") as? String
    }

    enum CoachError: LocalizedError {
        case notConfigured, notSignedIn, offline, server
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Your coach is not connected yet. Add the coach backend to start chatting."
            case .notSignedIn:   return "Sign in to talk to your coach."
            case .offline:       return "You are offline. Check your connection and try again."
            case .server:        return "Could not reach your coach. Try again in a moment."
            }
        }
    }

    /// Live run stats for the coach, or nil when no run is in progress. Lets the
    /// coach answer "how's my pace" during a run instead of only from stored form.
    @MainActor
    static func runContext() -> [String: Any]? {
        let s = RunSession.shared
        guard s.isActive else { return nil }
        let meters = ActivityTracker.shared.liveSummary?.distance ?? 0
        let miles = meters / 1609.344
        var ctx: [String: Any] = [
            "active": true,
            "elapsedSeconds": Int(s.elapsed.rounded()),
            "distanceMiles": (miles * 100).rounded() / 100
        ]
        if miles > 0.02 { ctx["avgPaceSecPerMile"] = Int(s.elapsed / miles) }
        if let last = s.mileSplits.last?.time { ctx["lastMilePaceSecPerMile"] = Int(last) }
        if let t = s.targetPaceSecPerMile { ctx["targetPaceSecPerMile"] = Int(t) }
        ctx["milesCompleted"] = s.mileSplits.count
        return ctx
    }

    /// Returns the coach's reply plus an optional structured action (schedule a
    /// run, rebuild the profile) that the app applies. Falls back to text only
    /// when the server sends no action. `extraContext` carries live run stats.
    func reply(to message: String, history: [CoachMessage], extraContext: [String: Any]? = nil) async throws -> CoachReply {
        guard let endpoint, !endpoint.isEmpty, let url = URL(string: endpoint) else {
            throw CoachError.notConfigured
        }
        guard let idToken = try await Auth.auth().currentUser?.getIDToken() else {
            throw CoachError.notSignedIn
        }
        var context = Self.groundingContext()
        if let extraContext { context["liveRun"] = extraContext }
        let body: [String: Any] = [
            "message": message,
            "context": context,
            "history": history.suffix(8).map { ["role": $0.role == .user ? "user" : "assistant", "text": $0.text] }
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        // Backend enforces App Check (appCheckOk 401s without the token) — attach it.
        if let appCheckToken = try? await AppCheck.appCheck().token(forcingRefresh: false) {
            request.setValue(appCheckToken.token, forHTTPHeaderField: "X-Firebase-AppCheck")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let e as URLError where e.code == .notConnectedToInternet
            || e.code == .networkConnectionLost || e.code == .timedOut {
            throw CoachError.offline
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CoachError.server
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let reply = (json?["reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reply.isEmpty else { throw CoachError.server }
        let action = (json?["action"] as? [String: Any]).flatMap(CoachAction.init(json:))
        return CoachReply(text: reply, action: action)
    }

    /// The runner's latest analysis + the drills, so the coach answers grounded
    /// in their data and recommends real drills rather than inventing them.
    static func groundingContext() -> [String: Any] {
        var ctx: [String: Any] = [:]
        // Everything from the recorded form video lives under ONE clearly-named
        // key. With `cadence` at the top level the model quoted the VIDEO's
        // cadence as the runner's live cadence ("your cadence is 190" while they
        // stood still) — the data must say what it is, not just the prompt.
        if let form = ScorecardDataStore.shared.load() {
            var video: [String: Any] = [
                "note": "metrics measured in the runner's LAST RECORDED FORM VIDEO, not live values",
                "overallForm": form.overall,
                "cadenceInThatVideo": form.cadence,
                "metrics": form.metrics.map { ["label": $0.label, "value": $0.value] },
            ]
            if let cues = form.cueScores {
                video["cueScores"] = cues.mapValues { Int($0.rounded()) }
            }
            ctx["formVideoAnalysis"] = video
        }
        // The same fused FOCUS list the app shows, so chat answers match the UI.
        ctx["focus"] = Array(FormGaitCrossReference.storedInsights().prefix(4)).map {
            ["title": $0.title, "confidence": $0.corroboration.label]
        }
        ctx["gaitType"] = ScorecardDataStore.shared.loadGaitType() ?? "unknown"
        ctx["strikePattern"] = ScorecardDataStore.shared.loadGaitStrike() ?? "unknown"
        ctx["drills"] = DrillsLibrary.all.map { ["title": $0.title, "target": $0.target, "how": $0.how, "dose": $0.dose] }
        return ctx
    }
}

// MARK: - Chat view

/// Conversation state lives outside the view: the tab views are rebuilt on
/// every tab switch, which used to wipe the chat and silently drop any
/// in-flight coach reply.
@MainActor
final class CoachChatStore: ObservableObject {
    static let shared = CoachChatStore()
    @Published var messages: [CoachMessage] = [
        CoachMessage(role: .coach, text: "Ask me about your form or your next drill.")
    ]
    @Published var sending = false
    /// Set by the scheduling card to send a prompt into the chat; the chat view
    /// picks it up, sends it, and clears it.
    @Published var queuedUserMessage: String?
}

struct CoachChatView: View {
    var embedded: Bool = false
    /// Hard lock: free user who has used up the monthly message allowance.
    var isLocked: Bool = false
    /// Premium unlocks unlimited chat, the live Lewis voice reply, and voice input.
    var isPremium: Bool = false
    var onLockedTap: (() -> Void)? = nil
    /// Fired when the coach action asks to rebuild the training profile — the
    /// parent presents the onboarding questions.
    var onEditProfile: (() -> Void)? = nil

    @ObservedObject private var store = CoachChatStore.shared
    @State private var input = ""
    @StateObject private var voiceInput = CoachVoiceInput()
    @ObservedObject private var voiceEngine = CoachVoiceEngine.shared

    private let starterPrompts = [
        "How was my last run coach?",
        "Which drills fit my focus list?",
        "What should I focus on before my next run?"
    ]

    var body: some View {
        Group {
            if embedded {
                chatContent
                    .appRaisedSurface(fill: AppTheme.cardBg, cornerRadius: 22)
            } else {
                ZStack {
                    AppTheme.bgColor.ignoresSafeArea()
                    chatContent
                }
                .presentationDragIndicator(.visible)
                .presentationBackground(AppTheme.bgColor)
            }
        }
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.sending && !isLocked
    }

    private var showStarterPrompts: Bool {
        store.messages.count == 1 && !store.sending
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image("GaitaLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                    .shadow(color: AppTheme.accentColor.opacity(store.sending ? 0.45 : 0.18), radius: store.sending ? 14 : 7)
                    .rotationEffect(.degrees(store.sending ? 360 : 0))
                    // nil on the stop leg: 360 snaps to 0 (visually identical)
                    // instead of animating a full backwards unwind.
                    .animation(store.sending ? .linear(duration: 1.1).repeatForever(autoreverses: false) : nil, value: store.sending)

                Text("GAITA")
                    .font(AppTheme.head(embedded ? 18 : 24))
                    .foregroundColor(AppTheme.primaryText)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, embedded ? 16 : 20)
            .padding(.top, embedded ? 16 : 18)
            .padding(.bottom, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(store.messages) { bubble($0) }
                        if store.sending {
                            HStack {
                                Text("…")
                                    .font(AppTheme.head(16))
                                    .foregroundColor(AppTheme.primaryText.opacity(0.5))
                                    .padding(.horizontal, 16).padding(.vertical, 10)
                                    .background(AppTheme.raisedFill)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                Spacer(minLength: 40)
                            }
                        }
                    }
                    .padding(.horizontal, embedded ? 14 : 16)
                    .padding(.vertical, 8)
                }
                .frame(minHeight: embedded ? 220 : nil)
                .onChange(of: store.messages.count) { _, _ in
                    withAnimation { proxy.scrollTo(store.messages.last?.id, anchor: .bottom) }
                }
            }

            if showStarterPrompts {
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(starterPrompts, id: \.self) { prompt in
                        Button(action: { send(prompt) }) {
                            HStack {
                                Spacer(minLength: 46)
                                Text(prompt)
                                    .font(AppTheme.bodySemibold(13))
                                    .foregroundColor(.black)
                                    .multilineTextAlignment(.trailing)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(AppTheme.accentColor)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, embedded ? 14 : 16)
                .padding(.bottom, 8)
            }

            HStack(spacing: 10) {
                TextField(voiceInput.phase == .recording ? "Listening…" : "Message Gaita", text: $input, axis: .vertical)
                    .font(AppTheme.body(14))
                    .foregroundColor(AppTheme.primaryText)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .appRaisedBox(cornerRadius: 18)
                    .disabled(isLocked)
                    .onTapGesture {
                        if isLocked { onLockedTap?() }
                }
                if CoachVoiceInput.isSupported {
                    Button(action: { voiceMessageTapped() }) {
                        Image(systemName: voiceInput.phase == .recording ? "stop.circle.fill" : "mic.circle.fill")
                            .font(AppTheme.body(30))
                            .foregroundColor(voiceInput.phase == .recording ? Color(hex: "#FF5252") : AppTheme.accentColor.opacity(isLocked ? 1 : 0.85))
                            .symbolEffect(.pulse, isActive: voiceInput.phase == .recording)
                    }
                    .disabled(voiceInput.phase == .transcribing || store.sending)
                    .accessibilityLabel(voiceInput.phase == .recording ? "Stop recording" : "Dictate a message")
                }
                Button(action: { send() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(AppTheme.body(30))
                        .foregroundColor(canSend || isLocked ? AppTheme.accentColor : AppTheme.primaryText.opacity(0.2))
                }
                .disabled(!canSend && !isLocked)
                .accessibilityLabel("Send message")
            }
            .padding(.horizontal, embedded ? 14 : 16)
            .padding(.top, embedded ? 14 : 16)
            .padding(.bottom, 6)

            if voiceInput.phase == .transcribing {
                Text("Transcribing on device…")
                    .font(AppTheme.body(9))
                    .foregroundColor(AppTheme.primaryText.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 4)
            } else if case .downloading(let f) = voiceEngine.state {
                Text("Downloading coach voice \(Int(f * 100))%")
                    .font(AppTheme.body(9))
                    .foregroundColor(AppTheme.primaryText.opacity(0.4))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 4)
            }

            Text("General fitness guidance, not medical advice. See a professional for pain or injury. Voice messages are transcribed on your device; only the text is sent to your coach.")
                .font(AppTheme.body(9))
                .foregroundColor(AppTheme.primaryText.opacity(0.3))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, embedded ? 14 : 16)
                .padding(.bottom, embedded ? 10 : 12)
        }
        .task {
            // Warm the coach voice only for premium — free replies are text only.
            if isPremium { await CoachVoiceEngine.shared.ensureReady() }
        }
        // Live transcription: words land in the input field as you speak.
        .onChange(of: voiceInput.liveTranscript) { _, text in
            if voiceInput.phase == .recording {
                input = text
            }
        }
        // The scheduling card can queue a prompt; send it as if the user typed it.
        .onChange(of: store.queuedUserMessage) { _, queued in
            guard let queued, !store.sending else { return }
            store.queuedUserMessage = nil
            if isLocked { onLockedTap?(); return }
            send(queued)
        }
    }

    private func voiceMessageTapped() {
        if isLocked {
            onLockedTap?()
            return
        }
        // Voice input (on-device transcription + spoken reply) is a premium feature.
        if !isPremium {
            onLockedTap?()
            return
        }
        Task {
            if voiceInput.phase == .recording {
                if let transcript = await voiceInput.stopAndTranscribe() {
                    input = transcript
                    send(spokenReply: true)
                }
            } else {
                await voiceInput.startRecording()
            }
        }
    }

    private func send(_ preset: String? = nil, spokenReply: Bool = false) {
        if isLocked {
            onLockedTap?()
            return
        }
        let text = (preset ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Snapshot history BEFORE appending the user message, or the same question
        // is sent twice — once as `message`, once as the last history entry —
        // degrading replies and wasting tokens (#11).
        let history = store.messages
        store.messages.append(CoachMessage(role: .user, text: text))
        input = ""
        // Backend kill-switch: if the coach service is turned off server-side
        // (down or being throttled), answer locally instead of hitting it.
        if !RemoteConfigManager.shared.coachEnabled {
            store.messages.append(CoachMessage(role: .coach, text: "Your coach is briefly offline for maintenance. Your form analysis still works — try again soon."))
            return
        }
        store.sending = true
        let liveRun = CoachChatService.runContext()   // non-nil if a run is in progress
        Task {
            let result: String
            var action: CoachAction? = nil
            var succeeded = false
            do {
                let reply = try await CoachChatService.shared.reply(to: text, history: history, extraContext: liveRun)
                result = reply.text
                action = reply.action
                succeeded = true
            } catch {
                CrashReporter.record(error, context: "coach.reply")
                result = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
            }
            await MainActor.run {
                store.messages.append(CoachMessage(role: .coach, text: result))
                store.sending = false
                // Meter against the free monthly allowance only when the coach
                // actually replied — a failed request must not burn a message (#10).
                if succeeded && !isPremium {
                    UsageLimits.shared.recordCoachMessage()
                }
            }
            // Voice in, voice out: speak the reply in Lewis's voice — premium only.
            if spokenReply && isPremium {
                await CoachVoiceEngine.shared.speak(result)
            }
            // The coach can act, not just talk: apply any structured action.
            if let action { await apply(action) }
        }
    }

    /// Carry out a coach action and drop a confirmation into the chat.
    @MainActor
    private func apply(_ action: CoachAction) async {
        let confirmation: String?
        switch action {
        case let .adjustDay(day, change):
            confirmation = await CoachPlanActions.applyAdjustDay(day: day, change: change)
        case let .moveRun(from, to):
            confirmation = await CoachPlanActions.applyMoveRun(from: from, to: to)
        case let .swapDays(a, b):
            confirmation = await CoachPlanActions.applySwapDays(a: a, b: b)
        case let .adjustWeek(change):
            confirmation = await CoachPlanActions.applyAdjustWeek(change: change)
        case .editProfile:
            onEditProfile?()
            return   // opening the profile editor needs no confirmation message
        }
        if let confirmation {
            store.messages.append(CoachMessage(role: .coach, text: confirmation))
        } else {
            // The plan action didn't apply (offline / no plan / unrecognized day).
            // The LLM reply may have already said "Done" — correct that here so the
            // user is never told a change happened when it didn't.
            store.messages.append(CoachMessage(role: .coach,
                text: "Actually, I couldn't make that change to your plan just now. Please try again."))
        }
    }

    private func bubble(_ m: CoachMessage) -> some View {
        HStack {
            if m.role == .user { Spacer(minLength: 40) }
            Text(m.text)
                .font(AppTheme.body(14))
                .foregroundColor(m.role == .user ? .black : AppTheme.primaryText.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(m.role == .user ? AppTheme.accentColor : AppTheme.raisedFill)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
            if m.role == .coach { Spacer(minLength: 40) }
        }
        .id(m.id)
    }
}

// MARK: - Training Zones card (moved here from Home; used on the Run tab)

struct TrainingZonesCard: View {
    var body: some View {
        let hrm = HeartRateZonesManager.shared
        let zones: CalculatedZones = hrm.calculatedZones ?? hrm.calculateZones(
            for: UserFitnessProfile(age: 30, restingHeartRate: 60, knownMaxHeartRate: nil,
                                    fitnessLevel: .intermediate, weight: nil, sex: .male))
        let maxHR = Double(zones.maxHeartRate)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("TRAINING ZONES")
                    .font(AppTheme.head(14))
                    .foregroundColor(AppTheme.primaryText)
                Spacer()
                Text("Max \(zones.maxHeartRate) bpm")
                    .font(AppTheme.bodyMedium(10))
                    .foregroundColor(AppTheme.primaryText.opacity(0.3))
            }
            VStack(spacing: 6) {
                ForEach(zones.zones, id: \.id) { zone in
                    zoneBar(name: zone.name,
                            bpm: "\(zone.range.lowerBound)\u{2013}\(zone.range.upperBound)",
                            percent: min(CGFloat(zone.range.upperBound) / CGFloat(maxHR), 1.0),
                            color: zone.color)
                        .frame(height: 26)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appRaisedSurface(fill: AppTheme.cardBg, cornerRadius: 20)
    }

    private func zoneBar(name: String, bpm: String, percent: CGFloat, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(AppTheme.primaryText.opacity(0.06))
                RoundedRectangle(cornerRadius: 6).fill(color)
                    .frame(width: geo.size.width * percent)
                HStack(spacing: 6) {
                    Text(name).font(AppTheme.bodySemibold(11)).foregroundColor(AppTheme.primaryText)
                    Text(bpm).font(AppTheme.meta(10)).foregroundColor(AppTheme.primaryText.opacity(0.9))
                }
                .padding(.leading, 8)
            }
        }
    }
}

// MARK: - Wrapping tappable chips (dark text on the green plan card)

private struct FlowChips: View {
    let chips: [(String, () -> Void)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
                Button(action: chip.1) {
                    Text(chip.0)
                        .font(AppTheme.bodySemibold(13))
                        .foregroundColor(AppTheme.onAccentPrimary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(AppTheme.onAccentPrimary.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Coach tab (green) — coaching home: today's focus + drills + chat

struct CoachTabView: View {
    private let green = AppTheme.accentColor
    @ObservedObject private var subs = SubscriptionManager.shared
    @ObservedObject private var usage = UsageLimits.shared
    @ObservedObject private var store = CoachChatStore.shared
    @State private var showPaywall = false
    @State private var showProfileEdit = false
    // Loaded once per appearance — computing this in body JSON-decoded the whole
    // stored scorecard (snapshot JPEG included) from UserDefaults on every render.
    @State private var insights: [CombinedInsight] = []

    var body: some View {
        ZStack {
            AppTheme.bgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("COACH")
                            .font(AppTheme.display(32))
                            .foregroundColor(AppTheme.primaryText)
                    }
                    .padding(.top, 20)

                    CoachChatView(
                        embedded: true,
                        // Free users chat until the monthly allowance runs out;
                        // then it hard-locks to the paywall. Premium never locks.
                        isLocked: !subs.isPremium && usage.coachMessagesRemaining == 0,
                        isPremium: subs.isPremium,
                        onLockedTap: { showPaywall = true },
                        onEditProfile: { showProfileEdit = true }
                    )
                    .frame(minHeight: 455)

                    planCard

                    if !subs.isPremium {
                        Text(usage.coachMessagesRemaining > 0
                             ? "\(usage.coachMessagesRemaining) free coach messages left this month. Premium unlocks unlimited chat and the spoken coach voice."
                             : "You have used your free coach messages this month. Premium unlocks unlimited chat and the spoken coach voice.")
                            .font(AppTheme.body(11))
                            .foregroundColor(AppTheme.primaryText.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }

                    // TODAY — top focus from the latest analysis, or a hint to
                    // analyze a run when there's nothing yet (was previously
                    // unreachable dead code).
                    if insights.isEmpty {
                        emptyToday
                    } else {
                        sectionHeader("TODAY")
                        ForEach(insights) { focusCard($0) }
                    }

                    sectionHeader("DRILLS")
                    ForEach(recommendedDrills(for: insights)) { drill in
                        drillCard(drill)
                    }

                    Spacer(minLength: AppTheme.tabBarHeight + 24)
                }
                .padding(.horizontal, 20)
            }
        }
        .onAppear { insights = Array(FormGaitCrossReference.storedInsights().prefix(3)) }
        // The tab persists across switches, so onAppear no longer fires on every
        // return — refresh TODAY insights whenever a new analysis is stored.
        .onReceive(NotificationCenter.default.publisher(for: .analysisSaved)) { _ in
            insights = Array(FormGaitCrossReference.storedInsights().prefix(3))
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .fullScreenCover(isPresented: $showProfileEdit) {
            // Re-run the onboarding questions; on finish it re-persists the
            // profile AND regenerates + saves the weekly plan (see OnboardingView).
            OnboardingView(isPresented: $showProfileEdit)
        }
    }

    // MARK: - Plan-with-coach card (the green scheduling entry point)

    private var planCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(AppTheme.head(15))
                    .foregroundColor(AppTheme.onAccentPrimary)
                Text("PLAN YOUR WEEK")
                    .font(AppTheme.head(15))
                    .foregroundColor(AppTheme.onAccentPrimary)
            }
            Text("Ask your coach to adjust a run or rebuild your whole plan.")
                .font(AppTheme.body(13))
                .foregroundColor(AppTheme.onAccentPrimary.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)

            // Quick actions — the first two go through the coach (which returns an
            // action the app applies); "Rebuild my plan" opens the questions directly.
            FlowChips(chips: [
                ("Easier run tomorrow", { queue("Give me an easier run tomorrow.") }),
                ("Make my whole week easier", { queue("Make my whole week easier please.") }),
                ("Make tomorrow a rest day", { queue("Make tomorrow a rest day please.") }),
                ("Rebuild my plan", { showProfileEdit = true })
            ])
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appRaisedSurface(fill: green, cornerRadius: 20)
    }

    private func queue(_ text: String) {
        if !subs.isPremium && usage.coachMessagesRemaining == 0 { showPaywall = true; return }
        store.queuedUserMessage = text
    }

    private var emptyToday: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TODAY")
                .font(AppTheme.head(14))
                .foregroundColor(AppTheme.primaryText)
            Text("Analyze a run on the Analyze tab and your focus list shows up here.")
                .font(AppTheme.body(13))
                .foregroundColor(AppTheme.primaryText.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appRaisedSurface(fill: AppTheme.cardBg, cornerRadius: 18)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(AppTheme.head(14))
            .foregroundColor(AppTheme.primaryText)
        .padding(.top, 4)
    }

    private func focusCard(_ insight: CombinedInsight) -> some View {
        let color = Color(hex: insight.corroboration.hex)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(insight.corroboration.label)
                    .font(AppTheme.meta(9))
                    .foregroundColor(color)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(color.opacity(0.14)))
                    .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
                Text(insight.title).font(AppTheme.bodySemibold(15)).foregroundColor(AppTheme.primaryText)
                Spacer(minLength: 0)
            }
            Text(insight.detail).font(AppTheme.body(12)).foregroundColor(AppTheme.primaryText.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appRaisedSurface(fill: AppTheme.cardBg, cornerRadius: 18)
    }

    private func recommendedDrills(for insights: [CombinedInsight]) -> [Drill] {
        guard !insights.isEmpty else { return Array(DrillsLibrary.all.prefix(3)) }

        let signal = insights
            .map { "\($0.title) \($0.detail)" }
            .joined(separator: " ")
            .lowercased()

        var titles: [String] = []
        func add(_ title: String) {
            guard !titles.contains(title) else { return }
            titles.append(title)
        }

        if signal.contains("heel") || signal.contains("braking") || signal.contains("cadence") || signal.contains("overstride") {
            add("Cadence bump")
            add("Soft quiet feet")
        }
        if signal.contains("hip") || signal.contains("glute") || signal.contains("pronation") || signal.contains("knee") {
            add("Single leg bridge")
            add("Lateral band walk")
            add("Step down")
        }
        if signal.contains("landing") || signal.contains("impact") || signal.contains("quiet") {
            add("Soft quiet feet")
        }
        if signal.contains("posture") || signal.contains("lean") {
            add("Tall posture")
        }
        if signal.contains("head") || signal.contains("eyes") {
            add("Eyes forward")
        }
        if signal.contains("arm") {
            add("Arm swing")
        }

        let picked = titles.compactMap { wanted in DrillsLibrary.all.first { $0.title == wanted } }
        let fallback = DrillsLibrary.all.filter { drill in !picked.contains { $0.title == drill.title } }
        return Array((picked + fallback).prefix(3))
    }

    private func drillCard(_ drill: Drill) -> some View {
        let color = Color(hex: drill.hex)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(drill.target)
                    .font(AppTheme.meta(9))
                    .foregroundColor(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(color.opacity(0.14)))
                    .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
                Spacer(minLength: 0)
            }
            Text(drill.title)
                .font(AppTheme.head(16))
                .foregroundColor(AppTheme.primaryText)
            Text(drill.how)
                .font(AppTheme.body(12))
                .foregroundColor(AppTheme.primaryText.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            Text(drill.dose.uppercased())
                .font(AppTheme.meta(10))
                .foregroundColor(color)
                .padding(.top, 1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appRaisedSurface(fill: AppTheme.cardBg, cornerRadius: 18)
    }
}
