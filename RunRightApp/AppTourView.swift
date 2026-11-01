//
//  AppTourView.swift
//  RunRightApp
//
//  First launch tour: five short pages on using the app correctly — how to
//  film a form video, scan shoes, run with the coach, and work the plan.
//  Shown once, right after onboarding completes, and always skippable.
//  Theme aware; two font system; single accent.
//

import SwiftUI

struct AppTourView: View {
    var onDone: () -> Void

    @State private var page = 0

    private struct TourPage {
        let icon: String?          // SF Symbol; nil = brand logo
        let title: String
        let body: String
        let checklist: [String]
    }

    private let pages: [TourPage] = [
        TourPage(
            icon: nil,
            title: "Welcome to Gaita",
            body: "Your running form coach. Two minutes to learn the ropes, or skip and explore on your own.",
            checklist: []
        ),
        TourPage(
            icon: "video.fill",
            title: "Film your form",
            body: "On the Analyze tab, record or upload a running video. Gaita scores your drive, impact, and smoothness, then tells you what to fix.",
            checklist: [
                "Film from the side, not the front",
                "Whole body in frame the entire time",
                "Ten to twenty seconds is plenty",
                "Keep the phone steady, good light helps",
            ]
        ),
        TourPage(
            icon: "shoeprints.fill",
            title: "Scan your shoes",
            body: "From Analyze, photograph the sole of each shoe. The wear pattern reveals your gait and warns you before a worn shoe causes trouble.",
            checklist: []
        ),
        TourPage(
            icon: "figure.run",
            title: "Run with your coach",
            body: "Start a run from the Run tab. Gaita calls your mile splits and only speaks up when your pace drifts far. Say Hey Gaita any time to ask for your stats hands free.",
            checklist: []
        ),
        TourPage(
            icon: "waveform",
            title: "Train the plan",
            body: "Your week lives on the Run tab and adapts when life happens. Miss a long run and it moves. Ask the coach to swap days or make tomorrow easier.",
            checklist: []
        ),
    ]

    var body: some View {
        ZStack {
            AppTheme.bgColor.ignoresSafeArea()

            VStack(spacing: 0) {
                // Skip is always one tap away, on every page.
                HStack {
                    Spacer()
                    Button(action: onDone) {
                        Text("Skip")
                            .font(AppTheme.bodySemibold(15))
                            .foregroundColor(AppTheme.secondaryText)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.top, 8)

                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { i in
                        pageView(pages[i]).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.25), value: page)

                // Dots + primary action.
                VStack(spacing: 22) {
                    HStack(spacing: 7) {
                        ForEach(pages.indices, id: \.self) { i in
                            Capsule()
                                .fill(i == page ? AppTheme.accentColor : AppTheme.primaryText.opacity(0.18))
                                .frame(width: i == page ? 20 : 7, height: 7)
                        }
                    }
                    .animation(.easeInOut(duration: 0.2), value: page)

                    Button(action: advance) {
                        Text(page == pages.count - 1 ? "Get started" : "Next")
                            .font(AppTheme.bodySemibold(17))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .background(AppTheme.accentColor)
                            .clipShape(Capsule())
                    }
                    .padding(.horizontal, 28)
                }
                .padding(.bottom, 34)
            }
        }
    }

    private func advance() {
        if page < pages.count - 1 {
            page += 1
        } else {
            onDone()
        }
    }

    @ViewBuilder
    private func pageView(_ p: TourPage) -> some View {
        VStack(spacing: 26) {
            Spacer()

            if let icon = p.icon {
                ZStack {
                    Circle()
                        .fill(AppTheme.accentColor.opacity(0.12))
                        .frame(width: 120, height: 120)
                    Image(systemName: icon)
                        .font(.system(size: 46, weight: .medium))
                        .foregroundColor(AppTheme.accentColor)
                        .accessibilityHidden(true)
                }
            } else {
                Image("GaitaLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 110, height: 110)
            }

            Text(p.title)
                .font(AppTheme.display(30))
                .foregroundColor(AppTheme.primaryText)
                .multilineTextAlignment(.center)

            Text(p.body)
                .font(AppTheme.body(16))
                .foregroundColor(AppTheme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 34)

            if !p.checklist.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(p.checklist, id: \.self) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(AppTheme.body(15))
                                .foregroundColor(AppTheme.accentColor)
                                .accessibilityHidden(true)
                            Text(item)
                                .font(AppTheme.bodyMedium(14))
                                .foregroundColor(AppTheme.primaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .appRaisedSurface(fill: AppTheme.cardBg, cornerRadius: 16)
                .padding(.horizontal, 30)
            }

            Spacer()
            Spacer()
        }
    }
}

#Preview {
    AppTourView(onDone: {})
}
