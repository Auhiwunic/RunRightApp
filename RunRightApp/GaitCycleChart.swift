//
//  GaitCycleChart.swift
//  RunRightApp
//
//  Two research-honest chart styles for the full-metrics sheet:
//   • GaitCycleReferenceChart — the optimal joint-angle curve across one full
//     stride, drawn as a shaded band (form is individual, so it is a range not
//     a line) with cited landmarks. Distance and sprint are separate models.
//     Where the app has a matching measured value (foot-strike angle) it drops
//     the user's point on the curve so they see their landing vs optimal.
//   • TargetZoneChart — the user's own metric-over-run line with a shaded
//     "coaching target" zone behind it, mode-aware.
//
//  These deliberately do NOT fabricate a smooth per-cycle user curve: the
//  pipeline stores per-contact scalars, not full waveforms, so inventing one
//  would imply precision the app does not have.
//

import SwiftUI

struct GaitCycleReferenceChart: View {
    let ref: JointReference
    let accent: Color
    /// Optional measured value at foot strike (cycle 0%), e.g. shin/knee angle.
    var userAtStrike: Double? = nil
    /// Optional full measured curve (11 deciles, same units) from the user's run.
    var userCurve: [Double]? = nil
    /// Colour for the measured line. Adapts: ink on paper, white on dark.
    var userAccent: Color = AppTheme.primaryText

    var body: some View {
        let allMean = ref.mean
        // FIXED research axis — the optimal band renders identically every scan;
        // the user's line is clamped into this frame rather than rescaling it.
        let lo = ref.axisLo
        let hi = ref.axisHi
        let span = max(hi - lo, 1)

        // Only draw the user's line when it's real: in-frame (median inside the
        // axis) and not a degenerate flat/pinned line. Otherwise show the band
        // alone rather than a misleading stripe at the top edge.
        let userPlausible: Bool = {
            guard let uc = userCurve, uc.count == 11, uc.allSatisfy({ $0.isFinite }) else { return false }
            let s = uc.sorted()
            let median = s[5]
            let range = s[10] - s[0]
            return median >= lo && median <= hi && range >= 2
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ref.name.uppercased())
                    .font(AppTheme.sectionTitleFont)
                    .foregroundColor(AppTheme.primaryText)
                Spacer()
                Text("TYPICAL RANGE")
                    .font(AppTheme.meta(8))
                    .foregroundColor(accent.opacity(0.9))
            }

            GeometryReader { geo in
                curveBody(w: geo.size.width, h: geo.size.height, lo: lo, hi: hi, span: span, mean: allMean, userPlausible: userPlausible)
            }
            .frame(height: 96)

            // Landmark legend + cycle axis.
            HStack {
                Text("FOOT STRIKE").font(AppTheme.meta(7))
                Spacer()
                Text("SWING").font(AppTheme.meta(7))
                Spacer()
                Text("NEXT STRIKE").font(AppTheme.meta(7))
            }
            .foregroundColor(AppTheme.primaryText.opacity(0.3))

