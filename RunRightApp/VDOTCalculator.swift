//
//  VDOTCalculator.swift
//  RunRightApp
//
//  On-device VDOT engine: converts 1-mile time trial → training paces → weekly plan.
//  Based on Jack Daniels' Running Formula tables.

import Foundation

// MARK: - Run Goal
enum RunGoal: String, CaseIterable, Identifiable {
    case fiveK = "5K"
    case tenK = "10K"
    case halfMarathon = "Half Marathon"
    case marathon = "Marathon"
    case generalFitness = "General Fitness"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .fiveK: return "figure.run"
        case .tenK: return "figure.run.circle"
        case .halfMarathon: return "medal"
        case .marathon: return "trophy"
        case .generalFitness: return "heart.circle"
        }
    }
}

// MARK: - Training Paces
struct TrainingPaces {
    let easy: String       // min:sec per mile
    let marathon: String
    let threshold: String  // tempo pace
    let interval: String   // VO2max
    let repetition: String // speed work
    
    let easySeconds: Double
    let marathonSeconds: Double
    let thresholdSeconds: Double
    let intervalSeconds: Double
    let repetitionSeconds: Double
}

// MARK: - VDOT Table Entry
private struct VDOTEntry {
    let vdot: Double
    let mileSeconds: Double     // 1-mile race time in seconds
    let easyPace: Double        // seconds per mile
    let marathonPace: Double
    let thresholdPace: Double
    let intervalPace: Double
    let repetitionPace: Double
}

// MARK: - VDOT Calculator
struct VDOTCalculator {
    
    // Daniels' VDOT table: VDOT → 1-mile time → training paces (all in seconds/mile)
    // Covers VDOT 30–75 (beginner → elite)
    private static let table: [VDOTEntry] = [
        // VDOT, 1mi time,   Easy,   Marathon, Threshold, Interval, Repetition
        VDOTEntry(vdot: 30, mileSeconds: 622, easyPace: 795, marathonPace: 720, thresholdPace: 670, intervalPace: 622, repetitionPace: 585),
        VDOTEntry(vdot: 32, mileSeconds: 594, easyPace: 760, marathonPace: 690, thresholdPace: 642, intervalPace: 594, repetitionPace: 558),
        VDOTEntry(vdot: 34, mileSeconds: 568, easyPace: 728, marathonPace: 662, thresholdPace: 616, intervalPace: 568, repetitionPace: 534),
        VDOTEntry(vdot: 36, mileSeconds: 544, easyPace: 698, marathonPace: 636, thresholdPace: 592, intervalPace: 544, repetitionPace: 512),
        VDOTEntry(vdot: 38, mileSeconds: 522, easyPace: 670, marathonPace: 612, thresholdPace: 570, intervalPace: 522, repetitionPace: 492),
        VDOTEntry(vdot: 40, mileSeconds: 501, easyPace: 644, marathonPace: 590, thresholdPace: 549, intervalPace: 501, repetitionPace: 473),
        VDOTEntry(vdot: 42, mileSeconds: 482, easyPace: 620, marathonPace: 569, thresholdPace: 530, intervalPace: 482, repetitionPace: 456),
        VDOTEntry(vdot: 44, mileSeconds: 464, easyPace: 598, marathonPace: 550, thresholdPace: 512, intervalPace: 464, repetitionPace: 440),
        VDOTEntry(vdot: 46, mileSeconds: 448, easyPace: 577, marathonPace: 532, thresholdPace: 496, intervalPace: 448, repetitionPace: 425),
        VDOTEntry(vdot: 48, mileSeconds: 433, easyPace: 558, marathonPace: 515, thresholdPace: 481, intervalPace: 433, repetitionPace: 411),
        VDOTEntry(vdot: 50, mileSeconds: 419, easyPace: 540, marathonPace: 500, thresholdPace: 467, intervalPace: 419, repetitionPace: 398),
        VDOTEntry(vdot: 52, mileSeconds: 406, easyPace: 524, marathonPace: 486, thresholdPace: 454, intervalPace: 406, repetitionPace: 386),
        VDOTEntry(vdot: 54, mileSeconds: 394, easyPace: 508, marathonPace: 472, thresholdPace: 442, intervalPace: 394, repetitionPace: 375),
        VDOTEntry(vdot: 56, mileSeconds: 383, easyPace: 494, marathonPace: 460, thresholdPace: 430, intervalPace: 383, repetitionPace: 364),
        VDOTEntry(vdot: 58, mileSeconds: 372, easyPace: 480, marathonPace: 448, thresholdPace: 420, intervalPace: 372, repetitionPace: 354),
        VDOTEntry(vdot: 60, mileSeconds: 362, easyPace: 468, marathonPace: 437, thresholdPace: 410, intervalPace: 362, repetitionPace: 345),
        VDOTEntry(vdot: 63, mileSeconds: 348, easyPace: 450, marathonPace: 422, thresholdPace: 396, intervalPace: 348, repetitionPace: 332),
        VDOTEntry(vdot: 66, mileSeconds: 335, easyPace: 434, marathonPace: 408, thresholdPace: 383, intervalPace: 335, repetitionPace: 320),
        VDOTEntry(vdot: 70, mileSeconds: 318, easyPace: 414, marathonPace: 390, thresholdPace: 366, intervalPace: 318, repetitionPace: 305),
        VDOTEntry(vdot: 75, mileSeconds: 298, easyPace: 390, marathonPace: 368, thresholdPace: 346, intervalPace: 298, repetitionPace: 287),
    ]
    
