//
//  PaywallView.swift
//  RunRightApp
//
//  On-brand paywall. Free forever: on-device form analysis + basic tracking +
//  share card. Premium unlocks the coach, shoe scan, run analysis, full history.
//

import SwiftUI
import StoreKit

struct PaywallView: View {
    @ObservedObject private var subs = SubscriptionManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID = PremiumProduct.annual
    @State private var purchasing = false
    @State private var legalDoc: LegalDoc?

    private let green = Color(hex: "#00FF7F")

    private let perks: [(icon: String, text: String)] = [
        ("bubble.left.fill", "AI coach chat and drills"),
        ("waveform", "Voice chats in the coach's own voice"),
        ("shoeprints.fill", "Shoe gait scan"),
        ("clock.arrow.circlepath", "Full analysis history")
    ]

    var body: some View {
        ZStack {
            AppTheme.bgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("GAITA PREMIUM")
                            .font(AppTheme.head(13))
                            .foregroundColor(green)
                        Text("Coach yourself to better form")
                            .font(AppTheme.display(26))
                            .foregroundColor(AppTheme.primaryText)
                        Text("Form analysis stays free forever. Premium unlocks the coaching around it.")
                            .font(AppTheme.body(13))
                            .foregroundColor(AppTheme.primaryText.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 24)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(perks, id: \.text) { perk in
                            HStack(spacing: 12) {
                                Image(systemName: perk.icon)
                                    .font(AppTheme.head(15)).foregroundColor(green).frame(width: 24)
                                Text(perk.text).font(AppTheme.bodyMedium(15)).foregroundColor(AppTheme.primaryText)
                                Spacer()
                                Image(systemName: "checkmark").font(AppTheme.meta(12)).foregroundColor(green)
                            }
                        }
                    }
                    .padding(16)
                    .appRaisedSurface(fill: AppTheme.cardBg, cornerRadius: 18, shadowRadius: 9, x: 5, y: 5)

                    planRow(id: PremiumProduct.annual, title: "Annual", fallbackPrice: "$59.99", period: "year", badge: "BEST VALUE")
                    planRow(id: PremiumProduct.monthly, title: "Monthly", fallbackPrice: "$7.99", period: "month", badge: nil)

                    let selectedProduct = subs.product(for: selectedID)

                    Button(action: subscribe) {
                        Text(purchasing ? "…" : selectedProduct == nil ? "Loading prices…" : "Start Premium")
                            .font(AppTheme.head(16))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(green.opacity(selectedProduct == nil ? 0.45 : 1))
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .disabled(purchasing || selectedProduct == nil)

                    HStack {
                        Button("Restore Purchases") { Task { await subs.restore(); if subs.isPremium { dismiss() } } }
                            .font(AppTheme.bodyMedium(12)).foregroundColor(AppTheme.primaryText.opacity(0.5))
                        Spacer()
                        Text("Cancel anytime").font(AppTheme.body(12)).foregroundColor(AppTheme.primaryText.opacity(0.35))
                    }

                    // 3.1.2: auto-renewal must be disclosed and the Terms and
                    // Privacy Policy must be reachable from the paywall.
                    Text("The subscription renews automatically at \(selectedProduct?.displayPrice ?? "the shown price") per \(selectedID == PremiumProduct.annual ? "year" : "month") until canceled. Cancel anytime in your App Store account settings at least 24 hours before the period ends.")
                        .font(AppTheme.body(10))
                        .foregroundColor(AppTheme.primaryText.opacity(0.35))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 14) {
                        Button("Terms & Conditions") { legalDoc = .terms }
                            .font(AppTheme.bodyMedium(10))
                            .foregroundColor(AppTheme.primaryText.opacity(0.5))
                        Button("Privacy Policy") { legalDoc = .privacyPolicy }
                            .font(AppTheme.bodyMedium(10))
                            .foregroundColor(AppTheme.primaryText.opacity(0.5))
                    }

                    #if DEBUG
                    Button(action: { subs.debugUnlocked = true; dismiss() }) {
                        Text("Simulate purchase (debug)")
                            .font(AppTheme.meta(11))
                            .foregroundColor(AppTheme.primaryText.opacity(0.4))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                    }
                    #endif

                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 20)
            }
        }
        .presentationDragIndicator(.visible)
        .presentationBackground(AppTheme.bgColor)
        .sheet(item: $legalDoc) { doc in
            LegalDocView(doc: doc)
        }
        .task { await subs.loadProducts() }
    }

    private func planRow(id: String, title: String, fallbackPrice: String, period: String, badge: String?) -> some View {
        let price = subs.product(for: id)?.displayPrice ?? fallbackPrice
        let selected = selectedID == id
        return Button(action: { selectedID = id }) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(AppTheme.body(18)).foregroundColor(selected ? green : AppTheme.primaryText.opacity(0.3))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(AppTheme.head(15)).foregroundColor(AppTheme.primaryText)
                        if let badge {
                            Text(badge).font(AppTheme.meta(8))
                                .foregroundColor(.black).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(green).clipShape(Capsule())
                        }
                    }
                    Text("\(price) / \(period)").font(AppTheme.body(12)).foregroundColor(AppTheme.primaryText.opacity(0.5))
                }
                Spacer()
            }
            .padding(16)
            .appRaisedSurface(fill: selected ? AppTheme.raisedFill : AppTheme.cardBg, cornerRadius: 16, shadowRadius: 9, x: 5, y: 5)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(selected ? green : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private func subscribe() {
        guard let product = subs.product(for: selectedID) else { return }
        purchasing = true
        Task {
            let ok = await subs.purchase(product)
            purchasing = false
            if ok { dismiss() }
        }
    }
}
