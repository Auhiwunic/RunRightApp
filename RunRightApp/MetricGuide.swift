//
//  MetricGuide.swift
//  RunRightApp
//
//  One place that answers, for every metric the app shows: what it is, why it
//  matters for your running, what good looks like, and how form fixes it.
//  Copy is short, plain and hyphen free. Ranges come from published running
//  dynamics data (Garmin percentile bands, Weyand sprint studies, cadence and
//  overstride literature) so targets are honest, not invented.
//

import SwiftUI

struct MetricGuideEntry: Identifiable {
    var id: String { title }
    let title: String
    let what: String
    let why: String
    let target: String
    let fix: String
}

enum MetricGuide {

    static let formGrade = MetricGuideEntry(
        title: "Form grade",
        what: "One number from 0 to 100, the average of your form cue scores from this video. The letter is that number as a grade.",
        why: "It tracks the habits that keep you fast and uninjured: posture, landing position, arm swing and turnover. Runs feel easier as it climbs.",
        target: "80 and up is an A range stride. Most runners start in the 60s and that is fine.",
        fix: "Work one cue at a time. The FOCUS list below ranks them, and two weeks on the worst one moves the grade more than poking at all of them."
    )

    static let cadence = MetricGuideEntry(
        title: "Cadence",
        what: "How many steps you take per minute, counting both feet.",
        why: "Quick steps keep each landing under your hips. Slow turnover stretches the stride out front, and a foot out front brakes you on every step and sends the shock up your shins and knees.",
        target: "165 to 200 spm covers most good running. Cadence rises with pace, so fast efforts near 190 to 200 are normal, and easy runs sit lower. Taller runners run a little lower at any pace.",
        fix: "Run short stretches to a metronome set 5 to 10 percent above your natural rate. Think short, light, quick. The Cadence bump drill in Coach is built for exactly this."
    )

    static let strike = MetricGuideEntry(
        title: "Foot strike",
        what: "Which part of your foot touches down first: heel, midfoot or forefoot.",
        why: "Strike style matters less than where the foot lands. A heel strike under your hips is fine. Any strike far out front acts as a brake, whatever part of the foot lands first.",
        target: "There is no single best strike. Land close to under your hips with a quiet foot and keep whichever strike feels natural.",
        fix: "Do not force a forefoot strike, that mostly moves the load to your calves. Lift your cadence instead and the landing pulls back under you on its own."
    )

    static let verticalOscillation = MetricGuideEntry(
        title: "Vertical oscillation",
        what: "How much your body bounces up and down each step, measured as a percent of your height.",
        why: "Bounce is energy spent going up instead of forward. At the same pace, less bounce means cheaper running and less impact to absorb on each landing.",
        target: "Under 6 percent reads as efficient. 6 to 10 is common. Above 10 usually travels with overstriding.",
        fix: "Think flat and forward, not up. Quicker steps with a slight whole body lean trim bounce without shrinking your stride power."
    )

    static let groundContact = MetricGuideEntry(
        title: "Ground contact",
        what: "How long each foot stays on the ground per step, in milliseconds, read from your video frame by frame.",
        why: "Ground time is where speed happens. Fast runners put big force into the ground in a short window and get back in the air. Long contacts usually mean the foot landed out front and spent time braking before it could push.",
        target: "Contact time depends on pace. Trained runners sit near 200 to 240 ms; up to about 320 ms is normal at easy paces. Elite sprinters at top speed touch down for under 100 ms with about four times body weight of force.",
        fix: "Lift your cadence and land under your hips, that trims contact time fastest. Hops, skips and jump work build the leg spring that makes short contacts possible. Expect months, not days."
    )

