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

    private let green = Color(hex: "#00FF7F")

    private let perks: [(icon: String, text: String)] = [
        ("bubble.left.fill", "AI coach chat and drills"),
        ("shoeprints.fill", "Shoe gait scan"),
        ("clock.arrow.circlepath", "Full analysis history")
    ]

    var body: some View {
        ZStack {
            Color(hex: "#1A1A1C").ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("GAITA PREMIUM")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(green)
                        Text("Coach yourself to better form")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundColor(.white)
                        Text("Form analysis stays free forever. Premium unlocks the coaching around it.")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 24)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(perks, id: \.text) { perk in
                            HStack(spacing: 12) {
                                Image(systemName: perk.icon)
                                    .font(.system(size: 15, weight: .bold)).foregroundColor(green).frame(width: 24)
                                Text(perk.text).font(.system(size: 15, weight: .medium)).foregroundColor(.white)
                                Spacer()
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(green)
                            }
                        }
                    }
                    .padding(16)
                    .background(Color(hex: "#2A2A2E"))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    planRow(id: PremiumProduct.annual, title: "Annual", fallbackPrice: "$59.99", period: "year", badge: "BEST VALUE")
                    planRow(id: PremiumProduct.monthly, title: "Monthly", fallbackPrice: "$7.99", period: "month", badge: nil)

                    Button(action: subscribe) {
                        Text(purchasing ? "…" : "Start Premium")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(green)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .disabled(purchasing)

                    HStack {
                        Button("Restore") { Task { await subs.restore(); if subs.isPremium { dismiss() } } }
                            .font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.5))
                        Spacer()
                        Text("Cancel anytime").font(.system(size: 12)).foregroundColor(.white.opacity(0.35))
                    }

                    #if DEBUG
                    Button(action: { subs.debugUnlocked = true; dismiss() }) {
                        Text("Simulate purchase (debug)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.4))
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
        .presentationBackground(Color(hex: "#1A1A1C"))
        .task { await subs.loadProducts() }
    }

    private func planRow(id: String, title: String, fallbackPrice: String, period: String, badge: String?) -> some View {
        let price = subs.product(for: id)?.displayPrice ?? fallbackPrice
        let selected = selectedID == id
        return Button(action: { selectedID = id }) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18)).foregroundColor(selected ? green : .white.opacity(0.3))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                        if let badge {
                            Text(badge).font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(.black).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(green).clipShape(Capsule())
                        }
                    }
                    Text("\(price) / \(period)").font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
                }
                Spacer()
            }
            .padding(16)
            .background(Color(hex: "#2A2A2E"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
