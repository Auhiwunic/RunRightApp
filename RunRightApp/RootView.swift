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
            } else {
                // Brief loading state while anonymous sign-in bootstraps
                // (only seen on very first install with no cached session)
                VStack(spacing: 16) {
                    Image(systemName: "figure.run.circle.fill")
                        .font(AppTheme.body(56))
                        .foregroundColor(AppTheme.primaryText)

                    ProgressView()
                        .tint(AppTheme.primaryText)
                        .scaleEffect(1.2)

                    if let error = auth.errorMessage {
                        Text(error)
                            .font(AppTheme.bodyMedium(13))
                            .foregroundColor(AppTheme.primaryText.opacity(0.75))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                            .padding(.top, 4)

                        // Anonymous sign-in needs the network; on a fresh install
                        // with no connection it fails and there is nothing to fall
                        // back to. Without this, the user is pinned on the spinner
                        // forever. Let them retry once they're back online.
                        Button("Try Again") {
                            Task { await auth.signInAnonymouslyIfNeeded() }
                        }
                        .font(AppTheme.bodySemibold(15))
                        .foregroundColor(.black)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(AppTheme.accentColor))
                        .padding(.top, 8)
                    } else {
                        Text("Getting ready…")
                            .font(AppTheme.bodyMedium(13))
                            .foregroundColor(AppTheme.primaryText.opacity(0.4))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }

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
        }
        .animation(.easeInOut(duration: 0.25), value: auth.isAuthenticated)
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
                // Sync Apple Health metrics + running workouts every time the app opens
                await HealthKitManager.shared.syncAll()
                maybeShowSyncPrompt()
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
            }
        }
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
            AnimatedBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Privacy")
                            .font(AppTheme.display(42))
                            .foregroundStyle(PlanTheme.textPrimary)
                        Text("check-in.")
                            .font(AppTheme.display(42))
                            .foregroundStyle(accent)
                    }
                    .padding(.top, 48)

                    Text("Confirm these once so Gaita can keep using health, location, and video features for your training.")
                        .font(AppTheme.body(17))
                        .foregroundStyle(PlanTheme.textSecondary)
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
                            .font(.footnote.weight(.semibold))
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
        .preferredColorScheme(.dark)
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
            .foregroundStyle(PlanTheme.textPrimary)

            HStack(spacing: 10) {
                ForEach(AgeGateRegion.allCases) { option in
                    let selected = region == option
                    Button { region = option } label: {
                        Text(option.displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selected ? .black : PlanTheme.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(selected ? accent : PlanTheme.barUnselected)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if !isOldEnough {
                Text("Gaita is not available for this age in your selected region.")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(hex: "#FF453A"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: PlanTheme.cardRadius).fill(PlanTheme.card))
    }

    private func consentRow(title: String, text: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(AppTheme.bodySemibold(17))
                    .foregroundStyle(PlanTheme.textPrimary)
                Text(text)
                    .font(AppTheme.body(13))
                    .foregroundStyle(PlanTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(SwitchToggleStyle(tint: accent))
        .padding(18)
        .background(RoundedRectangle(cornerRadius: PlanTheme.cardRadius).fill(PlanTheme.card))
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
            do {
                if let uid = Auth.auth().currentUser?.uid {
                    var settings = (try? await UserSettingsRepository.shared.load(uid: uid)) ?? UserSettings()
                    settings.consentRecord = record
                    try await UserSettingsRepository.shared.save(uid: uid, settings: settings)
                }
                ConsentManager.shared.save(record)

                await MainActor.run {
                    isSaving = false
                    onComplete()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = "Couldn't save consent. Please check your connection and try again."
                }
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
                    .font(.system(size: 56))
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
