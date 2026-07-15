import SwiftUI
import FirebaseAuth

struct RootView: View {
    @StateObject private var auth = FirebaseAuthManager.shared
    @StateObject private var remoteConfig = RemoteConfigManager.shared
    @State private var showAuthSheet = false
    @State private var showOnboarding = false
    @State private var showConsentGate = false
    @State private var showSyncPrompt = false
    @AppStorage("hasSeenSyncPrompt") private var hasSeenSyncPrompt = false   // once dismissed, never shown again
    @AppStorage("hasCompletedWeeklyOnboarding") private var hasOnboarded = false
    @AppStorage("hasSeenAppTour") private var hasSeenTour = false
    @State private var showTour = false

    // Branded launch splash. Shows on every cold launch as a short brand beat
    // over the first-frame build, then fades once the app is ready. On an
    // offline first launch it stays and surfaces a retry (never an endless
    // spinner). Returning users are already authenticated, so it is just the
    // ~0.9s beat and adds no real wait.
    @State private var splashActive = true
    @State private var minSplashElapsed = false

    var body: some View {
        ZStack {
            // Always fill the window with the app background so there is never
            // a transparent/black flicker during auth state transitions.
            AppTheme.bgColor.ignoresSafeArea()

            if remoteConfig.needsForcedUpdate {
                // Backend kill-switch: this build is below the server-mandated
                // minimum (e.g. a broken endpoint or a required migration shipped).
                // Block the app until the user updates so old clients can't keep
                // hitting the broken backend.
                ForceUpdateView(message: remoteConfig.maintenanceMessage)
                    .transition(.opacity)
            } else if auth.isAuthenticated {
                MainTabView()
                    .transition(.opacity)
            }
            // While unauthenticated the splash overlay below covers the window,
            // so there is nothing to render here (bgColor already fills the base).

            // One-time, centered sign-in prompt for guests — shown once at the very
            // beginning; "Not now" (or tapping outside) closes it for good.
            if showSyncPrompt {
                SyncPromptCard(
                    onSignIn: {
                        hasSeenSyncPrompt = true
                        withAnimation(.easeInOut(duration: 0.2)) { showSyncPrompt = false }
                        showAuthSheet = true
                    },
                    onClose: {
                        hasSeenSyncPrompt = true
                        withAnimation(.easeInOut(duration: 0.2)) { showSyncPrompt = false }
                    }
                )
                .transition(.opacity)
                .zIndex(10)
            }

            // Branded launch splash — on top of everything until the app is ready.
            if splashActive {
                BrandedSplashScreen(
                    errorMessage: auth.errorMessage,
                    onRetry: auth.errorMessage == nil ? nil : {
                        Task { await auth.signInAnonymouslyIfNeeded() }
                    }
                )
                .transition(.opacity)
                .zIndex(50)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: auth.isAuthenticated)
        .animation(.easeOut(duration: 0.4), value: splashActive)
        .task {
            // Minimum brand beat so the splash reads as intentional, not a flash.
            try? await Task.sleep(nanoseconds: 900_000_000)
            minSplashElapsed = true
            dismissSplashIfReady()
        }
        .onChange(of: auth.isAuthenticated) { _, _ in dismissSplashIfReady() }
        .task {
            await auth.signInAnonymouslyIfNeeded()
            if !hasOnboarded {
                // First launch: run the Weekly Plan onboarding before anything else.
                showOnboarding = true
            } else if ConsentManager.shared.currentRecord == nil {
                // Existing users from pre-consent builds must explicitly confirm
                // consent before HealthKit sync, background GPS, or video analysis.
                showConsentGate = true
            } else {
                // Show the guest sync prompt immediately; the Health sync (4 HK
                // queries + a 60-day workout sync) runs concurrently in its own
                // Task so it never delays the first interactive moment.
                maybeShowSyncPrompt()
                Task { await HealthKitManager.shared.syncAll() }
            }
        }
        .sheet(isPresented: $showAuthSheet) {
            AuthSheet()
                .environmentObject(auth)
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
        }
        .fullScreenCover(isPresented: $showConsentGate) {
            ConsentGateView {
                showConsentGate = false
                Task {
                    await HealthKitManager.shared.syncAll()
                    maybeShowSyncPrompt()
                }
            }
            .interactiveDismissDisabled(true)
        }
        .onChange(of: showOnboarding) { _, shown in
            // When onboarding finishes, mark it complete and run the Health sync we deferred.
            if !shown && !hasOnboarded {
                hasOnboarded = true
                // Onboarding already offered sign-in on its final slide, so don't
                // immediately nag again with the sync card. Returning guests get the
                // regular sign-in path from the Profile tab.
                hasSeenSyncPrompt = true
                Task { await HealthKitManager.shared.syncAll() }
                // New users get the short how-to tour next (always skippable).
                if !hasSeenTour { showTour = true }
            }
        }
        .fullScreenCover(isPresented: $showTour) {
            AppTourView {
                hasSeenTour = true
                showTour = false
            }
        }
    }

    /// Fade the launch splash once the minimum brand beat has elapsed AND the
    /// app is authenticated (so we never reveal a half-built, signed-out state).
    /// If sign-in never completes (offline first launch) the splash stays and
    /// shows its retry, which is the correct behavior.
    private func dismissSplashIfReady() {
        guard minSplashElapsed, auth.isAuthenticated, splashActive else { return }
        splashActive = false
    }

    /// Show the centered sync prompt once, for guests who haven't dismissed it.
    private func maybeShowSyncPrompt() {
        guard auth.isAnonymous, !hasSeenSyncPrompt, !showOnboarding else { return }
        withAnimation(.easeInOut(duration: 0.3)) { showSyncPrompt = true }
    }
}

// MARK: - Existing User Consent Gate

private struct ConsentGateView: View {
    let onComplete: () -> Void

