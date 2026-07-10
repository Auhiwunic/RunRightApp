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
    /// Personalized band (blend of population + the user's own history). When
    /// set, it replaces the fixed band center/width and the population norm is
    /// drawn as a dim second trace so "consistent" never reads as "correct".
    var personalCenter: [Double]? = nil
    var personalHalfWidth: [Double]? = nil
    /// 0…1 personalization weight, only used to label the band honestly.
    var wSelf: Double = 0

    private var personalized: Bool { personalCenter?.count == 11 && personalHalfWidth?.count == 11 }

    var body: some View {
        // Band center = personalized blend when we have history, else population.
        let allMean = personalized ? (personalCenter ?? ref.mean) : ref.mean
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
            let range = s[10] - s[0]
            // The line is drawn mean-centered into the band, so its absolute level
            // is irrelevant — a run offset out of the axis purely by the markerless
            // DC bias (exactly what centering cancels) must NOT be dropped. Gate
            // only on it being real data: finite and not a degenerate flat line.
            return range >= 2
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ref.name.uppercased())
                    .font(AppTheme.sectionTitleFont)
                    .foregroundColor(AppTheme.primaryText)
                Spacer()
                Text(personalized && wSelf >= 0.4 ? "YOUR RANGE" : "TYPICAL RANGE")
                    .font(AppTheme.meta(8))
                    .foregroundColor(accent.opacity(0.9))
            }

            // Plain-language explainer so beginners know what "flexion" means.
            if !ref.explain.isEmpty {
                Text(ref.explain)
                    .font(AppTheme.body(11))
                    .foregroundColor(AppTheme.primaryText.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
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

            // Show the legend whenever anything beyond the bare band is drawn —
            // including when the band is personalized (which also draws the dim
            // population trace), so that trace is never rendered without its key.
            if userPlausible || userAtStrike != nil || personalized {
                HStack(spacing: 12) {
                    if userPlausible || userAtStrike != nil {
                        HStack(spacing: 5) {
                            Rectangle().fill(userAccent).frame(width: 12, height: 2)
                            Text("Your run").font(AppTheme.bodyMedium(9)).foregroundColor(AppTheme.primaryText.opacity(0.5))
                        }
                    }
                    HStack(spacing: 5) {
                        Rectangle().fill(accent.opacity(0.5)).frame(width: 12, height: 6)
                        Text(personalized && wSelf >= 0.4 ? "Your typical range" : "Typical range")
                            .font(AppTheme.bodyMedium(9)).foregroundColor(AppTheme.primaryText.opacity(0.5))
                    }
                    if personalized {
                        HStack(spacing: 5) {
                            Rectangle().fill(AppTheme.primaryText.opacity(0.28)).frame(width: 12, height: 1.5)
                            Text("All runners").font(AppTheme.bodyMedium(9)).foregroundColor(AppTheme.primaryText.opacity(0.5))
                        }
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

        // Band half-width: personalized (blend of the runner's own consistency +
        // population) when history exists, else the lenient fixed width. Form
        // varies a lot runner-to-runner, so the fixed fallback widens the
        // research half-widths (2.5x, with a generous per-axis floor); both clamp
        // to the fixed axis so the shaded range never paints off-card.
        // Band = ~2.5x the published between-subject SD (a lenient "typical range",
        // not a strict CI), floored so it never collapses below markerless noise.
        // Floor lowered (0.13 -> 0.08 of span) so the SD structure shows through —
        // tighter in stance where runners are consistent, wider through swing.
        func bandW(_ i: Int) -> Double { personalHalfWidth?[i] ?? max(ref.band[i] * 2.5, span * 0.08) }
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

            // Guardrail: when the band is personalized, always draw the POPULATION
            // center as a dim dashed line. This keeps "you're consistent" (your
            // band) and "you match healthy norms" (this line) as two separate
            // readouts, so a very consistent bad habit can't render as all-green.
            if personalized {
                let popPts = (0...10).map { CGPoint(x: x($0), y: y(min(max(ref.mean[$0], lo), hi))) }
                Path { p in Self.smooth(&p, popPts, close: false) }
                .stroke(AppTheme.primaryText.opacity(0.28),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 3]))
            }

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
            //
            // SHAPE, not absolute degrees: a 2D markerless camera places each
            // joint center a systematic few degrees off its true anatomical
            // center (worst and ~2x noisier at the ankle / occluded far leg),
            // and that offset is larger than the real differences between healthy
            // runners. So we align the user curve's mean to the band's mean and
            // compare the SHAPE and timing of the motion — a genuinely reduced
            // range of motion or mistimed peak still shows, but a runner isn't
            // flagged "off" just for the camera angle or their own anatomy.
            if userPlausible, let uc = userCurve, uc.count == 11 {
                let userMean = uc.reduce(0, +) / Double(uc.count)
                let refMean = mean.reduce(0, +) / Double(mean.count)
                let shift = refMean - userMean
                let pts = (0...10).map { CGPoint(x: x($0), y: y(min(max(uc[$0] + shift, lo), hi))) }
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