    // MARK: - VDOT from 1-Mile Time
    
    /// Convert a 1-mile time (in seconds) to a VDOT score.
    static func vdotFromMileTime(_ seconds: Double) -> Double {
        // Clamp to table range
        guard seconds <= table.first!.mileSeconds else { return table.first!.vdot }
        guard seconds >= table.last!.mileSeconds else { return table.last!.vdot }
        
        // Find bracketing entries and interpolate
        for i in 0..<(table.count - 1) {
            let upper = table[i]     // slower time, lower VDOT
            let lower = table[i + 1] // faster time, higher VDOT
            
            if seconds <= upper.mileSeconds && seconds >= lower.mileSeconds {
                let timeFraction = (upper.mileSeconds - seconds) / (upper.mileSeconds - lower.mileSeconds)
                return upper.vdot + timeFraction * (lower.vdot - upper.vdot)
            }
        }
        
        return 40 // fallback
    }
    
    // MARK: - Training Paces from VDOT
    
    /// Get all 5 training paces for a given VDOT.
    static func trainingPaces(vdot: Double) -> TrainingPaces {
        let entry = interpolatedEntry(for: vdot)
        return TrainingPaces(
            easy: formatPace(entry.easyPace),
            marathon: formatPace(entry.marathonPace),
            threshold: formatPace(entry.thresholdPace),
            interval: formatPace(entry.intervalPace),
            repetition: formatPace(entry.repetitionPace),
            easySeconds: entry.easyPace,
            marathonSeconds: entry.marathonPace,
            thresholdSeconds: entry.thresholdPace,
            intervalSeconds: entry.intervalPace,
            repetitionSeconds: entry.repetitionPace
        )
    }
    
    // MARK: - Generate Weekly Plan
    
    /// Generate a personalized 7-day plan based on VDOT and goal.
    static func generateWeeklyPlan(vdot: Double, goal: RunGoal) -> [DayPlan] {
        let paces = trainingPaces(vdot: vdot)
        
        switch goal {
        case .fiveK:
            return fiveKPlan(paces: paces)
        case .tenK:
            return tenKPlan(paces: paces)
        case .halfMarathon:
            return halfMarathonPlan(paces: paces)
        case .marathon:
            return marathonPlan(paces: paces)
        case .generalFitness:
            return generalFitnessPlan(paces: paces)
        }
    }
    
    // MARK: - Goal-Specific Plans
    
