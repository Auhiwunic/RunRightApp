# Gaita — improvement work order

Audit of the current build (multi-agent, findings verified against code). Ordered by impact.
Free on-device form analysis works well; the paid surfaces (Coach, Scan) depend on backends that are not deployed, the paywall sells two features that do not exist, and there are real cross-account data-bleed/privacy bugs. Plenty of dead code from the redesigns, and one one-line change roughly halves the analysis time.

---

## Fix (bugs, correctness, release blockers)

### High
1. **Cadence reported at 2x mismatch** — `RunningFormMetrics.swift:341` (+ consumers `AnalyzeView.swift:790,806`, `CoachChat.swift:78`). `metrics.cadence` is single-foot steps/min (~124) but is scored against both-feet ranges (165–190) and the Analyze headline reports both-feet (~204). Pick both-feet SPM as canonical: `return meanStep > 0 ? (60/meanStep)*2 : 0`, fix the 120–230 reject band, and route headline/scorecard/CSV/coach through the one value.
2. **Local data bleeds across accounts** — `FirebaseAuthManager.signOut()`. Sign-out never clears local state, and `ScorecardDataStore`/`AnalysisHistoryStore` keys are device-global. User B sees user A's scorecard, RECENT, Coach TODAY, CSVs. Call `clearLocalData()` (+ form_exports) in `signOut()`, or namespace keys by uid.
3. **Guest data orphaned on sign-in** — `FirebaseAuthManager.signInOrLink()` `credentialAlreadyInUse` branch. Guest scans/runs (written under the anon uid) silently vanish when linking to an existing account. Migrate the anon uid subcollections or warn the user; clean up the dangling anon auth record.
4. **Raw biometric CSVs leak + survive account deletion** — `AnalyzeView.swift` (`AnalysisHistoryStore.add` line 54, `persistRawDataCSV`/`csvFileURL` 492–513) + `FirebaseAuthManager.clearLocalData()`. Files in `Documents/form_exports` are never pruned with the 20-record cap and are not deleted on account deletion (App Store 5.1.1(v)). Prune orphans on eviction; delete form_exports in `clearLocalData()`.
5. **Permission prompts still say "Corsa"** — `Info.plist:31–45` (all seven `NS*UsageDescription`) + `PrivacyInfo.xcprivacy`. App ships as Gaita. Replace "Corsa" → "Gaita".
6. **Coach + Scan backends not deployed** — `Info.plist:50,55` (`analyzeShoe`, `coachChat`). Both paid features error out at launch. Deploy both Cloud Functions (OpenAI key server-side, Auth-verified), smoke-test with a signed-in user, and don't ship the paywall gating until they return 200.
7. **StoreKit products don't exist** — `Subscriptions.swift:16–17`. `com.runright.premium.{monthly,annual}` have no App Store Connect products and no `.storekit` file, so purchases fail. Create the two auto-renewable subs + a `Products.storekit`.
8. **Legal docs still branded Corsa** — everything under `legal/`. Rewrite to Gaita and run a fresh trademark knockout for Gaita (see Improve). App Store links a mismatched Privacy Policy today.
9. **Scan sheet can trap the user** — `ScanView.swift` (presented at `AnalyzeView.swift:153`). No dismiss/X, no drag indicator, swipe fights the ScrollView. Add `@Environment(\.dismiss)` + an X in `scanHeader`, and `.presentationDragIndicator(.visible)` on the sheet.
10. **Paywall sells "Run analysis" — not built** — `PaywallView.swift:23`. No run analyzer exists. Build the post-run breakdown or remove the perk until it ships.
11. **Paywall sells "Full analysis history" — not built/gated** — `PaywallView.swift:24`, `AnalyzeView.swift:50,472`. Everyone gets `prefix(3)` and a 20-cap; no "See all". Build a premium-gated full-history screen or remove the perk.

### Medium
12. **`Int(NaN/Inf)` crash risk** — `AnalyzeView.swift:543,548,797`. `Int(Double)` traps on non-finite. Add `isFinite` guards / a `safeInt(_:)` helper at every `Int(x.rounded())` over computed doubles.
13. **Mile-split loop under-counts** — `ActiveRunView.swift:622–630`. A GPS jump across >1 mile records one split. Change `if` → `while currentMiles >= Double(mileSplits.count + 1)`.
14. **Stale opposite-side wear zones fused into a new shoe** — `ScanView.swift:382`, consumed `FormGaitCrossReference.swift:97`. Scanning only the left of a new pair fuses the old right. Key wear zones (and the gait image) by scan session, or clear the opposite side on a new single-side scan.
15. **CSV written to the wrong record when `add()` skips** — `AnalyzeView.swift:136–148`. When `history.add()` returns early, `records.first` is the previous run and its CSV gets overwritten. Have `add()` return the inserted id and only persist for that id.
16. **Retired Analyze purple still ships** — `DrillsLibrary.swift:29,32,35` (three hip drills), `ShareCardView.swift:260` (SMOOTH dial on the share card), `HomeView.swift:16` (dead `accentPurple`). Repoint `#6B63FF` to the brand palette; delete the dead constant.

