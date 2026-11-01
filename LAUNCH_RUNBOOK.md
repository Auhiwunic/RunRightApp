# Gaita — Launch Runbook

Everything left between here and a live App Store app, in order. The code is
feature complete and building clean. What remains is account, legal, and store
work only you (the account holder) can do, plus one real device test pass.

Do them roughly top to bottom. Items marked ⛔ are hard submission blockers.

---

## 0. Decide the bundle ID (do this FIRST — it is permanent) ⛔
The app currently ships `com.runright.app` (legacy RunRight name). It becomes
**permanent** the moment you first upload to App Store Connect. Two choices:
- **Keep `com.runright.app`** — zero extra work, users never see it. Recommended.
- **Change to `com.gaita.app`** — cleaner, but means: change PRODUCT_BUNDLE_IDENTIFIER in both build configs, re-register a new iOS app in Firebase, download a fresh GoogleService-Info.plist, and update the App Check + Sign in with Apple config. More work, no user-facing benefit.

Decision: ________________  (once uploaded, you cannot change it)

---

## 1. Apple Developer Program ⛔
- Confirm the paid Apple Developer membership is active ($99/yr). You mentioned it is.
- In the Apple Developer portal → Identifiers → confirm the App ID for your chosen bundle ID exists with **HealthKit** and **Sign in with Apple** capabilities enabled. (Xcode's automatic signing usually creates this; verify it, since Sign in with Apple was the earlier signing error.)

## 2. App Store Connect: create the app record ⛔
- App Store Connect → My Apps → + → New App.
- Platform iOS, name "Gaita: Running Form Coach" (or "Gaita"), primary language, bundle ID, SKU (any internal string, e.g. `gaita-001`).

## 3. Subscription products ⛔ (the biggest blocker)
The paywall reads two product IDs from the code. They must exist in ASC or the
paywall shows fallback prices and **review will reject the purchase flow**.
- ASC → your app → Subscriptions → create a Subscription Group (e.g. "Gaita Premium").
- Add two auto renewable subscriptions with these **exact** product IDs:
  - `com.runright.premium.monthly` — price $7.99/month
  - `com.runright.premium.annual` — price $59.99/year
- Fill each: display name, description, and a review screenshot of the paywall.
- Add the **Terms of Use (EULA)** and **Privacy Policy** URLs in the subscription metadata (same URLs as step 6).
- Optional but recommended: generate a `Products.storekit` config in Xcode (Product → Scheme → Edit → Options → StoreKit Configuration) pointing at these IDs, so you can test the purchase UI locally before ASC review.

## 4. Deploy / verify the backend
- `coachChat` is **already deployed** (done this session, verified returning real replies).
- Verify `analyzeShoe` is deployed: `npx firebase-tools functions:list --project corsa-51d8f` should show both `analyzeShoe` and `coachChat`.
- ⛔ **App Check** — both functions ship with `enforceAppCheck: true`. If App Check is not configured, EVERY coach + scan call fails for real users (the simulator can bypass attestation, so it "works" in testing and breaks in production). To configure:
  - Firebase console → App Check → register the iOS app with **App Attest** (production) and Debug provider (development).
  - Confirm the app initializes App Check at launch (the FirebaseAppCheck pod is already linked; verify the init call runs before any function call).
  - Test on a real device with a TestFlight build that a function call succeeds.
  - If you cannot get App Check working before launch, set `enforceAppCheck: false` on both functions and redeploy as a fallback (less secure, but functional). Do not launch with enforcement on and attestation broken.

## 5. Secrets & key hygiene ⛔
- Confirm the previously leaked OpenAI key is **revoked** at platform.openai.com/api-keys and that the live key exists only as the Firebase secret (`firebase functions:secrets:get OPENAI_API_KEY`).
- Google Cloud console → APIs & Services → Credentials → restrict the Firebase iOS API key to your bundle ID (iOS app restriction). It is a client key so shipping it is fine, but restricting it limits abuse.
- The ElevenLabs TTS worker (`coach-pace-tts.coach-pace.workers.dev`) accepts unauthenticated calls today. Before relying on cloud voice at scale, add Firebase ID token verification or App Check to the worker, or someone with the URL can drain the quota. (Not a launch blocker if the coach defaults to the on device Lewis voice, which it now does.)

## 6. Host the legal docs ⛔
- Host `legal/PRIVACY_POLICY.md` and `legal/TERMS_AND_CONDITIONS.md` at public URLs (GitHub Pages, the Gaita site, or any static host). Render the Markdown to HTML.
- The docs are complete and accurate (entity Arjun Wategaonkar, contact email filled, California governing law, no remaining placeholders).
- Enter the **Privacy Policy URL** in ASC → App Privacy (required).
- Enter the **Terms of Use URL** in the subscription metadata and app description (required for auto renewable subs).
- The app already links to the bundled copies in Profile and on the paywall, so in app access is covered.

## 7. App Privacy answers ⛔
- ASC → App Privacy → fill using the answer sheet in `legal/APP_STORE_LISTING.md`.
- It must match `PrivacyInfo.xcprivacy`: collect Email, Name, User ID, Health, Fitness, Photos/Videos, Other User Content, Other Data — all linked, none for tracking. Do NOT declare precise location or audio.

## 8. Trademark ⛔ (legal, do before the listing goes public)
- Run a knockout search for "Gaita" (USPTO TESS/TSDR + EUIPO), especially against Gaitly, gaitly.ai, and GaitLab in classes 9 / 41 / 42. The internal memo flags real confusion risk. Clear it or accept the risk knowingly before publishing.

## 9. Store listing content
- Paste name, subtitle, promotional text, description, keywords, What's New from `legal/APP_STORE_LISTING.md`.
- Category: Health & Fitness (primary), Sports (secondary).
- Age rating: run the questionnaire (expect 4+).
- Support URL and (optional) marketing URL.

## 10. Screenshots
- Capture on a 6.7" simulator (iPhone 15/16/17 Pro Max) with the polished demo data and premium unlocked (debug button).
- Clean the status bar: `xcrun simctl status_bar <UDID> override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3`.
- Five shots, order and captions in the listing doc (skeleton overlay, dials+FOCUS, your run vs optimal, shoe heat grid, coach chat).

## 11. Real device test pass (cannot be done on the simulator)
Build to a physical iPhone (⌘R with the phone selected) and verify:
- [ ] Camera capture records a run and it analyzes
- [ ] Lewis coach voice downloads (premium, on Wi-Fi) and speaks; first synthesis ~20s one time
- [ ] Live voice transcription: mic → words appear in the coach input as you speak (needs iOS 26)
- [ ] HealthKit permission + workout sync
- [ ] A sandbox subscription purchase completes and unlocks premium
- [ ] A coach chat message returns a real reply on device (proves App Check works in production)
- [ ] Sign in with Apple and Google both complete

## 12. TestFlight
- Archive (Product → Archive with the Release scheme — confirm it uses Release config, which compiles out the debug premium unlock).
- Upload to App Store Connect, add to TestFlight, install on your device, run the step 11 checklist there.

## 13. Submit for review
- Attach the build, confirm all metadata, answer the export compliance prompt (the app declares `ITSAppUsesNonExemptEncryption = NO`, so this should auto pass).
- Add review notes: explain the debug premium unlock is DEBUG only and compiled out; provide a demo account or note that form analysis is free without sign in; note the coach refuses medical advice.
- Submit.

---

## Optional hardening (not blockers)
- Minimize date of birth: store an over/under age boolean server side and keep the raw DOB on device (currently the DOB is uploaded and declared under Other Data — declared is compliant, minimizing is better).
- Authenticate the ElevenLabs TTS worker (see step 5).
- Retitle internal `Corsa` / `RunRight` identifiers (Firebase project id, rules comments) — invisible to users, cosmetic only.
- Full Dynamic Type / VoiceOver pass.

## Status of things already handled in code (no action needed)
- Privacy manifest: valid data types, encryption declaration, honest purpose strings, dead Siri string removed, display name set to Gaita.
- Paywall: auto renewal disclosure, Restore Purchases, Terms + Privacy links, no fallback-price purchase.
- Legal docs: bundled and linked in app, accurate, no placeholders.
- Coach: medical disclaimer shown; grounded, refuses diagnosis server side.
- Scoring: deterministic, single source of truth.
- Two font system, light/dark theme, splash.