    @State private var dateOfBirth = Calendar.current.date(byAdding: .year, value: -18, to: Date()) ?? Date()
    @State private var region: AgeGateRegion = .other
    @State private var healthData = false
    @State private var backgroundLocation = false
    @State private var runningVideo = false
    @State private var isSaving = false
    @State private var saveError: String?

    private var accent: Color { AppTheme.accentColor }
    private var isOldEnough: Bool {
        ConsentManager.age(on: dateOfBirth) >= region.minimumAge
    }
    private var canContinue: Bool {
        // Only the age gate is mandatory; the three feature consents are optional.
        isOldEnough && !isSaving
    }

    var body: some View {
        ZStack {
            // Theme aware: this gate appears over whatever theme the user chose,
            // so it uses AppTheme tokens — a fixed-dark takeover on a light theme
            // read as broken.
            AppTheme.bgColor.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Privacy")
                            .font(AppTheme.display(42))
                            .foregroundStyle(AppTheme.primaryText)
                        Text("check-in.")
                            .font(AppTheme.display(42))
                            .foregroundStyle(accent)
                    }
                    .padding(.top, 48)

                    Text("Confirm these once so Gaita can keep using health, location, and video features for your training.")
                        .font(AppTheme.body(17))
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    ageSection

                    consentRow(
                        title: "Health data",
                        text: "Use HealthKit activity and running-workout data for Gaita stats and training views.",
                        isOn: $healthData
                    )
                    consentRow(
                        title: "Background location",
                        text: "Record route, distance, and pace while an active run continues with the screen locked.",
                        isOn: $backgroundLocation
                    )
                    consentRow(
                        title: "Running video",
                        text: "Analyze videos you choose on this device for running-form feedback. Run-video frames are not uploaded.",
                        isOn: $runningVideo
                    )

                    if let saveError {
                        Text(saveError)
                            .font(AppTheme.bodySemibold(13))
                            .foregroundStyle(Color(hex: "#FF453A"))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button(action: saveConsent) {
                        ZStack {
                            if isSaving {
                                ProgressView().tint(.black)
                            } else {
                                Text("Continue")
                                    .font(AppTheme.bodySemibold(17))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(canContinue ? accent : accent.opacity(0.35))
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                    }
                    .disabled(!canContinue)
                    .padding(.bottom, 36)
                }
                .padding(.horizontal, 28)
            }
        }
    }