    private static func fiveKPlan(paces: TrainingPaces) -> [DayPlan] {
        [
            makeDayPlan(day: "Monday", type: "Easy", distance: "3.0 mi", pace: paces.easy, segments: [
                .init(name: "Easy Run", distance: "3.0 mi", pace: paces.easy)
            ], zones: [.init(zoneName: "Zone 2", minutes: 30, colorHex: "#5ECC3A")]),
            
            makeDayPlan(day: "Tuesday", type: "Intervals", distance: "4.5 mi", pace: "varies", segments: [
                .init(name: "Warm Up", distance: "1.0 mi", pace: paces.easy),
                .init(name: "800m Hard", distance: "0.5 mi", pace: paces.interval),
                .init(name: "400m Jog", distance: "0.25 mi", pace: paces.easy),
                .init(name: "800m Hard", distance: "0.5 mi", pace: paces.interval),
                .init(name: "400m Jog", distance: "0.25 mi", pace: paces.easy),
                .init(name: "800m Hard", distance: "0.5 mi", pace: paces.interval),
                .init(name: "Cool Down", distance: "0.5 mi", pace: paces.easy)
            ], zones: [
                .init(zoneName: "Zone 2", minutes: 12, colorHex: "#5ECC3A"),
                .init(zoneName: "Zone 5", minutes: 15, colorHex: "#E83030"),
                .init(zoneName: "Zone 2", minutes: 5, colorHex: "#5ECC3A")
            ]),
            
            makeRestDay(day: "Wednesday"),
            
            makeDayPlan(day: "Thursday", type: "Tempo", distance: "4.0 mi", pace: paces.threshold, segments: [
                .init(name: "Warm Up", distance: "1.0 mi", pace: paces.easy),
                .init(name: "Tempo", distance: "2.0 mi", pace: paces.threshold),
                .init(name: "Cool Down", distance: "1.0 mi", pace: paces.easy)
            ], zones: [
                .init(zoneName: "Zone 2", minutes: 10, colorHex: "#5ECC3A"),
                .init(zoneName: "Zone 4", minutes: 16, colorHex: "#E89830"),
                .init(zoneName: "Zone 2", minutes: 10, colorHex: "#5ECC3A")
            ]),
            
            makeDayPlan(day: "Friday", type: "Easy", distance: "3.0 mi", pace: paces.easy, segments: [
                .init(name: "Easy Run", distance: "3.0 mi", pace: paces.easy)
            ], zones: [.init(zoneName: "Zone 2", minutes: 30, colorHex: "#5ECC3A")]),
            
            makeDayPlan(day: "Saturday", type: "Long Run", distance: "6.0 mi", pace: paces.easy, segments: [
                .init(name: "Warm Up", distance: "1.0 mi", pace: paces.easy),
                .init(name: "Steady", distance: "4.0 mi", pace: paces.easy),
                .init(name: "Cool Down", distance: "1.0 mi", pace: paces.easy)
            ], zones: [.init(zoneName: "Zone 2", minutes: 60, colorHex: "#5ECC3A")]),
            
            makeRestDay(day: "Sunday")
        ]
    }
    
