# Apple Review Bulletproof Audit — 2026-07-10

Exhaustive App Store review + security audit: every source file (95 Swift + backend + config)
reviewed by a fleet of agents against Apple's rejection triggers AND security vulns, each finding
then adversarially verified. **40 confirmed findings: 3 blockers, 10 should-fix, 22 nits.**

## Blockers — FIXED ✅
1. **Release build would not compile** — `AppAttestProviderFactory` isn't a type in FirebaseAppCheck
   (my earlier launch-prep edit introduced this; DEBUG hid it because the `#else` branch isn't
   compiled there). Fixed: defined a custom `AppAttestProviderFactory: AppCheckProviderFactory`
   wrapping `AppAttestProvider(app:)` in `RunRightApp.swift`. → Register **App Attest** in Firebase console.
2. **Crashlytics Crash Data undeclared** (5.1.2) — Crashlytics ships + `setUserID` links crash data to
   the uid, but `PrivacyInfo.xcprivacy` omitted it. Fixed: added `CrashData` + `OtherDiagnosticData`
   (linked, no tracking). → Also tick **Crash Data + Diagnostics** in ASC App Privacy (LAUNCH_DAY step 7).
3. **Wake-word mic could record in background** (5.1.1) — `HeyGaitaListener`'s `.onDisappear` doesn't
   fire on lock, so the mic tap could keep running under the `audio` background mode. Fixed:
   `ActiveRunView` now tears the listener down on `scenePhase == .background`, restarts on `.active`.

## Should-fix — FIXED ✅
- **Free-scan paywall not enforced** (3.1.1) — `ScanView.runScan` now checks `canScan` before the paid
  backend, so free users can't exceed the monthly allowance across shoes/re-scans.
- **Raw backend/OpenAI error strings leaked** (info disclosure) — sanitized in three layers:
  `functions/index.js` (both `OpenAI error:` forwards + the two 500 catch-alls now log server-side and
  return generic text) and `ScanView.friendlyError` (never surfaces raw text; maps to plain messages).
  → **Requires `firebase deploy --only functions`** (LAUNCH_DAY step 4).
- **Background location always enabled** (5.1.1) — `ActivityTracker` now enables
  `allowsBackgroundLocationUpdates` only while a run is active (on in `startTracking`, off in `stopTracking`).
- **Malformed/DRM video showed raw AVFoundation error** (2.3.10) — `VideoProcessor` now shows an
  actionable message, logs the detail.
- **Coach could mutate the WRONG day from a hallucinated LLM day string** (2.1) — `resolveDayIndex`
  returns `nil` on an unrecognized day instead of silently defaulting to tomorrow.

## Should-fix — REMAINING (recommend before submit; low reviewer-hit risk)
- **PaywallView:99** auto-renew disclosure falls back to "the shown price" if StoreKit products fail to
  load; **PaywallView:91** Restore Purchases gives no feedback when there's nothing to restore. (3.1.2/3.1.1)
- **OnboardingView:94** onboarding answers not persisted to Firestore if anonymous sign-in failed (no uid). (2.1)
- **RunView:1682** diagnostic time-trial advances even when Location is denied — dead-ends silently. (2.1)
- **ShoeCameraView:167** photo-library load failure is swallowed — picker can appear dead on a bad asset. (2.1)

## Nits (22) — optional polish, none are rejections
Ship-hygiene: archive must use **Release** config (excludes DEBUG premium bypass + BacktestRunner);
delete dead code (`RunningFormMetrics` ~500 lines w/ latent range crash, retired OpenAIService prose,
`SampleRuns` demo data); one release `print()` in ShareCardView → debugLog; update `corsa-51d8f`
fallback strings to the Gaita project. Robustness: guard a handful of force-unwrapped date/range
computations; `UIScreen.main.bounds` deprecated on iOS 26; HealthKit `savedAny=true` even on write
failure; `displayName commitChanges(nil)` swallows errors. (Full list in the workflow output.)

## Verified GOOD (no action)
Sign in with Apple present (4.8); in-app account deletion with reauth (5.1.1(v)); Restore Purchases
present; all permission purpose strings specific + truthful; `audio`+`location` background modes both
backed by real features; no ATS exceptions; no hardcoded secrets (Firebase client key is meant to ship);
PII kept behind `debugLog`; App Check enforced on both functions; SSRF allow-list on image URLs.
