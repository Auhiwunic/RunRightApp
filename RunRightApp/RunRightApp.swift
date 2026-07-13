//
//  RunRightApp.swift
//  RunRightApp
//

import SwiftUI
import FirebaseAppCheck
import FirebaseCore
import FirebaseFirestore
import GoogleSignIn

/// App Check factory backed by App Attest. FirebaseAppCheck ships a
/// `DeviceCheckProviderFactory` but NOT an App Attest one, so we wrap
/// `AppAttestProvider` ourselves. Register the iOS app with **App Attest** in
/// Firebase console → App Check to match this.
private final class AppAttestProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        AppAttestProvider(app: app)
    }
}

@main
struct RunRightApp: App {
    /// "dark" (default) or "light" — the white mode toggle lives in Profile.
    @AppStorage("gaita.appearance") private var appearance = "dark"

    init() {
        // App Check provider MUST match what's registered in the Firebase
        // console, or every enforceAppCheck function call fails in production
        // (the simulator's debug provider hides this). We use App Attest
        // (iOS 14+, Apple/Firebase-recommended for new apps) — so register the
        // iOS app with App Attest in Firebase console → App Check.
        #if DEBUG
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
        AppCheck.setAppCheckProviderFactory(AppAttestProviderFactory())
        #endif
        FirebaseApp.configure()

        // Enable Firestore offline persistence so the app works without internet
        let settings = Firestore.firestore().settings
        settings.isPersistenceEnabled = true
        settings.cacheSizeBytes = 100 * 1024 * 1024 // 100 MB cache
        Firestore.firestore().settings = settings
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Fetch backend kill-switches (coach/scan/force-update). Bundled
                // defaults already apply, so this only ever loosens or tightens.
                .task { RemoteConfigManager.shared.start() }
                // DEBUG headless backtest (GAITA_BACKTEST=1) — no-op otherwise.
                .task {
                    #if DEBUG
                    BacktestRunner.runIfNeeded()
                    #endif
                }
                // Pins system chrome (status bar, sheets, alerts, keyboard) to
                // the chosen appearance; AppTheme colors resolve off this trait.
                .preferredColorScheme(appearance == "light" ? .light : .dark)
                // Dynamic Type: the font tokens scale via `relativeTo:`, capped
                // here so low-vision users get a large enlargement without the
                // dense numeric dashboards overflowing their fixed frames.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .onOpenURL { url in
                    // Required for Google Sign In to complete its OAuth flow
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
