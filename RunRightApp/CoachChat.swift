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

    func reply(to message: String, history: [CoachMessage]) async throws -> String {
        guard let endpoint, !endpoint.isEmpty, let url = URL(string: endpoint) else {
            throw CoachError.notConfigured
        }
        guard let idToken = try await Auth.auth().currentUser?.getIDToken() else {
            throw CoachError.notSignedIn
        }
        let body: [String: Any] = [
            "message": message,
            "context": Self.groundingContext(),
            "history": history.suffix(8).map { ["role": $0.role == .user ? "user" : "assistant", "text": $0.text] }
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
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
        return reply
    }

    /// The runner's latest analysis + the drills, so the coach answers grounded
    /// in their data and recommends real drills rather than inventing them.
    static func groundingContext() -> [String: Any] {
        var ctx: [String: Any] = [:]
        if let form = ScorecardDataStore.shared.load() {
            ctx["overallForm"] = form.overall
            ctx["cadence"] = form.cadence
            ctx["metrics"] = form.metrics.map { ["label": $0.label, "value": $0.value] }
            if let cues = form.cueScores {
                ctx["cueScores"] = cues.mapValues { Int($0.rounded()) }
            }
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

struct CoachChatView: View {
    var embedded: Bool = false
    var isLocked: Bool = false
    var onLockedTap: (() -> Void)? = nil

    @State private var messages: [CoachMessage] = [
        CoachMessage(role: .coach, text: "Ask me about your form or your next drill.")
    ]
    @State private var input = ""
    @State private var sending = false

    private let starterPrompts = [
        "How was my last run coach?",
        "What drills should I do to minimize knee pain?",
        "What should I focus on before my next run?"
    ]

    var body: some View {
        Group {
            if embedded {
                chatContent
                    .background(Color(hex: "#202024"))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            } else {
                ZStack {
                    Color(hex: "#1A1A1C").ignoresSafeArea()
                    chatContent
                }
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(hex: "#1A1A1C"))
            }
        }
    }

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending && !isLocked
    }

    private var showStarterPrompts: Bool {
        messages.count == 1 && !sending
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image("GaitaLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)
                    .shadow(color: Color(hex: "#00FF7F").opacity(sending ? 0.45 : 0.18), radius: sending ? 14 : 7)
                    .rotationEffect(.degrees(sending ? 360 : 0))
                    .animation(sending ? .linear(duration: 1.1).repeatForever(autoreverses: false) : .default, value: sending)

                Text("GAITA")
                    .font(.system(size: embedded ? 18 : 24, weight: .bold))
                    .foregroundColor(.white)

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, embedded ? 16 : 20)
            .padding(.top, embedded ? 16 : 18)
            .padding(.bottom, 10)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(messages) { bubble($0) }
                        if sending {
                            HStack {
                                Text("…")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white.opacity(0.5))
                                    .padding(.horizontal, 16).padding(.vertical, 10)
                                    .background(Color(hex: "#2A2A2E"))
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                Spacer(minLength: 40)
                            }
                        }
                    }
                    .padding(.horizontal, embedded ? 14 : 16)
                    .padding(.vertical, 8)
                }
                .frame(minHeight: embedded ? 220 : nil)
                .onChange(of: messages.count) { _, _ in
                    withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
                }
            }

            if showStarterPrompts {
                VStack(alignment: .trailing, spacing: 8) {
                    ForEach(starterPrompts, id: \.self) { prompt in
                        Button(action: { send(prompt) }) {
                            HStack {
                                Spacer(minLength: 46)
                                Text(prompt)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.black)
                                    .multilineTextAlignment(.trailing)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Color(hex: "#00FF7F"))
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
                TextField("Message Gaita", text: $input, axis: .vertical)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .disabled(isLocked)
                    .onTapGesture {
                        if isLocked { onLockedTap?() }
                }
                Button(action: { send() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(canSend || isLocked ? Color(hex: "#00FF7F") : .white.opacity(0.2))
                }
                .disabled(!canSend && !isLocked)
            }
            .padding(embedded ? 14 : 16)
        }
    }

    private func send(_ preset: String? = nil) {
        if isLocked {
            onLockedTap?()
            return
        }
        let text = (preset ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(CoachMessage(role: .user, text: text))
        input = ""
        sending = true
        let history = messages
        Task {
            let result: String
            do {
                result = try await CoachChatService.shared.reply(to: text, history: history)
            } catch {
                result = (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
            }
            await MainActor.run {
                messages.append(CoachMessage(role: .coach, text: result))
                sending = false
            }
        }
    }

    private func bubble(_ m: CoachMessage) -> some View {
        HStack {
            if m.role == .user { Spacer(minLength: 40) }
            Text(m.text)
                .font(.system(size: 14))
                .foregroundColor(m.role == .user ? .black : .white.opacity(0.85))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(m.role == .user ? Color(hex: "#00FF7F") : Color(hex: "#2A2A2E"))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
            if m.role == .coach { Spacer(minLength: 40) }
        }
        .id(m.id)
    }
}

// MARK: - Home entry card (sits where Training Zones was)

struct CoachHomeCard: View {
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                Text("COACH")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text("Tell me what you are feeling and I will point you to the right drills.")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack {
                    Text("Ask your coach")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                    Spacer()
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(Color(hex: "#00FF7F"))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .homeRaisedSurface(fill: Color(hex: "#33393E"), cornerRadius: 18, shadowRadius: 6, x: 3, y: 4, lightOpacity: 0.04, darkOpacity: 0.34)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .homeRaisedSurface(fill: Color(hex: "#33393E"), cornerRadius: 20)
        }
        .buttonStyle(.plain)
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
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Text("Max \(zones.maxHeartRate) bpm")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))
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
        .background(Color(hex: "#2A2A2E"))
        .cornerRadius(20)
        .shadow(color: Color.black.opacity(0.25), radius: 10, x: 0, y: 6)
    }

    private func zoneBar(name: String, bpm: String, percent: CGFloat, color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06))
                RoundedRectangle(cornerRadius: 6).fill(color)
                    .frame(width: geo.size.width * percent)
                HStack(spacing: 6) {
                    Text(name).font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                    Text(bpm).font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.9))
                }
                .padding(.leading, 8)
            }
        }
    }
}