    private static func tenKPlan(paces: TrainingPaces) -> [DayPlan] {
        [
            makeDayPlan(day: "Monday", type: "Easy", distance: "4.0 mi", pace: paces.easy, segments: [
                .init(name: "Easy Run", distance: "4.0 mi", pace: paces.easy)
            ], zones: [.init(zoneName: "Zone 2", minutes: 40, colorHex: "#5ECC3A")]),
            
            makeDayPlan(day: "Tuesday", type: "Tempo", distance: "5.0 mi", pace: paces.threshold, segments: [
                .init(name: "Warm Up", distance: "1.0 mi", pace: paces.easy),
                .init(name: "Tempo", distance: "3.0 mi", pace: paces.threshold),
                .init(name: "Cool Down", distance: "1.0 mi", pace: paces.easy)
            ], zones: [
                .init(zoneName: "Zone 2", minutes: 10, colorHex: "#5ECC3A"),
                .init(zoneName: "Zone 4", minutes: 24, colorHex: "#E89830"),
                .init(zoneName: "Zone 2", minutes: 10, colorHex: "#5ECC3A")
            ]),
            
            makeRestDay(day: "Wednesday"),
            
            makeDayPlan(day: "Thursday", type: "Intervals", distance: "5.0 mi", pace: "varies", segments: [
                .init(name: "Warm Up", distance: "1.0 mi", pace: paces.easy),
                .init(name: "1000m Hard", distance: "0.62 mi", pace: paces.interval),
                .init(name: "400m Jog", distance: "0.25 mi", pace: paces.easy),
                .init(name: "1000m Hard", distance: "0.62 mi", pace: paces.interval),
                .init(name: "400m Jog", distance: "0.25 mi", pace: paces.easy),
                .init(name: "1000m Hard", distance: "0.62 mi", pace: paces.interval),
                .init(name: "Cool Down", distance: "0.64 mi", pace: paces.easy)
            ], zones: [
                .init(zoneName: "Zone 2", minutes: 14, colorHex: "#5ECC3A"),
                .init(zoneName: "Zone 5", minutes: 18, colorHex: "#E83030"),
                .init(zoneName: "Zone 2", minutes: 6, colorHex: "#5ECC3A")
            ]),
            
            makeDayPlan(day: "Friday", type: "Recovery", distance: "3.0 mi", pace: paces.easy, segments: [
                .init(name: "Easy Jog", distance: "3.0 mi", pace: paces.easy)
            ], zones: [.init(zoneName: "Zone 1", minutes: 30, colorHex: "#00CED1")]),
            
            makeDayPlan(day: "Saturday", type: "Long Run", distance: "8.0 mi", pace: paces.easy, segments: [
                .init(name: "Warm Up", distance: "1.0 mi", pace: paces.easy),
                .init(name: "Steady", distance: "6.0 mi", pace: paces.easy),
                .init(name: "Cool Down", distance: "1.0 mi", pace: paces.easy)
            ], zones: [.init(zoneName: "Zone 2", minutes: 72, colorHex: "#5ECC3A")]),
            
            makeRestDay(day: "Sunday")
        ]
    }
    
    private static func halfMarathonPlan(paces: TrainingPaces) -> [DayPlan] {
        [
            makeDayPlan(day: "Monday", type: "Easy", distance: "4.0 mi", pace: paces.easy, segments: [
                .init(name: "Easy Run", distance: "4.0 mi", pace: paces.easy)
            ], zones: [.init(zoneName: "Zone 2", minutes: 40, colorHex: "#5ECC3A")]),
            
            makeDayPlan(day: "Tuesday", type: "Tempo", distance: "6.0 mi", pace: paces.threshold, segments: [
                .init(name: "Warm Up", distance: "1.5 mi", pace: paces.easy),
                .init(name: "Tempo", distance: "3.0 mi", pace: paces.threshold),
                .init(name: "Cool Down", distance: "1.5 mi", pace: paces.easy)
            ], zones: [
                .init(zoneName: "Zone 2", minutes: 15, colorHex: "#5ECC3A"),
                .init(zoneName: "Zone 4", minutes: 24, colorHex: "#E89830"),
                .init(zoneName: "Zone 2", minutes: 15, colorHex: "#5ECC3A")
            ]),
            
            makeDayPlan(day: "Wednesday", type: "Easy", distance: "4.0 mi", pace: paces.easy, segments: [
                .init(name: "Easy Run", distance: "4.0 mi", pace: paces.easy)
            ], zones: [.init(zoneName: "Zone 2", minutes: 40, colorHex: "#5ECC3A")]),
            
            makeDayPlan(day: "Thursday", type: "Intervals", distance: "5.0 mi", pace: "varies", segments: [
                .init(name: "Warm Up", distance: "1.0 mi", pace: paces.easy),
                .init(name: "Mile Repeat", distance: "1.0 mi", pace: paces.interval),
                .init(name: "800m Jog", distance: "0.5 mi", pace: paces.easy),
                .init(name: "Mile Repeat", distance: "1.0 mi", pace: paces.interval),
                .init(name: "Cool Down", distance: "1.5 mi", pace: paces.easy)
            ], zones: [
                .init(zoneName: "Zone 2", minutes: 16, colorHex: "#5ECC3A"),
                .init(zoneName: "Zone 5", minutes: 14, colorHex: "#E83030"),
                .init(zoneName: "Zone 2", minutes: 10, colorHex: "#5ECC3A")
            ]),
            
            makeDayPlan(day: "Friday", type: "Recovery", distance: "3.0 mi", pace: paces.easy, segments: [
                .init(name: "Easy Jog", distance: "3.0 mi", pace: paces.easy)
            ], zones: [.init(zoneName: "Zone 1", minutes: 30, colorHex: "#00CED1")]),
            
            makeDayPlan(day: "Saturday", type: "Long Run", distance: "12.0 mi", pace: paces.easy, segments: [
                .init(name: "Warm Up", distance: "2.0 mi", pace: paces.easy),
                .init(name: "Steady", distance: "8.0 mi", pace: paces.easy),
                .init(name: "Cool Down", distance: "2.0 mi", pace: paces.easy)
            ], zones: [.init(zoneName: "Zone 2", minutes: 108, colorHex: "#5ECC3A")]),
            
            makeRestDay(day: "Sunday")
        ]
    }
    
