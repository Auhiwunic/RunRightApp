//
//  TrainingZonesOnboarding.swift
//  RunRightApp
//
//  Onboarding flow to collect user data for zone calculation
//

import SwiftUI

struct TrainingZonesOnboarding: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var zonesManager = HeartRateZonesManager.shared
    
    // Form state
    @State private var currentStep = 0
    @State private var age: String = ""
    @State private var sex: UserFitnessProfile.Sex = .male
    @State private var fitnessLevel: UserFitnessProfile.FitnessLevel = .intermediate
    @State private var restingHR: String = ""
    @State private var knownMaxHR: String = ""
    @State private var weight: String = ""
    
    // Validation
    @State private var showError = false
    @State private var errorMessage = ""
    
    private let totalSteps = 4
    
    var body: some View {
        ZStack {
            AppTheme.bgColor.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                header
                
                // Progress indicator
                progressIndicator
                    .padding(.top, 20)
                
                // Content
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 24) {
                        switch currentStep {
                        case 0:
                            welcomeStep
                        case 1:
                            basicInfoStep
                        case 2:
                            fitnessLevelStep
                        case 3:
                            optionalInfoStep
                        default:
                            resultsStep
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 32)
                    .padding(.bottom, 120)
                }
                
                // Navigation buttons
                navigationButtons
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
    }
    
    // MARK: - Header
    private var header: some View {
        ZStack {
            ZStack {
                RadialGradient(
                    colors: [Color(hex: "#1a1a1a"), .clear],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: 200
                )
            }
            .background(AppTheme.bgColor)
            
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                        .padding(8)
                }
                
                Text("Training Zones Setup")
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(height: 70)
    }
    
    // MARK: - Progress Indicator
    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalSteps, id: \.self) { step in
                Capsule()
                    .fill(step <= currentStep ? AppTheme.accentColor : Color.white.opacity(0.2))
                    .frame(height: 4)
            }
        }
        .padding(.horizontal, 20)
    }
    
    // MARK: - Welcome Step
    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 60))
                .foregroundColor(AppTheme.accentColor)
            
            VStack(spacing: 12) {
                Text("Calibrate Your Zones")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(.white)
                
                Text("Answer a few questions to personalize your heart rate training zones and get real-time voice coaching during runs.")
                    .font(.system(size: 15, weight: .light))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            
            VStack(alignment: .leading, spacing: 16) {
                benefitRow(icon: "waveform.path.ecg", text: "Accurate heart rate zones")
                benefitRow(icon: "speaker.wave.3.fill", text: "Voice announcements during runs")
                benefitRow(icon: "chart.line.uptrend.xyaxis", text: "VO2 Max estimation")
                benefitRow(icon: "figure.run", text: "Personalized training guidance")
            }
            .padding(.top, 16)
        }
    }
    
    private func benefitRow(icon: String, text: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(AppTheme.accentColor)
                .frame(width: 30)
            
            Text(text)
                .font(.system(size: 15, weight: .light))
                .foregroundColor(.white.opacity(0.8))
            
            Spacer()
        }
    }
    
    // MARK: - Basic Info Step
    private var basicInfoStep: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Basic Information")
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(.white)
                
                Text("This helps us calculate your maximum heart rate")
                    .font(.system(size: 14, weight: .light))
                    .foregroundColor(.white.opacity(0.6))
            }
            
            // Age
            VStack(alignment: .leading, spacing: 12) {
                Text("How old are you?")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                
                TextField("", text: $age)
                    .keyboardType(.numberPad)
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    .placeholder(when: age.isEmpty) {
                        Text("Age in years")
                            .font(.system(size: 18, weight: .light))
                            .foregroundColor(.white.opacity(0.3))
                            .padding(.leading, 16)
                    }
            }
            
            // Sex
            VStack(alignment: .leading, spacing: 12) {
                Text("Biological sex")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                
                Text("Used for more accurate HR formulas")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                
                HStack(spacing: 12) {
                    ForEach(UserFitnessProfile.Sex.allCases, id: \.self) { option in
                        Button(action: { sex = option }) {
                            Text(option.rawValue)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(sex == option ? .white : .white.opacity(0.6))
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                                .background(sex == option ? AppTheme.accentColor : Color.white.opacity(0.05))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(sex == option ? Color.clear : Color.white.opacity(0.1), lineWidth: 1)
                                )
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Fitness Level Step
    private var fitnessLevelStep: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Running Experience")
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(.white)
                
                Text("Helps estimate your resting heart rate")
                    .font(.system(size: 14, weight: .light))
                    .foregroundColor(.white.opacity(0.6))
            }
            
            VStack(spacing: 12) {
                ForEach(UserFitnessProfile.FitnessLevel.allCases, id: \.self) { level in
                    Button(action: { fitnessLevel = level }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(level.rawValue)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.white)
                                
                                Text(level.description)
                                    .font(.system(size: 13))
                                    .foregroundColor(.white.opacity(0.5))
                            }
                            
                            Spacer()
                            
                            if fitnessLevel == level {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(AppTheme.accentColor)
                            }
                        }
                        .padding(16)
                        .background(fitnessLevel == level ? AppTheme.accentColor.opacity(0.1) : Color.white.opacity(0.03))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(fitnessLevel == level ? AppTheme.accentColor.opacity(0.5) : Color.white.opacity(0.08), lineWidth: 1)
                        )
                    }
                }
            }
        }
    }
    
    // MARK: - Optional Info Step
    private var optionalInfoStep: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Fine-tune Your Zones")
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(.white)
                
                Text("Optional: for more accurate calculations")
                    .font(.system(size: 14, weight: .light))
                    .foregroundColor(.white.opacity(0.6))
            }
            
            // Resting HR
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Resting Heart Rate")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                    
                    Text("(optional)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                }
                
                Text("Measure first thing in the morning")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                
                HStack {
                    TextField("", text: $restingHR)
                        .keyboardType(.numberPad)
                        .font(.system(size: 20, weight: .light))
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(12)
                        .placeholder(when: restingHR.isEmpty) {
                            Text("e.g., 60")
                                .font(.system(size: 16, weight: .light))
                                .foregroundColor(.white.opacity(0.3))
                                .padding(.leading, 16)
                        }
                    
                    Text("bpm")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            
            // Known Max HR
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Known Max Heart Rate")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.white)
                    
                    Text("(optional)")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                }
                
                Text("If you've done a max HR test")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                
                HStack {
                    TextField("", text: $knownMaxHR)
                        .keyboardType(.numberPad)
                        .font(.system(size: 20, weight: .light))
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(12)
                        .placeholder(when: knownMaxHR.isEmpty) {
                            Text("e.g., 185")
                                .font(.system(size: 16, weight: .light))
                                .foregroundColor(.white.opacity(0.3))
                                .padding(.leading, 16)
                        }
                    
                    Text("bpm")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
    }
    
    // MARK: - Results Step
    private var resultsStep: some View {
        VStack(spacing: 24) {
            if let zones = zonesManager.calculatedZones {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 50))
                    .foregroundColor(AppTheme.accentGreen)
                
                Text("Your Zones Are Ready!")
                    .font(.system(size: 24, weight: .light))
                    .foregroundColor(.white)
                
                // Max HR
                VStack(spacing: 8) {
                    Text("Max Heart Rate")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.5))
                    
                    Text("\(zones.maxHeartRate) bpm")
                        .font(.system(size: 32, weight: .light))
                        .foregroundColor(.white)
                }
                .padding(.top, 8)
                
                // VO2 Max
                if let vo2 = zones.estimatedVO2Max, let profile = zonesManager.userProfile {
                    VStack(spacing: 8) {
                        Text("Estimated VO2 Max")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.5))
                        
                        HStack(alignment: .lastTextBaseline, spacing: 8) {
                            Text(String(format: "%.1f", vo2))
                                .font(.system(size: 28, weight: .light))
                                .foregroundColor(.white)
                            
                            Text(zonesManager.vo2MaxRating(vo2Max: vo2, age: profile.age, sex: profile.sex))
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(AppTheme.accentColor)
                        }
                    }
                }
                
                // Zones
                VStack(spacing: 8) {
                    ForEach(zones.zones) { zone in
                        HStack {
                            Circle()
                                .fill(zone.color)
                                .frame(width: 12, height: 12)
                            
                            Text(zone.name)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                            
                            Spacer()
                            
                            Text("\(zone.range.lowerBound)-\(zone.range.upperBound) bpm")
                                .font(.system(size: 14, weight: .light))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(16)
                .background(Color.white.opacity(0.03))
                .cornerRadius(12)
            }
        }
    }
    
    // MARK: - Navigation Buttons
    private var navigationButtons: some View {
        VStack(spacing: 12) {
            Button(action: nextStep) {
                Text(currentStep >= totalSteps ? "Done" : "Continue")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(AppTheme.accentColor)
                    .cornerRadius(12)
            }
            
            if currentStep > 0 && currentStep < totalSteps {
                Button(action: { currentStep -= 1 }) {
                    Text("Back")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 30)
        .background(AppTheme.bgColor)
    }
    
    // MARK: - Actions
    private func nextStep() {
        if currentStep == 1 {
            // Validate age
            guard let ageInt = Int(age), ageInt >= 10 && ageInt <= 100 else {
                errorMessage = "Please enter a valid age between 10 and 100"
                showError = true
                return
            }
        }
        
        if currentStep == 3 {
            // Save profile and calculate zones
            saveProfile()
            currentStep = 4
            return
        }
        
        if currentStep >= totalSteps {
            // Done
            dismiss()
            return
        }
        
        withAnimation {
            currentStep += 1
        }
    }
    
    private func saveProfile() {
        guard let ageInt = Int(age) else { return }
        
        let profile = UserFitnessProfile(
            age: ageInt,
            restingHeartRate: Int(restingHR),
            knownMaxHeartRate: Int(knownMaxHR),
            fitnessLevel: fitnessLevel,
            weight: Double(weight),
            sex: sex
        )
        
        zonesManager.saveProfile(profile)
    }
}

// MARK: - Placeholder Modifier
extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        alignment: Alignment = .leading,
        @ViewBuilder placeholder: () -> Content
    ) -> some View {
        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}

#Preview {
    TrainingZonesOnboarding()
}

