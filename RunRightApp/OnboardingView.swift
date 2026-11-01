//
//  OnboardingView.swift
//  RunRightApp
//
//  First-launch introduction: the Weekly Plan onboarding (goal → experience →
//  training days → weekly mileage → heart-rate setup) which then generates the
//  user's weekly training plan. Heart-rate answers feed the HR zone manager.
//

import SwiftUI
import FirebaseAuth

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var completedProfile: OnboardingProfile?
    @State private var showingSignIn = false

    var body: some View {
        Group {
            if let profile = completedProfile {
                if showingSignIn {
                    // One-time sign-in offer at the end of onboarding. Skipping keeps
                    // the user anonymous; the regular Profile sign-in path covers them
                    // afterwards.
                    OnboardingSignInView(onDone: { finish(profile) })
                } else {
                    WeeklyPlanView(
                        profile: profile,
                        onRestart: { completedProfile = nil; showingSignIn = false },
                        onDone: { showingSignIn = true }
                    )
                }
            } else {
                OnboardingFlowView(onComplete: { completedProfile = $0 })
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Completion

    private func finish(_ profile: OnboardingProfile) {
        persist(profile)
        isPresented = false
    }

    /// Map the onboarding answers onto the app's UserSettings (HR zones + weekly
    /// goal) and persist. Fitness level is derived from the experience answer so
    /// we don't ask the user two near-identical questions.
    private func persist(_ profile: OnboardingProfile) {
        let fitnessLevel: String = {
            switch profile.experienceLevel {
            case .beginner:       return "beginner"
            case .someExperience: return "intermediate"
            case .regularRunner:  return "advanced"
            case .competitive:    return "elite"
            }
        }()

        let weeklyGoal: Double = {
            switch profile.weeklyMileage {
            case .zeroToFive:          return 5
            case .fiveToFifteen:       return 12
            case .fifteenToTwentyFive: return 20
            case .twentyFivePlus:      return 30
            }
        }()

        let trimmedName = profile.name.trimmingCharacters(in: .whitespaces)

        let settings = UserSettings(
            displayName: trimmedName,
            dailyGoalMiles: 3.0,
            weeklyGoalMiles: weeklyGoal,
            hasCompletedOnboarding: true,
            age: profile.age,
            sex: profile.sex,
            fitnessLevel: fitnessLevel,
            consentRecord: profile.consentRecord
        )

        ConsentManager.shared.save(profile.consentRecord)

        // Apply HR zones immediately so they're live without a restart.
        settings.applyToHRZoneManager()

        // Mirror the name onto the Firebase user so the home greeting picks it up.
        if !trimmedName.isEmpty {
            let change = Auth.auth().currentUser?.createProfileChangeRequest()
            change?.displayName = trimmedName
            change?.commitChanges(completion: nil)
        }

        if let uid = Auth.auth().currentUser?.uid {
            Task { try? await UserSettingsRepository.shared.save(uid: uid, settings: settings) }
        }

        // Generate this week's plan from the profile and save it, so the Run tab
        // reflects the answers immediately (first onboarding AND coach-triggered
        // profile rebuilds both land here). Notify so any open plan view reloads.
        if let uid = Auth.auth().currentUser?.uid {
            let days = CoachPlanActions.dayPlans(from: WeeklyPlanGenerator.generate(from: profile))
            let weekId = PlanRepository.shared.weekId(for: Date())
            Task {
                try? await PlanRepository.shared.saveWeeklyPlan(uid: uid, weekId: weekId, days: days)
                await MainActor.run { NotificationCenter.default.post(name: .planUpdated, object: nil) }
            }
        }
    }
}

// MARK: - One-time onboarding sign-in slide

/// Final onboarding slide offering sign-in (Google or email) over the same
/// animated zone background as the intro. Skipping keeps the user anonymous.
/// Shown only during first-launch onboarding.
struct OnboardingSignInView: View {
    @ObservedObject private var auth = FirebaseAuthManager.shared
    let onDone: () -> Void

    @State private var showEmailSheet = false
    @State private var isLoading = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            AnimatedBackground()

            VStack(alignment: .leading, spacing: 0) {
                Spacer()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Save your")
                        .font(AppTheme.display(44))
                        .foregroundStyle(PlanTheme.textPrimary)
                    Text("progress.")
                        .font(AppTheme.display(44))
                        .foregroundStyle(PlanTheme.textPrimary)
                }

                Text("Sign in to back up your runs, scans, and plan, then pick up on any device. You can always do this later.")
                    .font(AppTheme.body(17))
                    .foregroundStyle(PlanTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 20)

                Spacer()

                VStack(spacing: 12) {
                    Button(action: googleSignIn) {
                        ZStack {
                            if isLoading {
                                ProgressView().tint(.black)
                            } else {
                                Text("Continue with Google")
                                    .font(AppTheme.bodySemibold(17))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.white)
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                    }
                    .disabled(isLoading)

                    Button(action: appleSignIn) {
                        Text("Continue with Apple")
                            .font(AppTheme.bodySemibold(17))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.black)
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(AppTheme.primaryText.opacity(0.18), lineWidth: 1)
                            )
                    }
                    .disabled(isLoading)

                    Button(action: { showEmailSheet = true }) {
                        Text("Sign up with email")
                            .font(AppTheme.bodySemibold(17))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(PlanTheme.card)
                            .foregroundStyle(PlanTheme.textPrimary)
                            .clipShape(Capsule())
                            .overlay(
                                Capsule().stroke(AppTheme.primaryText.opacity(0.15), lineWidth: 1)
                            )
                    }
                    .disabled(isLoading)

                    Button(action: onDone) {
                        Text("Maybe later")
                            .font(AppTheme.bodyMedium(15))
                            .foregroundStyle(PlanTheme.textSecondary)
                            .padding(.vertical, 8)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showEmailSheet) {
            AuthSheet()
                .environmentObject(auth)
                .presentationDragIndicator(.visible)
        }
        // Signing in converts the anonymous user to a real one — when that happens
        // (via Google or the email sheet), move on automatically.
        .onChange(of: auth.isAnonymous) { _, anonymous in
            if !anonymous { onDone() }
        }
    }

    private func googleSignIn() {
        isLoading = true
        Task {
            await auth.signInWithGoogle()
            isLoading = false
            if auth.isAuthenticated && !auth.isAnonymous { onDone() }
        }
    }

    private func appleSignIn() {
        isLoading = true
        Task {
            await auth.signInWithApple()
            isLoading = false
            if auth.isAuthenticated && !auth.isAnonymous { onDone() }
        }
    }
}

#Preview {
    OnboardingView(isPresented: .constant(true))
}
