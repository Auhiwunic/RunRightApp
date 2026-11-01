//
//  WearSymmetry.swift
//  RunRightApp
//
//  DISPLAY-ONLY balancing of the left/right wear heatmaps. The two shoes are
//  scanned separately, so lighting and angle can make one side read a zone as
//  worn while the other reads it clean — even though a real pair wears close to
//  symmetrically. This lifts the lesser side of each zone toward the more-worn
//  side so the pair looks like one consistent pattern, unless a zone is truly
//  unworn on both (green/green), which is left alone.
//
//  Applied ONLY where the heatmaps are drawn. The symmetry metric, health score,
//  and FOCUS insights all read the RAW zones, so measurement stays honest.
//

import Foundation

enum WearSymmetry {
    private static let zones = [
        "bigToe", "lesserToes", "medialBall", "centralBall", "lateralBall",
        "medialMidfoot", "lateralMidfoot", "medialHeel", "centralHeel", "lateralHeel"
    ]

    private static func intensity(_ c: String) -> Int {
        switch c.lowercased() {
        case "red": return 3
        case "orange": return 2
        case "yellow": return 1
        default: return 0   // green / none
        }
    }

    private static func colorName(_ i: Int) -> String {
        switch max(0, min(3, i)) {
        case 3: return "red"
        case 2: return "orange"
        case 1: return "yellow"
        default: return "green"
        }
    }

    /// Return display copies of the two shoes with each zone balanced toward its
    /// more-worn side. `strength` (0…1) is how hard the lesser side is pulled up;
    /// 0.8 makes the pair read as the same pattern while keeping a hair of the
    /// real difference. Zones that are unworn on BOTH sides stay untouched.
    static func balanced(_ left: WearZoneData?, _ right: WearZoneData?,
                         strength: Double = 0.8) -> (WearZoneData?, WearZoneData?) {
        guard var l = left, var r = right else { return (left, right) }
        for z in zones {
            let li = intensity(l.color(for: z))
            let ri = intensity(r.color(for: z))
            let hi = max(li, ri)
            let lo = min(li, ri)
            guard hi > 0, hi > lo else { continue }   // both unworn, or already equal
            let lifted = Int((Double(lo) + strength * Double(hi - lo)).rounded())
            if li < ri { l.set(z, colorName(lifted)) }
            else       { r.set(z, colorName(lifted)) }
        }
        return (l, r)
    }
}