            if userPlausible || userAtStrike != nil {
                HStack(spacing: 12) {
                    HStack(spacing: 5) {
                        Rectangle().fill(userAccent).frame(width: 12, height: 2)
                        Text("Your run").font(AppTheme.bodyMedium(9)).foregroundColor(AppTheme.primaryText.opacity(0.5))
                    }
                    HStack(spacing: 5) {
                        Rectangle().fill(accent.opacity(0.5)).frame(width: 12, height: 6)
                        Text("Typical range").font(AppTheme.bodyMedium(9)).foregroundColor(AppTheme.primaryText.opacity(0.5))
                    }
                }
            }
        }
        .padding(14)
        .appRaisedSurface(fill: AppTheme.cardBg, cornerRadius: 16, shadowRadius: 8, x: 5, y: 6, lightOpacity: 0.08, darkOpacity: 0.34)
    }

    /// Append a Catmull-Rom spline through the points (converted to cubic
    /// Béziers) so the reference and measured curves read as smooth, not
    /// straight-segment. `continued` keeps drawing into an open subpath.
    static func smooth(_ p: inout Path, _ pts: [CGPoint], close: Bool, continued: Bool = false) {
        guard pts.count > 1 else { return }
        if continued { p.addLine(to: pts[0]) } else { p.move(to: pts[0]) }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0, y: p1.y + (p2.y - p0.y) / 6.0)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0, y: p2.y - (p3.y - p1.y) / 6.0)
            p.addCurve(to: p2, control1: c1, control2: c2)
        }
        if close { p.closeSubpath() }
    }

    private func curveBody(w: CGFloat, h: CGFloat, lo: Double, hi: Double, span: Double, mean: [Double], userPlausible: Bool) -> some View {
        func x(_ i: Int) -> CGFloat { w * CGFloat(i) / 10 }
        func y(_ v: Double) -> CGFloat { h * CGFloat(1 - (v - lo) / span) }

        // MUCH more lenient band: form varies a lot runner-to-runner, so widen
        // the research half-widths (2.5x, with a generous per-axis floor) and
        // clamp to the fixed axis so the shaded range never paints off-card.
        func bandW(_ i: Int) -> Double { max(ref.band[i] * 2.5, span * 0.13) }
        let upper = (0...10).map { CGPoint(x: x($0), y: y(min(mean[$0] + bandW($0), hi))) }
        let lower = (0...10).map { CGPoint(x: x($0), y: y(max(mean[$0] - bandW($0), lo))) }

        return ZStack {
            // Zero line if the range crosses it (flexion vs extension).
            if lo < 0 && hi > 0 {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: y(0)))
                    p.addLine(to: CGPoint(x: w, y: y(0)))
                }
                .stroke(AppTheme.primaryText.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            // Shaded optimal band — smooth upper edge, smooth back along lower.
            // No bold "perfect" mean line: a single ideal value is misleading,
            // so only the range is drawn.
            Path { p in
                Self.smooth(&p, upper, close: false)
                Self.smooth(&p, lower.reversed().map { $0 }, close: false, continued: true)
                p.closeSubpath()
            }
            .fill(accent.opacity(0.16))

            // Landmarks: faint vertical guides only (no dot on a mean line).
            ForEach(ref.landmarks.indices, id: \.self) { k in
                let pct = ref.landmarks[k].0
                let px = w * CGFloat(pct)
                Path { p in
                    p.move(to: CGPoint(x: px, y: 0))
                    p.addLine(to: CGPoint(x: px, y: h))
                }
                .stroke(AppTheme.primaryText.opacity(0.10), lineWidth: 1)
            }

            // Measured curve from the user's run — only when plausible (real,
            // in-frame, not a degenerate flat/pinned line). Smoothed.
            if userPlausible, let uc = userCurve, uc.count == 11 {
                let pts = (0...10).map { CGPoint(x: x($0), y: y(min(max(uc[$0], lo), hi))) }
                Path { p in Self.smooth(&p, pts, close: false) }
                .stroke(userAccent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            } else if let u = userAtStrike {
                // Fallback: just the landing value at 0%.
                Circle()
                    .fill(userAccent)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(accent, lineWidth: 2))
                    .position(x: x(0), y: y(min(max(u, lo), hi)))
            }
        }
    }
}

/// One "you vs optimal" comparison track: an optimal zone shaded on a fixed
/// scale, the user's value as a marker, and a plain-language readout. This is
/// the honest alternative to a fake force curve — for contact time, duty factor,
/// leg spring, modeled peak force and overstride, all measured or derived.
struct ComparisonTrack: View {
    let label: String
    let value: Double
    let unit: String
    let axisLo: Double
    let axisHi: Double
    let zoneLo: Double         // optimal zone bounds (in `unit`)
    let zoneHi: Double
    let readout: String
    var accent: Color = AppTheme.accentColor   // signature blue
    var modeled: Bool = false
    var decimals: Int = 0

    private var inZone: Bool { value >= zoneLo && value <= zoneHi }

