//
//  DrillsLibrary.swift
//  RunRightApp
//
//  Corrective drills tied to the FOCUS findings, each with a dosage. Copy is
//  short and hyphen free. Evidence: cadence bump (5 to 10 percent) is the
//  highest yield fix; hip drop is fixed with single leg loading, not isolation;
//  strength comes before form retraining and changes are added gradually.
//

import SwiftUI

struct Drill: Identifiable {
    let id = UUID()
    let target: String   // short category label
    let title: String
    let how: String
    let dose: String
    let hex: String      // category accent
}

enum DrillsLibrary {
    static let all: [Drill] = [
        Drill(target: "CADENCE", title: "Cadence bump",
              how: "Run to a metronome set 5 to 10 percent above your normal step rate. Keep your steps short and light so your foot lands under you, not ahead of you.",
              dose: "A few minutes each run, build up gradually", hex: "#FF3B3B"),
        Drill(target: "HIP AND GLUTES", title: "Single leg bridge",
              how: "On your back, one foot planted and the other leg straight. Drive through the heel and lift your hips until they sit level.",
              dose: "3 sets of 12 each side, 3 times a week", hex: "#FF8C00"),
        Drill(target: "HIP AND GLUTES", title: "Lateral band walk",
              how: "Loop a band above your knees, drop into a half squat and step sideways while keeping the band tight. Stay low the whole time.",
              dose: "3 sets of 15 steps each way", hex: "#FF8C00"),
        Drill(target: "KNEE AND HIP", title: "Step down",
              how: "Stand on a low step, slowly lower the other heel to tap the floor, then drive back up. Keep your kneecap tracking over your toes.",
              dose: "3 sets of 10 each leg", hex: "#FF8C00"),
        Drill(target: "LANDING", title: "Soft quiet feet",
              how: "On easy runs, focus on landing softly and silently. Picture running over eggshells without cracking them.",
              dose: "1 to 2 minutes, a few times per run", hex: "#00FF7F"),
        Drill(target: "POSTURE", title: "Tall posture",
              how: "Run tall and lean slightly from the ankles, not the waist. Open your chest. A gentle wall lean teaches the angle.",
              dose: "Reset your posture every kilometre", hex: "#00CED1"),
        Drill(target: "HEAD", title: "Eyes forward",
              how: "Fix your gaze about 20 metres ahead with your chin level. Pick a target and hold it instead of watching your feet.",
              dose: "Cue it on every run", hex: "#00CED1"),
        Drill(target: "ARMS", title: "Arm swing",
              how: "Keep your elbows near 90 degrees and swing front to back so your hands brush your waistband. Do not let them cross your body.",
              dose: "Cue it on easy runs", hex: "#00CED1")
    ]
}

