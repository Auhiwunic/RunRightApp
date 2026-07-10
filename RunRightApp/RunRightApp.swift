//
//  RunRightApp.swift
//  RunRightApp
//

import SwiftUI
import FirebaseAppCheck
import FirebaseCore
import FirebaseFirestore
import GoogleSignIn

@main
struct RunRightApp: App {
    /// "dark" (default) or "light" — the white mode toggle lives in Profile.
    @AppStorage("gaita.appearance") private var appearance = "dark"

    init() {
        #if DEBUG
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
        AppCheck.setAppCheckProviderFactory(DeviceCheckProviderFactory())
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
