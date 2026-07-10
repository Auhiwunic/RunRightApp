//
//  OnboardingFlowView.swift
//  Weekly Plan
//

import SwiftUI

struct OnboardingFlowView: View {
    let onComplete: (OnboardingProfile) -> Void

    @State private var currentStep = 0
    @State private var name: String = ""
    @State private var dateOfBirth: Date = Calendar.current.date(byAdding: .year, value: -18, to: Date()) ?? Date()
    @State private var ageGateRegion: AgeGateRegion = .other
    @State private var runningGoal: RunningGoal?
    @State private var experienceLevel: ExperienceLevel?
    @State private var selectedDays: Set<Int> = []
    @State private var weeklyMileage: WeeklyMileageRange?
    @State private var age: Double = 30
    @State private var sex: String = "male"
    @State private var consents = ConsentChecklist()

    private let totalQuestionSteps = 8

    /// Every step's accent is the signature blue (no rainbow zone cycle), so the
    /// whole intro matches the rest of the app.
    private var currentAccent: Color { PlanTheme.accent }

    /// Kept for the progress dots — also the signature blue now.
    private func zoneAccent(for step: Int) -> Color { PlanTheme.accent }

    var body: some View {
        ZStack {
            AnimatedBackground()

            VStack(spacing: 0) {
                if currentStep > 0 {
                    dotStepper
                }

                Group {
                    switch currentStep {
                    case 0:
                        WelcomeView(onGetStarted: { advance() })
                    case 1:
                        ageGateStep
                    case 2:
                        nameStep
                    case 3:
                        runningGoalStep
                    case 4:
                        experienceStep
                    case 5:
                        availableDaysStep
                    case 6:
                        weeklyMileageStep
                    case 7:
                        heartRateStep
                    case 8:
                        consentStep
                    default:
                        EmptyView()
                    }
                }
                .animation(.easeInOut, value: currentStep)
                .environment(\.planAccent, currentAccent)

                if currentStep > 0 {
                    navigationButtons
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var dotStepper: some View {
        HStack(spacing: 8) {
            ForEach(1...totalQuestionSteps, id: \.self) { step in
                Circle()
                    .fill(step <= currentStep ? zoneAccent(for: step) : PlanTheme.barUnselected)
                    .frame(width: step == currentStep ? 10 : 7, height: step == currentStep ? 10 : 7)
                    .animation(.easeInOut(duration: 0.2), value: currentStep)
            }
        }
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    private var nameStep: some View {
        questionContainer(top: "What should", accent: "we call you?", scrollable: false) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Shown on your home screen.")
                    .font(AppTheme.body(15))
                    .foregroundStyle(PlanTheme.textSecondary)

                TextField("", text: $name, prompt: Text("Your name").foregroundStyle(PlanTheme.textSecondary))
                    .font(AppTheme.head(20))
                    .foregroundStyle(PlanTheme.textPrimary)
                    .tint(currentAccent)
                    .submitLabel(.done)
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: PlanTheme.cardRadius).fill(PlanTheme.card))
            }
        }
    }

    private var ageGateStep: some View {
        questionContainer(top: "Before we", accent: "get started.", scrollable: false) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Gaita is for runners old enough to consent to health, location, and video analysis.")
                    .font(AppTheme.body(15))
                    .foregroundStyle(PlanTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 14) {
                    Text("Date of birth")
                        .font(AppTheme.bodySemibold(15))
                        .foregroundStyle(PlanTheme.textPrimary)

                    DatePicker(
                        "",
                        selection: $dateOfBirth,
                        in: ...Date(),
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(currentAccent)
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: PlanTheme.cardRadius).fill(PlanTheme.card))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Region")
                        .font(AppTheme.bodySemibold(15))
                        .foregroundStyle(PlanTheme.textPrimary)

                    HStack(spacing: 10) {
                        ForEach(AgeGateRegion.allCases) { region in
                            let isOn = ageGateRegion == region
                            Button { ageGateRegion = region } label: {
                                Text(region.displayName)
                                    .font(AppTheme.bodySemibold(15))
                                    .foregroundStyle(isOn ? .black : PlanTheme.textSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(isOn ? currentAccent : PlanTheme.barUnselected)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: PlanTheme.cardRadius).fill(PlanTheme.card))

                if !meetsAgeGate {
                    Text("Gaita is not available for this age in your selected region.")
                        .font(AppTheme.bodySemibold(13))
                        .foregroundStyle(Color(hex: "#FF453A"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var runningGoalStep: some View {
        questionContainer(top: "Why do you", accent: "run?") {
            GoalGrid(selection: $runningGoal)
        }
    }

    private var experienceStep: some View {
        questionContainer(top: "How much", accent: "have you run?", scrollable: false) {
            ExperienceTierPicker(selection: $experienceLevel)
        }
    }

    private var availableDaysStep: some View {
        questionContainer(top: "Which days", accent: "work for you?") {
            WeekdayBarSelector(selectedDays: $selectedDays)

            if let goal = runningGoal, let experience = experienceLevel, !selectedDays.isEmpty {
                MandateWarningView(
                    mandates: PlanMandateChecker.inlineWarningsForDays(
                        goal: goal,
                        experience: experience,
                        dayCount: selectedDays.count
                    )
                )
                .animation(.easeInOut(duration: 0.25), value: selectedDays.count)
            }
        }
    }

    private var weeklyMileageStep: some View {
        questionContainer(top: "Your weekly", accent: "mileage.") {
            MileagePicker(selection: $weeklyMileage)

            if let goal = runningGoal, let experience = experienceLevel, let mileage = weeklyMileage {
                MandateWarningView(
                    mandates: PlanMandateChecker.inlineWarningsForMileage(
                        goal: goal,
                        experience: experience,
                        mileage: mileage
                    )
                )
                .animation(.easeInOut(duration: 0.25), value: mileage)
            }
        }
    }

    private var heartRateStep: some View {
        questionContainer(top: "Personalise your", accent: "heart-rate zones.") {
            VStack(alignment: .leading, spacing: 24) {
                Text("Used to calculate your training zones. You can change this later in Profile.")
                    .font(AppTheme.body(15))
                    .foregroundStyle(PlanTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Age
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Age")
                            .font(AppTheme.bodySemibold(15))
                            .foregroundStyle(PlanTheme.textPrimary)
                        Spacer()
                        Text("\(Int(age))")
                            .font(AppTheme.headBold(20))
                            .foregroundStyle(PlanTheme.textPrimary)   // all intro text white; accent stays for controls
                    }
                    Slider(value: $age, in: 15...80, step: 1)
                        .tint(currentAccent)
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: PlanTheme.cardRadius).fill(PlanTheme.card))

                // Sex
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sex")
                        .font(AppTheme.bodySemibold(15))
                        .foregroundStyle(PlanTheme.textPrimary)
                    HStack(spacing: 10) {
                        ForEach(["male", "female", "other"], id: \.self) { option in
                            let isOn = sex == option
                            Button { sex = option } label: {
                                Text(option.capitalized)
                                    .font(AppTheme.bodySemibold(15))
                                    .foregroundStyle(isOn ? .black : PlanTheme.textSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(isOn ? currentAccent : PlanTheme.barUnselected)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: PlanTheme.cardRadius).fill(PlanTheme.card))
            }
        }
    }

    private var consentStep: some View {
        questionContainer(top: "Your data,", accent: "your call.") {
            VStack(alignment: .leading, spacing: 16) {
                consentToggle(
                    title: "Health data",
                    text: "Use HealthKit activity and running-workout data for Gaita stats and training views.",
                    isOn: $consents.healthData
                )

                consentToggle(
                    title: "Background location",
                    text: "Record GPS route, distance, and pace while an active run continues with the screen locked.",
                    isOn: $consents.backgroundLocation
                )

                consentToggle(
                    title: "Running video",
                    text: "Analyze videos you choose on this device for running-form feedback. Run-video frames are not uploaded.",
                    isOn: $consents.runningVideo
                )
            }
        }
    }

    private func consentToggle(title: String, text: String, isOn: Binding<Bool>) -> some View {
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
        .toggleStyle(SwitchToggleStyle(tint: currentAccent))
        .padding(18)
        .background(RoundedRectangle(cornerRadius: PlanTheme.cardRadius).fill(PlanTheme.card))
    }

    private var navigationButtons: some View {
        HStack {
            Button("Back") {
                goBack()
            }
            .font(AppTheme.bodyMedium(15))
            .foregroundStyle(PlanTheme.textSecondary)

            Spacer()

            Button(currentStep == totalQuestionSteps ? "Finish" : "Next") {
                if currentStep == totalQuestionSteps {
                    completeOnboarding()
                } else {
                    advance()
                }
            }
            .font(AppTheme.bodySemibold(17))
            .padding(.horizontal, 32)
            .padding(.vertical, 14)
            .background(canAdvance ? currentAccent : currentAccent.opacity(0.35))
            .foregroundStyle(.black)
            .clipShape(Capsule())
            .disabled(!canAdvance)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
    }

    private var canAdvance: Bool {
        switch currentStep {
        case 1: meetsAgeGate
        case 2: !name.trimmingCharacters(in: .whitespaces).isEmpty
        case 3: runningGoal != nil
        case 4: experienceLevel != nil
        case 5: !selectedDays.isEmpty
        case 6: weeklyMileage != nil
        // Step 8 consents are optional opt-ins ("your call") — any combination,
        // including none, is a valid choice, so Finish is always available here.
        case 8: true
        default: true
        }
    }

    private var meetsAgeGate: Bool {
        ConsentManager.age(on: dateOfBirth) >= ageGateRegion.minimumAge
    }

    private func questionContainer<Content: View>(
        top: String,
        accent: String,
        scrollable: Bool = true,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Group {
            if scrollable {
                ScrollView {
                    questionContent(top: top, accent: accent, content: content)
                }
            } else {
                questionContent(top: top, accent: accent, content: content)
            }
        }
    }

    private func questionContent<Content: View>(
        top: String,
        accent: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            stepHeader(top, accent)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    private func stepHeader(_ top: String, _ accent: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(top)
                .font(AppTheme.display(34))
                .foregroundStyle(PlanTheme.textPrimary)

            Text(accent)
                .font(AppTheme.display(34))
                .foregroundStyle(PlanTheme.textPrimary)   // all intro text white; accent stays for controls
        }
    }

    private func advance() {
        withAnimation {
            currentStep += 1
        }
    }

    private func goBack() {
        withAnimation {
            currentStep -= 1
        }
    }

    private func completeOnboarding() {
        guard
            let runningGoal,
            let experienceLevel,
            let weeklyMileage
        else { return }

        onComplete(
            OnboardingProfile(
                runningGoal: runningGoal,
                experienceLevel: experienceLevel,
                availableDays: selectedDays,
                weeklyMileage: weeklyMileage,
                name: name.trimmingCharacters(in: .whitespaces),
                age: Int(age),
                sex: sex,
                consentRecord: ConsentRecord(
                    healthDataConsentAt: consents.healthData ? Date() : nil,
                    backgroundLocationConsentAt: consents.backgroundLocation ? Date() : nil,
                    runningVideoConsentAt: consents.runningVideo ? Date() : nil,
                    ageGateConfirmedAt: Date(),
                    dateOfBirth: dateOfBirth,
                    region: ageGateRegion
                )
            )
        )
    }

}

private struct ConsentChecklist {
    var healthData = false
    var backgroundLocation = false
    var runningVideo = false
}

#Preview {
    OnboardingFlowView(onComplete: { _ in })
        .background(PlanTheme.background)
        .preferredColorScheme(.dark)
}
