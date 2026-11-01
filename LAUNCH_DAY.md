# Gaita — Launch Day Sheet

One ordered checklist for launch day, with the exact values filled in. This is
the "do it in this order" companion to `LAUNCH_RUNBOOK.md` (which has the deeper
reasoning per step). Everything below marked **[YOU]** needs your Apple/Firebase
account, a payment method, or a real device — none of it can be done from code.

Prepared date: 2026-07-10 (evening before).

---

## Already prepped in code (no action needed)
- ✅ App Check aligned to **App Attest** (`RunRightApp.swift`) — so it matches the
  Firebase registration in step 5. (Was DeviceCheck; that would have failed live.)
- ✅ `Products.storekit` created with both subscription IDs — for local paywall
  testing (step 3b).
- ✅ `PrivacyInfo.xcprivacy` verified to match the App Privacy answer sheet (step 7).
- ✅ Screenshots + website mockups final (real single-side skeleton, no copyrighted clip).
- ✅ App builds clean; DRIVE scoring fixed; backend functions written.

## Two open decisions that block launch — settle these FIRST
1. ⛔ **Bundle ID.** Currently `com.runright.app` (in both build configs). It is
   permanent after first upload. Keep it, or switch to `com.gaita.app` (cleaner
   but means re-registering the Firebase app + new GoogleService-Info.plist + App
   Check/Sign-in-with-Apple reconfig). **Decision: __________**
2. ⛔ **Stock-photo license.** The treadmill-runner photo in the screenshots /
   site / ad is from Freepik. Buy the commercial license **and** confirm the
   image has a model release, or swap it. Blocks all public visuals.

---

## Launch-day order

### 1. Apple Developer [YOU]
- [ ] Confirm paid membership active ($99/yr).
- [ ] Identifiers → App ID for your bundle ID exists with **HealthKit** + **Sign in with Apple** enabled.

### 2. App Store Connect — create the app [YOU]
- [ ] My Apps → + → New App. Bundle ID = your step-0 choice.
- [ ] Name: `Gaita: Running Form Coach` · Primary language: English (US) · Primary category: Health & Fitness.

### 3. Subscriptions (biggest blocker) [YOU]
- [ ] Subscription Group: **Gaita Premium**
- [ ] Auto-renewable products, EXACT IDs:
  - `com.runright.premium.monthly` — **$7.99 / month**
  - `com.runright.premium.annual` — **$59.99 / year**
- [ ] Add EULA + Privacy Policy URLs (step 6) to the subscription metadata.
- [ ] 3b (optional, local test): in Xcode add `Products.storekit` to the project, then
      Product → Scheme → Edit → Run → Options → StoreKit Configuration → select it.
      Run in the simulator and confirm the paywall shows both tiers + a sandbox purchase unlocks premium.

### 4. Backend [YOU – quick]
- [ ] `npx firebase-tools functions:list --project corsa-51d8f` shows **analyzeShoe** and **coachChat**.
- [ ] **Redeploy** — `functions/index.js` changed today (raw OpenAI/error strings no longer leaked to clients): `npx firebase-tools@latest deploy --only functions --project corsa-51d8f`.

### 5. App Check — App Attest [YOU]  ← must match the code (App Attest)
- [ ] Firebase console → App Check → register the iOS app with **App Attest** (production) + **Debug** provider (dev).
- [ ] Confirm on a real TestFlight build that a coach message returns a reply (proves attestation works).
- [ ] Fallback only if broken: set `enforceAppCheck: false` on both functions and redeploy. Do NOT launch with enforcement on + attestation broken.

### 6. Host legal docs [YOU]
- [ ] Deploy gaita-site. Confirm live:
  - Privacy Policy: `https://gaita-site.vercel.app/privacy`
  - Terms of Use: `https://gaita-site.vercel.app/terms`
- [ ] (If using a custom domain, use that instead and update ASC + the app.)

### 7. App Privacy answers [YOU]  — must match `PrivacyInfo.xcprivacy`
All **linked to you, none for tracking, purpose = App Functionality**:
Email · Name · User ID · Health · Fitness · Photos or Videos · Other User Content · Other Data · **Crash Data · Diagnostics** (the last two added for Firebase Crashlytics — declare them or the manifest/SDK mismatch is a 5.1.2 reject).
Do NOT declare precise location or audio.

### 8. Trademark [YOU – legal]
- [ ] Confirm the "Gaita" name/listing is clear before it goes public (see `legal/TRADEMARK_MEMO.md`).

### 9. Listing content [YOU – paste from `legal/APP_STORE_LISTING.md`]
- [ ] Name / Subtitle / Promo text / Description / Keywords / Support + Marketing URLs.

### 10. Screenshots [YOU – upload]
- [ ] Upload the 5 shots from `~/Downloads/gaita-appstore-screenshots/` (once the photo license in decision 2 is cleared).

### 11. Real-device test pass (cannot be done on the simulator) [YOU]
- [ ] Camera capture records a run and it analyzes
- [ ] Lewis coach voice downloads (premium, Wi-Fi) and speaks
- [ ] Live voice transcription: mic → words in the coach input (iOS 26)
- [ ] HealthKit permission + workout sync
- [ ] Sandbox subscription purchase completes and unlocks premium
- [ ] A coach chat message returns a real reply on device (proves App Check in production)
- [ ] Sign in with Apple AND Google both complete

### 12. TestFlight [YOU]
- [ ] Archive → upload → TestFlight → install on your device → run the step-11 checklist there.

### 13. Submit for review [YOU]
- [ ] Attach the demo account / notes, answer the review questions, submit.

---

## If anything on the engineering side needs a change, ping me. Everything above
## with [YOU] is account/device/legal work only you can do.
