//
//  VoiceAssistantManager.swift
//  RunRightApp
//
//  Text-to-speech voice coaching during runs
//

import Foundation
import AVFoundation
import Combine

// MARK: - Voice Announcement Types
enum VoiceAnnouncementType {
    case distance(Double)
    case pace(Double)
    case heartRateZone(HeartRateZone, Int)
    case zoneChange(HeartRateZone, HeartRateZone)
    case duration(TimeInterval)
    case motivation
    case warning(String)
    case custom(String)
}

// MARK: - Voice Settings
struct VoiceSettings: Codable {
    var isEnabled: Bool = true
    var volume: Float = 1.0              // Full volume for outdoor running
    var rate: Float = 0.5                // 50% speed (middle of slider)
    var pitch: Float = 1.0               // Normal pitch
    var preferredVoiceIdentifier: String? = nil  // Let system pick best Siri voice
    var announceDistance: Bool = true
    var announcePace: Bool = true
    var announceHeartRate: Bool = true
    var announceZoneChanges: Bool = true
    var distanceInterval: Double = 1.0
    var timeInterval: TimeInterval = 300
}

// MARK: - Voice Assistant Manager
class VoiceAssistantManager: NSObject, ObservableObject {
    static let shared = VoiceAssistantManager()
    
    @Published var settings: VoiceSettings = VoiceSettings()
    @Published var isSpeaking: Bool = false
    @Published var currentZone: HeartRateZone?
    @Published var availableVoices: [AVSpeechSynthesisVoice] = []
    
    private let synthesizer = AVSpeechSynthesizer()
    private var lastDistanceAnnounced: Double = 0
    private var lastTimeAnnounced: TimeInterval = 0
    private var lastZone: HeartRateZone?
    private var cancellables = Set<AnyCancellable>()
    private var siriVoice: AVSpeechSynthesisVoice?
    
    private let settingsKey = "voiceAssistantSettings"
    
    private override init() {
        super.init()
        synthesizer.delegate = self
        loadSettings()
        configureAudioSession()
        findBestSiriVoice()
    }
    
    // MARK: - Find Premium Siri Voice
    private func findBestSiriVoice() {
        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        
        // Filter English voices
        let englishVoices = allVoices.filter { $0.language.starts(with: "en") }
        let usVoices = englishVoices.filter { $0.language == "en-US" }
        
        // Store available premium voices for settings
        availableVoices = englishVoices.filter { $0.quality == .premium || $0.quality == .enhanced }
        
        // Check if user has a preferred voice saved FIRST
        if let preferredId = settings.preferredVoiceIdentifier,
           let preferredVoice = AVSpeechSynthesisVoice(identifier: preferredId) {
            siriVoice = preferredVoice
            print("🎙️ Using user's preferred voice: \(preferredVoice.name)")
            return
        }
        
        // Priority order for best voices:
        // 1. Premium quality US voices (best quality, downloaded)
        if let premiumVoice = usVoices.first(where: { $0.quality == .premium }) {
            siriVoice = premiumVoice
            print("🎙️ Using premium voice: \(premiumVoice.name)")
            return
        }
        
        // 2. Enhanced quality US voices (good quality, downloaded)
        if let enhancedVoice = usVoices.first(where: { $0.quality == .enhanced }) {
            siriVoice = enhancedVoice
            print("🎙️ Using enhanced voice: \(enhancedVoice.name)")
            return
        }
        
        // 3. Try specific good voice identifiers
        let goodVoiceNames = ["Samantha", "Ava", "Allison", "Susan", "Zoe", "Nicky"]
        for name in goodVoiceNames {
            if let voice = usVoices.first(where: { $0.name.contains(name) }) {
                siriVoice = voice
                print("🎙️ Using voice: \(voice.name)")
                return
            }
        }
        
        // 4. Any US English voice
        if let usVoice = usVoices.first {
            siriVoice = usVoice
            print("🎙️ Using US voice: \(usVoice.name)")
            return
        }
        
        // 5. Any English voice
        siriVoice = englishVoices.first
        print("🎙️ Using fallback voice: \(siriVoice?.name ?? "system default")")
    }
    
    // MARK: - Voice Selection
    func setVoice(_ voice: AVSpeechSynthesisVoice) {
        siriVoice = voice
        settings.preferredVoiceIdentifier = voice.identifier
        saveSettings()
    }
    
    func getCurrentVoiceName() -> String {
        return siriVoice?.name ?? "Default"
    }
    