    private static func marathonPlan(paces: TrainingPaces) -> [DayPlan] {
        [
            makeDayPlan(day: "Monday", type: "Easy", distance: "5.0 mi", pace: paces.easy, segments: [
                .init(name: "Easy Run", distance: "5.0 mi", pace: paces.easy)
            ], zones: [.init(zoneName: "Zone 2", minutes: 50, colorHex: "#5ECC3A")]),
            
            makeDayPlan(day: "Tuesday", type: "Tempo", distance: "7.0 mi", pace: paces.threshold, segments: [
                .init(name: "Warm Up", distance: "2.0 mi", pace: paces.easy),
                .init(name: "Marathon Pace", distance: "3.0 mi", pace: paces.marathon),
                .init(name: "Cool Down", distance: "2.0 mi", pace: paces.easy)
            ], zones: [
                .init(zoneName: "Zone 2", minutes: 20, colorHex: "#5ECC3A"),
                .init(zoneName: "Zone 3", minutes: 24, colorHex: "#E8D44A"),
                .init(zoneName: "Zone 2", minutes: 20, colorHex: "#5ECC3A")
            ]),
            
            makeDayPlan(day: "Wednesday", type: "Easy", distance: "5.0 mi", pace: paces.easy, segments: [
                .init(name: "Easy Run", distance: "5.0 mi", pace: paces.easy)
            ], zones: [.init(zoneName: "Zone 2", minutes: 50, colorHex: "#5ECC3A")]),
            
            makeDayPlan(day: "Thursday", type: "Tempo", distance: "8.0 mi", pace: paces.threshold, segments: [
                .init(name: "Warm Up", distance: "2.0 mi", pace: paces.easy),
                .init(name: "Tempo", distance: "4.0 mi", pace: paces.threshold),
                .init(name: "Cool Down", distance: "2.0 mi", pace: paces.easy)
            ], zones: [
                .init(zoneName: "Zone 2", minutes: 20, colorHex: "#5ECC3A"),
                .init(zoneName: "Zone 4", minutes: 32, colorHex: "#E89830"),
                .init(zoneName: "Zone 2", minutes: 20, colorHex: "#5ECC3A")
            ]),
            
            makeDayPlan(day: "Friday", type: "Recovery", distance: "3.0 mi", pace: paces.easy, segments: [
                .init(name: "Easy Jog", distance: "3.0 mi", pace: paces.easy)
            ], zones: [.init(zoneName: "Zone 1", minutes: 30, colorHex: "#00CED1")]),
            
            makeDayPlan(day: "Saturday", type: "Long Run", distance: "16.0 mi", pace: paces.easy, segments: [
                .init(name: "Warm Up", distance: "2.0 mi", pace: paces.easy),
                .init(name: "Steady", distance: "10.0 mi", pace: paces.easy),
                .init(name: "Marathon Pace", distance: "2.0 mi", pace: paces.marathon),
                .init(name: "Cool Down", distance: "2.0 mi", pace: paces.easy)
            ], zones: [
                .init(zoneName: "Zone 2", minutes: 120, colorHex: "#5ECC3A"),
                .init(zoneName: "Zone 3", minutes: 16, colorHex: "#E8D44A")
            ]),
            
            makeRestDay(day: "Sunday")
        ]
    }
    
