//
//  UsageLimits.swift
//  RunRightApp
//
//  Free-tier monthly allowances. Gate by what costs us money (OpenAI-backed shoe
//  scans and coach chat), never by what users value. Form analysis is on-device
//  and unlimited; history is free. Counters live in UserDefaults and roll over
//  automatically at the start of each calendar month. Premium bypasses all of
//  this (checked at the call site via SubscriptionManager.isPremium).
//

import Foundation

@MainActor
final class UsageLimits: ObservableObject {
    static let shared = UsageLimits()

    /// Free allowances per calendar month.
    static let freeScansPerMonth = 5
    static let freeCoachMessagesPerMonth = 5

    @Published private(set) var scansUsed = 0
    @Published private(set) var coachMessagesUsed = 0

    private let periodKey = "usage.period.v1"     // "yyyy-MM" of the counted period
    private let scanKey   = "usage.scans.v1"
    private let coachKey  = "usage.coach.v1"
    private let defaults = UserDefaults.standard

    private init() {
        rolloverIfNeeded()
        scansUsed = defaults.integer(forKey: scanKey)
        coachMessagesUsed = defaults.integer(forKey: coachKey)
    }

    // MARK: - Remaining / gates

    var scansRemaining: Int { max(0, Self.freeScansPerMonth - scansUsed) }
    var coachMessagesRemaining: Int { max(0, Self.freeCoachMessagesPerMonth - coachMessagesUsed) }

    /// Whether the user may start a shoe scan right now.
    func canScan(isPremium: Bool) -> Bool { isPremium || scansRemaining > 0 }
    /// Whether the user may send a coach message right now.
    func canSendCoachMessage(isPremium: Bool) -> Bool { isPremium || coachMessagesRemaining > 0 }

    // MARK: - Record usage (call only for non-premium users)

    /// Count a completed shoe scan against the free allowance.
    func recordScan() {
        rolloverIfNeeded()
        scansUsed += 1
        defaults.set(scansUsed, forKey: scanKey)
    }

    /// Count a sent coach message against the free allowance.
    func recordCoachMessage() {
        rolloverIfNeeded()
        coachMessagesUsed += 1
        defaults.set(coachMessagesUsed, forKey: coachKey)
    }

    // MARK: - Monthly rollover

    private func currentPeriod() -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: Date())
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// Reset the counters when the calendar month changes.
    private func rolloverIfNeeded() {
        let now = currentPeriod()
        let stored = defaults.string(forKey: periodKey)
        if stored != now {
            defaults.set(now, forKey: periodKey)
            defaults.set(0, forKey: scanKey)
            defaults.set(0, forKey: coachKey)
            scansUsed = 0
            coachMessagesUsed = 0
        }
    }
}