// MARK: - Coach tab (green) — coaching home: today's focus + drills + chat

struct CoachTabView: View {
    private let green = Color(hex: "#00FF7F")
    @ObservedObject private var subs = SubscriptionManager.shared
    @State private var showPaywall = false

    var body: some View {
        ZStack {
            Color(hex: "#1A1A1C").ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("COACH")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(.top, 20)

                    CoachChatView(
                        embedded: true,
                        isLocked: !subs.isPremium,
                        onLockedTap: { showPaywall = true }
                    )
                    .frame(minHeight: 455)

                    // TODAY — top focus from the latest analysis
                    let insights = Array(FormGaitCrossReference.storedInsights().prefix(3))
                    if !insights.isEmpty {
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
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }

    private var emptyToday: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TODAY")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            Text("Analyze a run on the Analyze tab and your focus list shows up here.")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#2A2A2E"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .foregroundColor(.white)
        .padding(.top, 4)
    }

    private func focusCard(_ insight: CombinedInsight) -> some View {
        let color = Color(hex: insight.corroboration.hex)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(insight.corroboration.label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(color.opacity(0.14)))
                    .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
                Text(insight.title).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                Spacer(minLength: 0)
            }
            Text(insight.detail).font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#2A2A2E"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(color.opacity(0.14)))
                    .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
                Spacer(minLength: 0)
            }
            Text(drill.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)
            Text(drill.how)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            Text(drill.dose.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .padding(.top, 1)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#2A2A2E"))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}