### Low
17. **Stale tab comment** — `MainTabView.swift:108` says "Scan" for the Coach slot. Fix comment.
18. **Em/en-dashes in user copy** — `ScanView.swift:526`, `OnboardingView.swift:128`, chart titles `AnalyzeView.swift:2414/2427/2440`, `RunningPowerModel.swift:217/300`. Replace sentence dashes per the no-dash rule.

---

## Improve (UX, quality, features)

- **Coach chat isn't grounded in cueScores** — `CoachChat.swift:74` `groundingContext()`. TODAY cards use `storedInsights()` but the backend context omits `cueScores`/FOCUS, so the chat coach can't reference the same priorities. Add them. *(medium)*
- **No accessibility** — app-wide: zero `accessibilityLabel`, 588 fixed `.system(size:)` fonts. Icon-only buttons (Coach send, tabs, share) are unlabeled; text ignores Dynamic Type. Label icon buttons + adopt scalable fonts on reading surfaces. *(medium)*
- **Tab contrast fails WCAG** — `MainTabView.swift:156,165`. Unselected items at `white.opacity(0.38)` (~2:1). Raise to ~0.58. *(medium)*
- **Firebase API key unrestricted** — `GoogleService-Info.plist`. Not a "secret" but must be locked: restrict the iOS key to the bundle id in GCP, and confirm Firestore/Storage rules require auth + user-scoping. *(medium)*
- **No Gaita trademark clearance** — `legal/`. The whole reason Corsa was dropped. Knockout search classes 9/41/42 before listing; capture in `legal/TRADEMARK_MEMO_GAITA.md`. *(medium)*
- **No cloud backup of form state** — `ShareCardView.swift` store + `AnalyzeView.swift:44`. Scorecard/history/cueScores/CSVs are local only; a signed-in user loses them on reinstall while runs/scans survive. Mirror to `users/{uid}` and restore on sign-in. *(low)*
- **Silent write failures** — `ShareCardView.swift:145` (`save` swallows encode errors), `ScanView.swift:323,400,406` (`try?` discards upload results). do/catch + surface via existing error plumbing. *(low)*
- **Offline vs "not deployed" conflated** — `CoachChat.swift`/`OpenAIService`. Catch `URLError.notConnectedToInternet` and show a distinct "You're offline / retry". *(low)*
- **Starter-prompt grammar** — `CoachChat.swift:102` "How was my last run coach?" → "How was my last run?". *(low)*
- **DEBUG premium unlock is sticky** — `Subscriptions.swift:31–36`. Persisted in UserDefaults, can't be reset from UI, so gating can't be re-tested. Make it non-persistent + add a reset. *(low)*
- **Bundle id / ids still `com.runright` / project `corsa-51d8f`** — decide before first submission (bundle id is permanent once published). *(low)*

---

## Optimize (performance, dead code)

### Performance
- **`CIContext()` built per video frame** — `VideoProcessor.swift:1708` (called per frame from the loop at 1632). This is the single biggest cost in the ~5-min analysis (hundreds of GPU-pipeline setups). Hoist to one reused `private let ciContext = CIContext()`. **Highest-ROI change in the app.** *(high)*
- **Full-frame CI render + fresh CVPixelBuffer every frame** — `VideoProcessor.swift:1692–1768`. Use a `CVPixelBufferPool` and skip the Core Image copy (the skeleton is a few lines) — draw on the reused `CGContext`. *(medium)*
- **FOCUS insights recomputed every render** — `AnalyzeView.swift:277–309`. `analyzeFormReport` sorts cues, does 4 UserDefaults reads, and allocates `CombinedInsight`s with fresh UUIDs on every `body` pass (also breaks `ForEach` diffing). Compute once in the `processedVideoURL` onChange into `@State`; give `CombinedInsight` a stable id. *(medium)*
- **Scorecard export blocks main thread** — `ShareCardView.swift:593`. `ImageRenderer` at scale 3 → PNG encode + disk write, all on the main actor. Move encode/write off-main; consider scale 2. *(medium)*
- **Per-frame await/Task.yield** — `VideoProcessor.swift:1645–1650`. Throttle before awaiting. *(low)*

### Dead code — delete
- `StravaService.swift` (dead OAuth client + `StravaConnectSheet`, unreferenced; also removes a dormant credential surface). *(medium)*
- `ShoeScannerView.swift` (orphaned older scan flow, duplicates ScanView). *(medium)*
- `ScanResultsView.swift` (only used by its own `#Preview`; fix the misleading "used by ScanResultsView" comments in `ScanView.swift:1241,1254`). *(medium)*
- `HomeView.swift:476 heartRateZonesCard` + `:568 zoneBar` (dead after HR zones moved to Run). *(low)*
- `ActivityTrackerView.swift` and `VideoSkeletonView.swift` (orphaned; note `PoseDetection.swift` is NOT dead — used by VideoProcessor). *(low)*

---

## Quick wins (small, high value)
- Hoist `CIContext` (one line, ~halves analysis time).
- Info.plist "Corsa" → "Gaita" (7 strings).
- Delete the 5 dead files above.
- Tab contrast 0.38 → 0.58.
- Remove the two unbuilt paywall perks (or build them) so you're not charging for vaporware.
- `MainTabView.swift:108` comment + `CoachChat.swift:102` grammar.
- Add `isFinite` guard helper for the `Int()` crash sites.