    // Get all available premium voices for the picker
    func getPremiumVoices() -> [AVSpeechSynthesisVoice] {
        let allVoices = AVSpeechSynthesisVoice.speechVoices()
        return allVoices.filter { 
            $0.language.starts(with: "en") && 
            ($0.quality == .premium || $0.quality == .enhanced)
        }.sorted { $0.name < $1.name }
    }
    
    // MARK: - Audio Session
    private func configureAudioSession() {
        do {
            // Use .playback category for best voice quality
            // .duckOthers lowers music volume while speaking
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .voicePrompt,  // Better for voice prompts than .spokenAudio
                options: [.duckOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
    
    // MARK: - Public Methods
    
    func speak(_ text: String, priority: Bool = false) {
        guard settings.isEnabled else { return }
        
        // Don't interrupt ongoing speech unless priority
        if synthesizer.isSpeaking {
            if priority {
                synthesizer.stopSpeaking(at: .word) // Stop at word boundary, not immediate
            } else {
                return // Wait for current speech to finish
            }
        }
        
        // Activate audio session before speaking
        try? AVAudioSession.sharedInstance().setActive(true)
        
        let utterance = AVSpeechUtterance(string: text)
        
        // Use premium Siri voice
        utterance.voice = siriVoice ?? AVSpeechSynthesisVoice(language: "en-US")
        
        // Volume
        utterance.volume = settings.volume
        
        // Rate: 0.4 - 0.6 range sounds natural
        // AVSpeechUtteranceDefaultSpeechRate = 0.5
        // settings.rate ranges from 0.3 to 0.7, so use it directly
        utterance.rate = settings.rate
        
        // Natural pitch (1.0 is normal, slightly higher sounds friendlier)
        utterance.pitchMultiplier = settings.pitch
        
        // Delays for natural pacing - give the audio system time to prepare
        utterance.preUtteranceDelay = 0.2   // Pause before speaking
        utterance.postUtteranceDelay = 0.3  // Pause after speaking
        
        synthesizer.speak(utterance)
    }
    
    func announce(_ type: VoiceAnnouncementType) {
        guard settings.isEnabled else { return }
        let text = generateText(for: type)
        speak(text)
    }
    
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
    
    // MARK: - Run Progress Updates
    
    func updateRunProgress(distance: Double, duration: TimeInterval, pace: Double?, heartRate: Int?) {
        guard settings.isEnabled else { return }
        
        if settings.announceDistance {
            let distanceMiles = distance / 1609.34
            if distanceMiles >= lastDistanceAnnounced + settings.distanceInterval {
                lastDistanceAnnounced = floor(distanceMiles / settings.distanceInterval) * settings.distanceInterval
                announceDistanceMilestone(distanceMiles: distanceMiles, duration: duration, pace: pace)
            }
        }
        
        if duration >= lastTimeAnnounced + settings.timeInterval {
            lastTimeAnnounced = floor(duration / settings.timeInterval) * settings.timeInterval
            announceTimeMilestone(duration: duration)
        }
        
        if settings.announceZoneChanges, let hr = heartRate,
           let zones = HeartRateZonesManager.shared.calculatedZones,
           let newZone = zones.currentZone(for: hr) {
            if let lastZone = lastZone, lastZone.id != newZone.id {
                announceZoneChange(from: lastZone, to: newZone, heartRate: hr)
            }
            self.lastZone = newZone
            self.currentZone = newZone
        }
    }
    
    func resetForNewRun() {
        lastDistanceAnnounced = 0
        lastTimeAnnounced = 0
        lastZone = nil
        currentZone = nil
    }
    
    // MARK: - Specific Announcements
    
    func announceRunStart() {
        var text = "Run started. "
        if HeartRateZonesManager.shared.calculatedZones != nil {
            text += "Your zones are calibrated. "
        }
        if settings.announceDistance {
            text += "Distance updates every \(formatDistanceInterval()). "
        }
        text += "Let's go!"
        speak(text)
    }
    
    func announceRunPaused() {
        speak("Run paused.")
    }
    
    func announceRunResumed() {
        speak("Run resumed. Keep going!")
    }
    
    func announceRunCompleted(distance: Double, duration: TimeInterval) {
        let distanceMiles = distance / 1609.34
        let text = "Run complete! You covered \(String(format: "%.2f", distanceMiles)) miles in \(formatDuration(duration)). Great job!"
        speak(text, priority: true)
    }
    
    private func announceDistanceMilestone(distanceMiles: Double, duration: TimeInterval, pace: Double?) {
        var text = "\(formatDistance(distanceMiles)). Time: \(formatDuration(duration)). "
        if settings.announcePace, let pace = pace, pace > 0 {
            text += "Pace: \(formatPace(pace)). "
        }
        if Int(distanceMiles) % 3 == 0 {
            text += getMotivationalPhrase()
        }
        speak(text)
    }
    
    private func announceTimeMilestone(duration: TimeInterval) {
        let text = "\(formatDuration(duration)) elapsed."
        speak(text)
    }
    
    private func announceZoneChange(from oldZone: HeartRateZone, to newZone: HeartRateZone, heartRate: Int) {
        var text = ""
        if newZone.id > oldZone.id {
            text = "Heart rate increasing. Now in \(newZone.name) zone at \(heartRate) BPM. "
            if newZone.id >= 4 {
                text += "Consider slowing down to stay aerobic."
            }
        } else {
            text = "Heart rate decreasing. Now in \(newZone.name) zone at \(heartRate) BPM. "
            if newZone.id <= 2 {
                text += "Good recovery pace."
            }
        }
        speak(text)
    }
    
    func announceCurrentHeartRate(_ heartRate: Int) {
        guard let zones = HeartRateZonesManager.shared.calculatedZones,
              let zone = zones.currentZone(for: heartRate) else {
            speak("Heart rate: \(heartRate) BPM.")
            return
        }
        speak("Heart rate: \(heartRate) BPM. \(zone.name) zone.")
    }
    
    // MARK: - Text Generation
    
    private func generateText(for type: VoiceAnnouncementType) -> String {
        switch type {
        case .distance(let distance):
            return formatDistance(distance / 1609.34)
        case .pace(let pace):
            return "Current pace: \(formatPace(pace))"
        case .heartRateZone(let zone, let hr):
            return "\(zone.name) zone at \(hr) BPM"
        case .zoneChange(let from, let to):
            return "Zone change: from \(from.name) to \(to.name)"
        case .duration(let duration):
            return formatDuration(duration)
        case .motivation:
            return getMotivationalPhrase()
        case .warning(let message):
            return "Warning: \(message)"
        case .custom(let text):
            return text
        }
    }
    
    // MARK: - Formatting Helpers
    
    private func formatDistance(_ miles: Double) -> String {
        if miles < 1 {
            return String(format: "%.1f miles", miles)
        } else if floor(miles) == miles {
            return "\(Int(miles)) \(Int(miles) == 1 ? "mile" : "miles")"
        } else {
            return String(format: "%.1f miles", miles)
        }
    }
    
    private func formatDistanceInterval() -> String {
        if settings.distanceInterval == 1 {
            return "mile"
        } else if settings.distanceInterval == 0.5 {
            return "half mile"
        } else {
            return String(format: "%.1f miles", settings.distanceInterval)
        }
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return "\(hours) hour\(hours > 1 ? "s" : "") \(minutes) minute\(minutes != 1 ? "s" : "")"
        } else if minutes > 0 {
            return "\(minutes) minute\(minutes != 1 ? "s" : "") \(seconds) second\(seconds != 1 ? "s" : "")"
        } else {
            return "\(seconds) second\(seconds != 1 ? "s" : "")"
        }
    }
    
    private func formatPace(_ metersPerSecond: Double) -> String {
        guard metersPerSecond > 0 else { return "calculating" }
        let secondsPerMile = 1609.34 / metersPerSecond
        let minutes = Int(secondsPerMile) / 60
        let seconds = Int(secondsPerMile) % 60
        return "\(minutes) \(seconds < 10 ? "oh \(seconds)" : String(seconds)) per mile"
    }
    
    private func getMotivationalPhrase() -> String {
        let phrases = [
            "Keep it up!",
            "You're doing great!",
            "Strong pace!",
            "Looking good!",
            "Stay focused!",
            "Keep pushing!",
            "You've got this!",
            "Excellent work!",
            "Stay strong!",
            "Nice job!"
        ]
        return phrases.randomElement() ?? "Keep going!"
    }
    
    // MARK: - Persistence
    
    func saveSettings() {
        if let encoded = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(encoded, forKey: settingsKey)
        }
    }
    
    private func loadSettings() {
        guard let data = UserDefaults.standard.data(forKey: settingsKey),
              let decoded = try? JSONDecoder().decode(VoiceSettings.self, from: data) else {
            return
        }
        settings = decoded
    }
}

// MARK: - AVSpeechSynthesizerDelegate
extension VoiceAssistantManager: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = true
        }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
        }
    }
}