    static let drive = MetricGuideEntry(
        title: "Drive",
        what: "Your power score from 0 to 100. It reads how much forward push each stride produces for your size, using stride length, contact time and speed from the video.",
        why: "Drive is what actually moves you. At the same effort, runners differ mostly in how much of each step goes into pushing the ground back instead of bouncing up or braking.",
        target: "70 and up reads as a strong, springy stride. Easy jogs score lower by design, so judge it on harder runs.",
        fix: "Build the spring with hops, skips and hill strides. Then lift cadence so your foot lands under you and the push goes forward."
    )

    static let impact = MetricGuideEntry(
        title: "Impact",
        what: "Your landing score from 0 to 100. Higher means softer: less shock per step, read from how hard and how far out front your foot comes down.",
        why: "Every step sends a shock up your shins and knees. Landing shock is the strongest link between form and overuse injury, so softer is safer.",
        target: "80 and up is a quiet, soft landing. Under 60 usually travels with overstriding or slow turnover.",
        fix: "Quick, light steps under your hips. Cue quiet feet on easy runs, picture running over eggshells. The Cadence bump drill fixes most hard landings on its own."
    )

    static let smooth = MetricGuideEntry(
        title: "Smooth",
        what: "Your efficiency score from 0 to 100: how little energy you waste on bounce, braking and wobble.",
        why: "Smooth running is cheap running. The less you bounce and brake, the more of your fitness shows up as pace instead of fatigue.",
        target: "75 and up reads as an economical stride. It climbs on its own as cadence and landing improve.",
        fix: "Do not chase it directly. Fix the worst cue on your focus list, run tall, and smooth follows."
    )

    static let pronation = MetricGuideEntry(
        title: "Pronation",
        what: "How much your foot rolls inward after it lands, read from where your sole is worn.",
        why: "Some inward roll is normal shock absorption, every foot does it. A strong roll paired with a dropping hip can feed pain at the knee and shin over time.",
        target: "Neutral or a mild roll needs nothing. It is only worth attention when wear runs along the inside edge and your video shows hip drop too.",
        fix: "Fix it from the top down, not the shoe rack. Single leg bridges and lateral band walks build the hip control that steadies the roll. Pick shoes by comfort."
    )

    static let wearSymmetry = MetricGuideEntry(
        title: "Symmetry",
        what: "How closely your left and right soles wear the same, as a percent. 100 means both feet load alike.",
        why: "No one is perfectly even. A big gap means one leg is doing extra work every step, and that is the usual path into one sided overuse injuries.",
        target: "90 percent and up is normal. Below 85 on flat easy running is worth a look, especially if one side has a history.",
        fix: "Check the FOCUS list for one sided findings, then run the single leg drills on the weaker side. Rescan in a month to see the gap close."
    )
}

// MARK: - Shared guide sheet

/// The tap through explanation sheet used anywhere a metric is shown.
/// Four short sections: what, why, target, fix.
struct MetricGuideSheet: View {
    let entry: MetricGuideEntry
    var accent: Color = AppTheme.accentColor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AppTheme.bgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Text(entry.title.uppercased())
                            .font(AppTheme.head(20))
                            .foregroundColor(AppTheme.primaryText)
                        Spacer()
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark")
                                .font(AppTheme.meta(13))
                                .foregroundColor(AppTheme.primaryText.opacity(0.6))
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(AppTheme.primaryText.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 20)

                    guideSection("WHAT IT IS", entry.what, labelColor: AppTheme.primaryText.opacity(0.35))
                    guideSection("WHY IT MATTERS", entry.why, labelColor: AppTheme.primaryText.opacity(0.35))
                    guideSection("TARGET", entry.target, labelColor: AppTheme.primaryText.opacity(0.35))
                    guideSection("FIX IT WITH FORM", entry.fix, labelColor: accent)

                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 20)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppTheme.bgColor)
    }

    private func guideSection(_ label: String, _ body: String, labelColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(AppTheme.meta(10))
                .tracking(1.5)
                .foregroundColor(labelColor)
            Text(body)
                .font(AppTheme.body(14))
                .foregroundColor(AppTheme.primaryText.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