    private var ageSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            DatePicker(
                "Date of birth",
                selection: $dateOfBirth,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .tint(accent)
            .foregroundStyle(AppTheme.primaryText)

            HStack(spacing: 10) {
                ForEach(AgeGateRegion.allCases) { option in
                    let selected = region == option
                    Button { region = option } label: {
                        Text(option.displayName)
                            .font(AppTheme.bodySemibold(15))
                            .foregroundStyle(selected ? .black : AppTheme.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(selected ? accent : AppTheme.insetFill)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if !isOldEnough {
                Text("Gaita is not available for this age in your selected region.")
                    .font(AppTheme.bodySemibold(13))
                    .foregroundStyle(Color(hex: "#FF453A"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: PlanTheme.cardRadius).fill(AppTheme.cardBg))
    }

    private func consentRow(title: String, text: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(AppTheme.bodySemibold(17))
                    .foregroundStyle(AppTheme.primaryText)
                Text(text)
                    .font(AppTheme.body(13))
                    .foregroundStyle(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: accent))
        .padding(18)
        .background(RoundedRectangle(cornerRadius: PlanTheme.cardRadius).fill(AppTheme.cardBg))
    }

    private func saveConsent() {
        guard canContinue else { return }
        isSaving = true
        saveError = nil

        let now = Date()
        let record = ConsentRecord(
            healthDataConsentAt: healthData ? now : nil,
            backgroundLocationConsentAt: backgroundLocation ? now : nil,
            runningVideoConsentAt: runningVideo ? now : nil,
            ageGateConfirmedAt: now,
            dateOfBirth: dateOfBirth,
            region: region
        )

        Task {
            if let uid = Auth.auth().currentUser?.uid {
                // Read-modify-write, but ONLY when the real profile actually
                // loaded. A failed/offline load used to fall back to a blank
                // UserSettings() and save THAT — overwriting the user's real
                // cloud profile (name, goals, HR) with defaults once it synced.
                // So skip the cloud write on load failure; the next successful
                // settings save carries consent up. Consent is authoritative
                // locally either way (below).
                if var settings = try? await UserSettingsRepository.shared.load(uid: uid) {
                    settings.consentRecord = record
                    try? await UserSettingsRepository.shared.save(uid: uid, settings: settings)
                }
            }
            // Local save always succeeds, so the gate can never hang — even fully
            // offline the user can confirm consent and continue; the cloud mirror
            // catches up on reconnect.
            ConsentManager.shared.save(record)
            await MainActor.run {
                isSaving = false
                onComplete()
            }
        }
    }
}

// MARK: - Sync Prompt (one-time centered card for guests)

private struct SyncPromptCard: View {
    let onSignIn: () -> Void
    let onClose: () -> Void
    private var lime: Color { AppTheme.accentColor }   // sync accent — orange

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 18) {
                Image(systemName: "icloud.and.arrow.up")
                    .font(AppTheme.bodySemibold(40))
                    .foregroundColor(lime)

                VStack(spacing: 8) {
                    Text("Sync across devices")
                        .font(AppTheme.head(20))
                        .foregroundColor(AppTheme.primaryText)
                    Text("Sign in to back up your runs and scans and pick up on any device. You can always do this later in Profile.")
                        .font(AppTheme.body(13))
                        .foregroundColor(AppTheme.primaryText.opacity(0.5))
                        .multilineTextAlignment(.center)
                }

                Button(action: onSignIn) {
                    Text("Sign in")
                        .font(AppTheme.head(15))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(lime)
                        .cornerRadius(14)
                }
                .buttonStyle(.plain)

                Button(action: onClose) {
                    Text("Not now")
                        .font(AppTheme.bodyMedium(14))
                        .foregroundColor(AppTheme.primaryText.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(AppTheme.cardBg)
            )
            .padding(.horizontal, 36)
        }
    }
}

// MARK: - Auth Sheet (Google + Email/Password)

struct AuthSheet: View {
    @EnvironmentObject private var auth: FirebaseAuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @State private var isLoading = false
    @State private var resetEmailSent = false
    @State private var showForgotPassword = false
    @State private var resetEmail = ""

    private var lime: Color { AppTheme.accentColor }
    private var bg: Color { AppTheme.bgColor }
    private var card: Color { AppTheme.cardBg }

    var body: some View {
        ZStack {
            bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {

                    // Header
                    Text(isSignUp ? "Create Account" : "Sign In")
                        .font(AppTheme.display(26))
                        .foregroundColor(AppTheme.primaryText)
                        .padding(.top, 32)

                    // Error message
                    if let error = auth.errorMessage {
                        Text(error)
                            .font(AppTheme.bodyMedium(12))
                            .foregroundColor(Color(hex: "#FF6B6B"))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 4)
                    }

                    // Google Sign In button
                    Button(action: {
                        isLoading = true
                        Task {
                            await auth.signInWithGoogle()
                            isLoading = false
                            if auth.isAuthenticated && !auth.isAnonymous { dismiss() }
                        }
                    }) {
                        Text("Continue with Google")
                            .font(AppTheme.bodySemibold(15))
                            .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Color.white)
                        .overlay(
                            // Outline so the white pill doesn't wash into the
                            // light-mode sheet (the Apple button already has one).
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(AppTheme.subtleBorder, lineWidth: 1)
                        )
                        .cornerRadius(14)
                    }
                    .disabled(isLoading)

                    Button(action: {
                        isLoading = true
                        Task {
                            await auth.signInWithApple()
                            isLoading = false
                            if auth.isAuthenticated && !auth.isAnonymous { dismiss() }
                        }
                    }) {
                        Text("Continue with Apple")
                            .font(AppTheme.bodySemibold(15))
                            .foregroundColor(.white)   // always-black Apple button
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(Color.black)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                            )
                            .cornerRadius(14)
                    }
                    .disabled(isLoading)

                    // Divider
                    HStack(spacing: 10) {
                        Rectangle().fill(AppTheme.primaryText.opacity(0.12)).frame(height: 1)
                        Text("or").font(AppTheme.body(12)).foregroundColor(AppTheme.primaryText.opacity(0.3))
                        Rectangle().fill(AppTheme.primaryText.opacity(0.12)).frame(height: 1)
                    }

                    // Email / Password fields
                    VStack(spacing: 12) {
                        TextField("", text: $email, prompt: Text("Email").foregroundColor(AppTheme.primaryText.opacity(0.3)))
                            .keyboardType(.emailAddress)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .foregroundColor(AppTheme.primaryText)
                            .padding(.horizontal, 14)
                            .frame(height: 50)
                            .background(card)
                            .cornerRadius(12)

                        SecureField("", text: $password, prompt: Text("Password").foregroundColor(AppTheme.primaryText.opacity(0.3)))
                            .foregroundColor(AppTheme.primaryText)
                            .padding(.horizontal, 14)
                            .frame(height: 50)
                            .background(card)
                            .cornerRadius(12)
                    }

                    // Forgot password (sign in mode only)
                    if !isSignUp {
                        HStack {
                            Spacer()
                            Button("Forgot password?") {
                                resetEmail = email
                                showForgotPassword = true
                            }
                            .font(AppTheme.bodyMedium(12))
                            .foregroundColor(lime.opacity(0.8))
                        }
                    }

                    // Submit button
                    Button(action: {
                        guard !email.isEmpty, !password.isEmpty else {
                            auth.errorMessage = "Please enter your email and password."
                            return
                        }
                        isLoading = true
                        Task {
                            if isSignUp {
                                await auth.createAccount(email: email, password: password)
                            } else {
                                await auth.signInWithEmail(email: email, password: password)
                            }
                            isLoading = false
                            if auth.isAuthenticated && !auth.isAnonymous { dismiss() }
                        }
                    }) {
                        ZStack {
                            if isLoading {
                                ProgressView().tint(.black)
                            } else {
                                Text(isSignUp ? "Create Account" : "Sign In")
                                    .font(AppTheme.head(15))
                                    .foregroundColor(.black)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(lime)
                        .cornerRadius(14)
                    }
                    .disabled(isLoading)

                    // Toggle sign in / create account
                    Button(action: {
                        isSignUp.toggle()
                        auth.errorMessage = nil
                    }) {
                        HStack(spacing: 4) {
                            Text(isSignUp ? "Already have an account?" : "Don't have an account?")
                                .foregroundColor(AppTheme.primaryText.opacity(0.4))
                            Text(isSignUp ? "Sign In" : "Create one")
                                .foregroundColor(lime)
                        }
                        .font(AppTheme.bodyMedium(13))
                    }
                    .padding(.bottom, 32)
                }
                .padding(.horizontal, 24)
            }
        }
        .alert("Reset Password", isPresented: $showForgotPassword) {
            TextField("Email", text: $resetEmail)
                .autocapitalization(.none)
            Button("Send Reset Email") {
                Task {
                    await auth.sendPasswordReset(email: resetEmail)
                    resetEmailSent = true
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We'll send a password reset link to your email.")
        }
        .alert("Email Sent", isPresented: $resetEmailSent) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your inbox for the password reset link.")
        }
    }
}

// MARK: - Force Update (Remote Config kill-switch: min_supported_build)

/// Full-screen block shown when this build is below the server-mandated minimum.
/// This is what makes the `min_supported_build` Remote Config value actually do
/// something — without it the value was fetched but never consumed.
private struct ForceUpdateView: View {
    /// Optional server-provided text (Remote Config `maintenance_message`).
    let message: String

    @Environment(\.openURL) private var openURL

    // Opens the App Store. TODO: replace with the direct product link
    // ("itms-apps://apps.apple.com/app/id<APP_ID>") once Gaita is published.
    private static let appStoreURL = URL(string: "itms-apps://apps.apple.com/search?term=Gaita")!

    var body: some View {
        ZStack {
            AppTheme.bgColor.ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(AppTheme.display(56))
                    .foregroundColor(AppTheme.accentColor)

                Text("Update Gaita")
                    .font(AppTheme.display(30))
                    .foregroundColor(AppTheme.primaryText)

                Text(message.isEmpty
                     ? "A newer version of Gaita is required to keep going. Please update from the App Store to continue."
                     : message)
                    .font(AppTheme.body(15))
                    .foregroundColor(AppTheme.primaryText.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 32)

                Button("Update Now") {
                    openURL(Self.appStoreURL)
                }
                .font(AppTheme.bodySemibold(17))
                .foregroundColor(.black)
                .padding(.horizontal, 40)
                .padding(.vertical, 14)
                .background(Capsule().fill(AppTheme.accentColor))
                .padding(.top, 8)
            }
            .padding()
        }
    }
}
