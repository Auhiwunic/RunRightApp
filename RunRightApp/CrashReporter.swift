//
//  CrashReporter.swift
//  RunRightApp
//
//  Thin wrapper over Firebase Crashlytics. Crashlytics auto-initializes after
//  FirebaseApp.configure(), so there is nothing to start here — this just
//  centralizes non-fatal logging + a DEBUG self-test, and keeps the Crashlytics
//  import in one place so call sites don't couple to the SDK.
//

import Foundation
import FirebaseCrashlytics

enum CrashReporter {

    /// Breadcrumb attached to the next crash/non-fatal report.
    static func log(_ message: String) {
        Crashlytics.crashlytics().log(message)
    }

    /// Tie reports to the signed-in user (call on auth state change; pass "" to clear).
    static func setUserID(_ id: String) {
        Crashlytics.crashlytics().setUserID(id)
    }

    static func setValue(_ value: Any, forKey key: String) {
        Crashlytics.crashlytics().setCustomValue(value, forKey: key)
    }

    /// Record a CAUGHT error as a non-fatal so it surfaces in the dashboard
    /// without crashing. Use in catch blocks on the analysis / coach / StoreKit
    /// / HealthKit paths — the exact failure modes reviewers and users hit.
    static func record(_ error: Error, context: String? = nil) {
        if let context { Crashlytics.crashlytics().log("error[\(context)]: \(error.localizedDescription)") }
        Crashlytics.crashlytics().record(error: error)
    }

    #if DEBUG
    /// Force a crash to verify end-to-end reporting (symbolication, dSYM upload).
    /// DEBUG only so it can never ship. Wire to a hidden Profile/Settings gesture
    /// when validating a TestFlight build.
    static func testCrash() -> Never { fatalError("Crashlytics test crash") }
    #endif
}
