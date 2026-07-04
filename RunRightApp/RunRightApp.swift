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
                // Every screen is styled dark; without this, system chrome
                // (status bar, sheets, alerts, keyboard) rendered light-mode.
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // Required for Google Sign In to complete its OAuth flow
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