    var body: some View {
        let span = max(axisHi - axisLo, 0.0001)
        func frac(_ v: Double) -> CGFloat { CGFloat(min(max((v - axisLo) / span, 0), 1)) }

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(label)
                    .font(AppTheme.sectionTitleFont)
                    .foregroundColor(AppTheme.primaryText)
                if modeled {
                    Text("MODELED")
                        .font(AppTheme.meta(7))
                        .foregroundColor(AppTheme.primaryText.opacity(0.3))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().stroke(AppTheme.primaryText.opacity(0.18), lineWidth: 1))
                }
                Spacer()
                Text(String(format: "%.\(decimals)f", value) + " " + unit)
                    .font(AppTheme.head(15))
                    .foregroundColor(inZone ? accent : AppTheme.primaryText)
            }

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(AppTheme.primaryText.opacity(0.06)).frame(height: 6)
                    // Optimal zone.
                    Capsule().fill(accent.opacity(0.35))
                        .frame(width: max(w * (frac(zoneHi) - frac(zoneLo)), 3), height: 6)
                        .offset(x: w * frac(zoneLo))
                    // "Optimal" tick label under the zone center.
                    // User marker.
                    Circle()
                        .fill(inZone ? accent : AppTheme.primaryText)
                        .frame(width: 13, height: 13)
                        .overlay(Circle().stroke(AppTheme.cardBg, lineWidth: 2))
                        .offset(x: w * frac(value) - 6.5)
                }
                .frame(height: 13)
            }
            .frame(height: 13)

            HStack {
                Text("TARGET \(String(format: "%.\(decimals)f", zoneLo))–\(String(format: "%.\(decimals)f", zoneHi)) \(unit)")
                    .font(AppTheme.meta(8))
                    .foregroundColor(accent.opacity(0.8))
                Spacer()
                Text(inZone ? "IN RANGE" : "OUTSIDE")
                    .font(AppTheme.meta(8))
                    .foregroundColor(inZone ? accent.opacity(0.8) : AppTheme.primaryText.opacity(0.4))
            }

            Text(readout)
                .font(AppTheme.body(10))
                .foregroundColor(AppTheme.primaryText.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .appRaisedSurface(fill: AppTheme.cardBg, cornerRadius: 16, shadowRadius: 8, x: 5, y: 6, lightOpacity: 0.08, darkOpacity: 0.34)
    }
}

/// The user's metric-over-run line with a shaded coaching-target zone behind it.
struct TargetZoneChart: View {
    let title: String
    let unit: String
    let series: [Double]        // raw values in `unit`
    let target: FormReference.TargetRange
    let accent: Color

    var body: some View {
        let clean = series.filter(\.isFinite)
        let seriesLo = clean.min() ?? target.lo
        let seriesHi = clean.max() ?? target.hi
        // Pad the axis so the target band and the data both fit.
        let lo = min(seriesLo, target.lo) * 0.95
        let hi = max(seriesHi, target.hi) * 1.05
        let span = max(hi - lo, 1)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(AppTheme.sectionTitleFont)
                    .foregroundColor(AppTheme.primaryText)
                Spacer()
                Text("TARGET \(Int(target.lo))–\(Int(target.hi)) \(target.unit)")
                    .font(AppTheme.meta(8))
                    .foregroundColor(accent.opacity(0.9))
            }

            GeometryReader { geo in
                zoneBody(w: geo.size.width, h: geo.size.height, lo: lo, span: span, clean: clean)
            }
            .frame(height: 64)

            Text(target.note)
                .font(AppTheme.body(10))
                .foregroundColor(AppTheme.primaryText.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .appRaisedSurface(fill: AppTheme.cardBg, cornerRadius: 16, shadowRadius: 8, x: 5, y: 6, lightOpacity: 0.08, darkOpacity: 0.34)
    }

    private func zoneBody(w: CGFloat, h: CGFloat, lo: Double, span: Double, clean: [Double]) -> some View {
        func y(_ v: Double) -> CGFloat { h * CGFloat(1 - (v - lo) / span) }
        return ZStack {
            Rectangle()
                .fill(accent.opacity(0.14))
                .frame(height: max(y(target.lo) - y(target.hi), 2))
                .position(x: w / 2, y: (y(target.lo) + y(target.hi)) / 2)

            if clean.count >= 2 {
                Path { p in
                    for (i, v) in clean.enumerated() {
                        let px = w * CGFloat(i) / CGFloat(clean.count - 1)
                        let pt = CGPoint(x: px, y: y(v))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(AppTheme.primaryText.opacity(0.85), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
