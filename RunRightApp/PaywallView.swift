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
    @State private var pendingNotice = false
    @State private var purchaseFailed = false
    @State private var restoreEmpty = false

    private let green = AppTheme.accentColor

    private let perks: [(icon: String, text: String)] = [
        ("shoeprints.fill", "Unlimited shoe scans"),
        ("bubble.left.fill", "Unlimited coach chat and drills"),
        ("waveform", "The coach speaks back, in Lewis's voice"),
        ("mic.fill", "Talk to your coach with voice messages")
    ]

    var body: some View {
        ZStack {
            AppTheme.bgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("GAITA PREMIUM")
                            .font(AppTheme.meta(12))
                            .tracking(1.4)
                            .foregroundColor(green)
                        Text("Coach yourself to better form")
                            .font(AppTheme.display(30))
                            .foregroundColor(AppTheme.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Form analysis stays free forever. Premium unlocks the coaching around it.")
                            .font(AppTheme.body(14))
                            .foregroundColor(AppTheme.primaryText.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 26)

                    // Perks as a bare, hairline-ruled editorial list — no nested card.
                    VStack(spacing: 0) {
                        ForEach(Array(perks.enumerated()), id: \.element.text) { index, perk in
                            if index > 0 {
                                Rectangle().fill(AppTheme.dividerColor).frame(height: 1)
                            }
                            HStack(spacing: 14) {
                                Image(systemName: perk.icon)
                                    .font(AppTheme.head(15)).foregroundColor(green).frame(width: 22)
                                Text(perk.text).font(AppTheme.bodyMedium(15)).foregroundColor(AppTheme.primaryText)
                                Spacer()
                            }
                            .padding(.vertical, 14)
                        }
                    }

                    VStack(spacing: 10) {
                        planRow(id: PremiumProduct.annual, title: "Annual", fallbackMonthly: "$5.00", fallbackFull: "$59.99", badge: savingsBadge)
                        planRow(id: PremiumProduct.monthly, title: "Monthly", fallbackMonthly: "$7.99", fallbackFull: nil, badge: nil)
                    }

                    let selectedProduct = subs.product(for: selectedID)

                    VStack(spacing: 8) {
                        Button(action: subscribe) {
                            Text(purchasing ? "…" : selectedProduct == nil ? "Loading prices…" : "Start Premium")
                                .font(AppTheme.head(16))
                                .foregroundColor(.black)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(green.opacity(selectedProduct == nil ? 0.45 : 1))
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .disabled(purchasing || selectedProduct == nil)

                        Text(ctaSubline)
                            .font(AppTheme.body(11))
                            .foregroundColor(AppTheme.primaryText.opacity(0.4))
                    }

                    HStack {
                        Button("Restore Purchases") { Task { await subs.restore(); if subs.isPremium { dismiss() } else { restoreEmpty = true } } }
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
        .alert("Approval pending", isPresented: $pendingNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your purchase needs approval (Ask to Buy or your bank). Premium unlocks automatically once it's approved — no need to buy again.")
        }
        .alert("Purchase failed", isPresented: $purchaseFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Something went wrong and you were not charged. Check your connection and try again.")
        }
        .alert("Nothing to restore", isPresented: $restoreEmpty) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("We couldn't find a previous subscription on this Apple ID. If you subscribed with a different Apple ID, sign in with that one and try again.")
        }
        .task { await subs.loadProducts() }
    }

    private func planRow(id: String, title: String, fallbackMonthly: String, fallbackFull: String?, badge: String?) -> some View {
        let selected = selectedID == id
        let monthly = perMonthPrice(id) ?? fallbackMonthly
        // Annual shows its real yearly charge; monthly is billed as shown.
        let subline = id == PremiumProduct.annual
            ? "\(subs.product(for: id)?.displayPrice ?? fallbackFull ?? "") billed yearly"
            : "billed monthly"
        return Button(action: { selectedID = id }) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(AppTheme.body(20)).foregroundColor(selected ? green : AppTheme.primaryText.opacity(0.3))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title).font(AppTheme.head(15)).foregroundColor(AppTheme.primaryText)
                        if let badge {
                            Text(badge).font(AppTheme.meta(8))
                                .foregroundColor(.black).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(green).clipShape(Capsule())
                        }
                    }
                    Text(subline).font(AppTheme.body(12)).foregroundColor(AppTheme.primaryText.opacity(0.45))
                }
                Spacer()
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(monthly).font(AppTheme.displayTabular(24)).foregroundColor(AppTheme.primaryText)
                    Text("/mo").font(AppTheme.meta(11)).foregroundColor(AppTheme.primaryText.opacity(0.45))
                }
            }
            .padding(16)
            .appRaisedSurface(fill: selected ? AppTheme.raisedFill : AppTheme.cardBg, cornerRadius: 16, shadowRadius: 9, x: 5, y: 5)
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(selected ? green : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    /// Per-month price for a plan. Annual divides its real price by 12 (in the
    /// product's own currency/format), so both plans compare on the same axis.
    private func perMonthPrice(_ id: String) -> String? {
        guard let p = subs.product(for: id) else { return nil }
        guard id == PremiumProduct.annual else { return p.displayPrice }
        return (p.price / 12).formatted(p.priceFormatStyle)
    }

    /// Honest savings vs paying monthly, computed from live prices. Falls back
    /// to a neutral label until StoreKit prices load.
    private var savingsBadge: String {
        if let a = subs.product(for: PremiumProduct.annual)?.price,
           let m = subs.product(for: PremiumProduct.monthly)?.price, m > 0 {
            let ratio = 1 - (a / (m * 12))
            let pct = Int((ratio as NSDecimalNumber).doubleValue * 100)
            if pct > 0 { return "SAVE \(pct)%" }
        }
        return "BEST VALUE"
    }

    private var ctaSubline: String {
        guard let p = subs.product(for: selectedID) else { return "Cancel anytime" }
        let period = selectedID == PremiumProduct.annual ? "year" : "month"
        return "\(p.displayPrice) per \(period), cancel anytime"
    }

    private func subscribe() {
        guard let product = subs.product(for: selectedID) else { return }
        purchasing = true
        Task {
            let outcome = await subs.purchase(product)
            purchasing = false
            switch outcome {
            case .success:
                dismiss()
            case .pending:
                // Don't leave an Ask-to-Buy / SCA user staring at a reverted
                // button assuming it failed — tell them approval is pending.
                pendingNotice = true
            case .cancelled:
                break   // user backed out — no message needed
            case .failed:
                purchaseFailed = true
            }
        }
    }
}
