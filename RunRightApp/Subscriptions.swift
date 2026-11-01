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
import FirebaseAuth

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

    /// Fixed App Review account. Signing in as this user unlocks premium in ANY
    /// build (including Release) so App Review can verify the gated features
    /// (coach, scan) without a StoreKit purchase. Create it once via "Sign up
    /// with email" and put the credentials in App Store Connect → App Review
    /// Information. It is safe: once the account exists the email is claimed, so
    /// no other user can register it, and the password lives only in the review
    /// notes. Not a general entitlement path — only this one exact address.
    static let reviewEmail = "appreview@gaita.app"

    #if DEBUG
    /// Testing-only unlock so the gated → unlocked flow can be exercised without a
    /// store. Persisted (DEBUG builds only) so it survives relaunch — flip it once
    /// and premium stays on until you turn it off. Compiled out of Release.
    static let debugKey = "debug.premiumUnlocked"
    @Published var debugUnlocked: Bool = UserDefaults.standard.bool(forKey: SubscriptionManager.debugKey) {
        didSet {
            UserDefaults.standard.set(debugUnlocked, forKey: Self.debugKey)
            recompute()
        }
    }
    #endif

    private var updatesTask: Task<Void, Never>?
    private var authHandle: AuthStateDidChangeListenerHandle?

    private init() {
        recompute()
        // Re-evaluate entitlement whenever the signed-in user changes, so the
        // review demo account flips premium on the instant it signs in (and a
        // sign-out drops it again). Fires immediately with the current user too.
        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, _ in
            Task { @MainActor in self?.recompute() }
        }
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { continue }
                if case .verified(let t) = update {
                    await t.finish()
                    await self.updateEntitlements()
                }
            }
        }
        // At launch we only need the local entitlement check (gates premium
        // features). The StoreKit product listing is a network call that is only
        // used by the paywall, which loads it itself on appear — so don't pay
        // that cost on every app open.
        Task { await updateEntitlements() }
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

    /// Outcome of a purchase attempt, so the paywall can distinguish a completed
    /// buy from a pending (Ask-to-Buy / SCA) approval, a cancel, or a failure.
    enum PurchaseOutcome {
        case success
        case pending
        case cancelled
        case failed
    }

    @discardableResult
    func purchase(_ product: Product) async -> PurchaseOutcome {
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let t) = verification {
                    await t.finish()
                    await updateEntitlements()
                    return .success
                }
                return .failed
            case .pending:
                // Ask-to-Buy (Family Sharing) or SCA: the buy isn't done yet but
                // isn't a failure. The Transaction.updates listener applies it once
                // approved; the caller just needs to explain the wait.
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .failed
            }
        } catch {
            return .failed
        }
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
        // App Review demo account unlocks premium in every build so reviewers can
        // reach the gated features without a sandbox purchase.
        if let email = Auth.auth().currentUser?.email?.lowercased(),
           email == Self.reviewEmail {
            premium = true
        }
        isPremium = premium
    }
}