    private static func generalFitnessPlan(paces: TrainingPaces) -> [DayPlan] {
        [
            makeDayPlan(day: "Monday", type: "Easy", distance: "3.0 mi", pace: paces.easy, segments: [
                .init(name: "Easy Run", distance: "3.0 mi", pace: paces.easy)
            ], zones: [.init(zoneName: "Zone 2", minutes: 30, colorHex: "#5ECC3A")]),
            
            makeDayPlan(day: "Tuesday", type: "Tempo", distance: "3.5 mi", pace: paces.threshold, segments: [
                .init(name: "Warm Up", distance: "0.75 mi", pace: paces.easy),
                .init(name: "Tempo", distance: "2.0 mi", pace: paces.threshold),
                .init(name: "Cool Down", distance: "0.75 mi", pace: paces.easy)
            ], zones: [
                .init(zoneName: "Zone 2", minutes: 8, colorHex: "#5ECC3A"),
                .init(zoneName: "Zone 4", minutes: 16, colorHex: "#E89830"),
                .init(zoneName: "Zone 2", minutes: 8, colorHex: "#5ECC3A")
            ]),
            
            makeRestDay(day: "Wednesday"),
            
            makeDayPlan(day: "Thursday", type: "Easy", distance: "3.0 mi", pace: paces.easy, segments: [
                .init(name: "Easy Run", distance: "3.0 mi", pace: paces.easy)
            ], zones: [.init(zoneName: "Zone 2", minutes: 30, colorHex: "#5ECC3A")]),
            
            makeRestDay(day: "Friday"),
            
            makeDayPlan(day: "Saturday", type: "Long Run", distance: "5.0 mi", pace: paces.easy, segments: [
                .init(name: "Warm Up", distance: "0.5 mi", pace: paces.easy),
                .init(name: "Steady", distance: "4.0 mi", pace: paces.easy),
                .init(name: "Cool Down", distance: "0.5 mi", pace: paces.easy)
            ], zones: [.init(zoneName: "Zone 2", minutes: 50, colorHex: "#5ECC3A")]),
            
            makeRestDay(day: "Sunday")
        ]
    }
    
    // MARK: - Helpers
    
    private static func makeDayPlan(day: String, type: String, distance: String, pace: String,
                                     segments: [WorkoutSegment], zones: [ZoneTarget]) -> DayPlan {
        DayPlan(dayName: day, runType: type, isRest: false,
                totalDistance: distance, targetPace: pace,
                segments: segments, zoneTargets: zones)
    }
    
    private static func makeRestDay(day: String) -> DayPlan {
        DayPlan(dayName: day, runType: "Rest", isRest: true,
                totalDistance: "—", targetPace: "—",
                segments: [], zoneTargets: [])
    }
    
    private static func interpolatedEntry(for vdot: Double) -> VDOTEntry {
        guard vdot >= table.first!.vdot else { return table.first! }
        guard vdot <= table.last!.vdot else { return table.last! }
        
        for i in 0..<(table.count - 1) {
            let lower = table[i]
            let upper = table[i + 1]
            
            if vdot >= lower.vdot && vdot <= upper.vdot {
                let frac = (vdot - lower.vdot) / (upper.vdot - lower.vdot)
                return VDOTEntry(
                    vdot: vdot,
                    mileSeconds: lerp(lower.mileSeconds, upper.mileSeconds, frac),
                    easyPace: lerp(lower.easyPace, upper.easyPace, frac),
                    marathonPace: lerp(lower.marathonPace, upper.marathonPace, frac),
                    thresholdPace: lerp(lower.thresholdPace, upper.thresholdPace, frac),
                    intervalPace: lerp(lower.intervalPace, upper.intervalPace, frac),
                    repetitionPace: lerp(lower.repetitionPace, upper.repetitionPace, frac)
                )
            }
        }
        
        return table[table.count / 2] // fallback to midpoint
    }
    
    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }
    
    static func formatPace(_ secondsPerMile: Double) -> String {
        let mins = Int(secondsPerMile) / 60
        let secs = Int(secondsPerMile) % 60
        return String(format: "%d:%02d/mi", mins, secs)
    }
    
    static func formatPaceShort(_ secondsPerMile: Double) -> String {
        let mins = Int(secondsPerMile) / 60
        let secs = Int(secondsPerMile) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
