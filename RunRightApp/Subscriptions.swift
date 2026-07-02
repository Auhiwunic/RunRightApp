//
//  Subscriptions.swift
//  RunRightApp
//
//  StoreKit 2 premium entitlement. Free forever: on-device form analysis + basic
//  tracking + the share card. Premium unlocks the AI coach, shoe gait scan, run
//  analysis, and full history. Products are configured in App Store Connect (or a
//  local .storekit file for testing). A DEBUG override lets us demo the gated flow
//  without any store setup — it is compiled out of release builds.
//

import Foundation
import StoreKit

enum PremiumProduct {
    static let monthly = "com.runright.premium.monthly"
    static let annual  = "com.runright.premium.annual"
    static let all: [String] = [monthly, annual]
}

@MainActor
final class SubscriptionManager: ObservableObject {
    static let shared = SubscriptionManager()

    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasedIDs: Set<String> = []
    @Published private(set) var isPremium: Bool = false

    #if DEBUG
    /// Demo-only unlock so the gated → unlocked flow can be shown without a store.
    @Published var debugUnlocked: Bool = false {
        didSet { recompute() }
    }
    #endif

    private var updatesTask: Task<Void, Never>?

    private init() {
        recompute()
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { continue }
                if case .verified(let t) = update {
                    await t.finish()
                    await self.updateEntitlements()
                }
            }
        }
        Task { await refresh() }
    }

    func refresh() async {
        await loadProducts()
        await updateEntitlements()
    }

    func loadProducts() async {
        do {
            let items = try await Product.products(for: PremiumProduct.all)
            products = items.sorted { $0.price < $1.price }
        } catch {
            products = []
        }
    }

    func updateEntitlements() async {
        var ids: Set<String> = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.revocationDate == nil {
                ids.insert(t.productID)
            }
        }
        purchasedIDs = ids
        recompute()
    }

    /// Returns true if the purchase completed.
    @discardableResult
    func purchase(_ product: Product) async -> Bool {
        do {
            let result = try await product.purchase()
            if case .success(let verification) = result,
               case .verified(let t) = verification {
                await t.finish()
                await updateEntitlements()
                return true
            }
        } catch {
            return false
        }
        return false
    }

    func restore() async {
        try? await AppStore.sync()
        await updateEntitlements()
    }

    func product(for id: String) -> Product? {
        products.first { $0.id == id }
    }

    private func recompute() {
        var premium = !purchasedIDs.isEmpty
        #if DEBUG
        if debugUnlocked { premium = true }
        #endif
        isPremium = premium
    }
}
