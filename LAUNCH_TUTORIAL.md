# Gaita — Full Launch Tutorial (click-by-click)

A non-technical, do-it-in-order walkthrough to get Gaita live on the App Store.
Pair it with a video for the visuals; this fills in **your** exact values that no
generic video has. Review usually takes **1–3 days** after you submit.

**Watch first (visual walkthrough of Xcode Archive → App Store Connect → Submit):**
https://www.youtube.com/watch?v=Qgq6jsRtfbA

**Your key values (used throughout):**
- Bundle ID: `com.runright.app`
- Subscriptions: `com.runright.premium.monthly` ($7.99/mo) · `com.runright.premium.annual` ($59.99/yr) · Group: **Gaita Premium**
- Firebase project: `corsa-51d8f`
- Legal URLs: `https://gaita-site.vercel.app/privacy` · `https://gaita-site.vercel.app/terms`
- App name: `Gaita: Running Form Coach`  (full listing copy in `legal/APP_STORE_LISTING.md`)

---

## Part 0 — Prerequisites (15 min)
- [ ] Apple Developer Program membership active ($99/yr) — https://developer.apple.com/account
- [ ] Xcode open on this Mac, signed into your Apple ID: **Xcode ▸ Settings ▸ Accounts ▸ +** → add your Apple ID.
- [ ] Decide the **bundle ID** now (permanent after first upload). Keeping `com.runright.app` = zero extra work. Changing to `com.gaita.app` = re-register the Firebase app + new GoogleService-Info.plist. Recommendation: **keep `com.runright.app`** for launch; rename later isn't worth the risk the night before.

## Part 1 — Firebase App Check (do before anything else; 10 min)
Your app now attests with **App Attest**. If Firebase isn't set to match, every coach + scan call fails for real users.
- [ ] https://console.firebase.google.com → project **corsa-51d8f** → **App Check** (left sidebar, under Build).
- [ ] Click your iOS app → **App Attest** → Register. (Add the **Debug** provider too, for your own testing.)
- [ ] Leave enforcement ON for `analyzeShoe` and `coachChat` (already set in code).

## Part 2 — Redeploy the backend (5 min)
The error-message fix from today isn't live until you deploy.
- [ ] Open Terminal, then run (from the REPO ROOT, where firebase.json lives — not the functions/ folder):
  ```
  cd "/Users/chetanwategaonkar/Skeleton Analysis/RunRightApp"
  npx --yes firebase-tools@latest deploy --only functions --project corsa-51d8f
  ```
- [ ] Confirm it finishes with "Deploy complete" and lists `analyzeShoe` + `coachChat`.

## Part 3 — Deploy the website (legal URLs must resolve; 10 min)
App Store Connect requires working Privacy + Terms URLs.
- [ ] Deploy `gaita-site` (Vercel). Then open both links in a browser and confirm they load:
  - `https://gaita-site.vercel.app/privacy`
  - `https://gaita-site.vercel.app/terms`
- [ ] (If you use a custom domain, use that URL everywhere below instead.)

## Part 4 — Create the app record in App Store Connect (10 min)
- [ ] https://appstoreconnect.apple.com → **My Apps** → **+** → **New App**.
- [ ] Platform: iOS · Name: `Gaita: Running Form Coach` · Primary language: English (U.S.) · Bundle ID: `com.runright.app` · SKU: `gaita-ios-001` (any unique string).

## Part 5 — Subscriptions (the fiddly part; 20 min)
In your app → **Monetization ▸ Subscriptions**.
- [ ] Create a **Subscription Group** named **Gaita Premium**.
- [ ] Add subscription #1: Reference name `Premium Monthly`, Product ID **`com.runright.premium.monthly`**, duration **1 month**, price **$7.99**.
- [ ] Add subscription #2: Reference name `Premium Annual`, Product ID **`com.runright.premium.annual`**, duration **1 year**, price **$59.99**.
- [ ] For EACH: add a localized display name + description (e.g. "Unlimited AI coach and shoe scans"), and a review screenshot of the paywall.
- [ ] In the group's metadata, paste the **Privacy Policy** and **Terms of Use (EULA)** URLs from Part 3.
- [ ] The product IDs must match the app EXACTLY — a typo = the paywall shows nothing and review fails.

## Part 6 — Screenshots (5 min)
- [ ] Upload the 5 images from `~/Downloads/gaita-appstore-screenshots/` (6.9" iPhone size). Captions/order are in `legal/APP_STORE_LISTING.md`.
- [ ] ⚠️ Only after the **Freepik photo license** is cleared (the treadmill-runner image) — this gates them going public.

## Part 7 — Listing metadata (10 min) — copy from `legal/APP_STORE_LISTING.md`
- [ ] Name, Subtitle, Promotional text, Description, Keywords (100 chars, comma-separated), Support URL, Marketing URL.

## Part 8 — App Privacy questionnaire (10 min)
App Store Connect → **App Privacy**. Must match `PrivacyInfo.xcprivacy`. All **linked to you, none for tracking, purpose = App Functionality**:
- [ ] Email · Name · User ID · Health · Fitness · Photos or Videos · Other User Content · Other Data
- [ ] **Crash Data** and **Diagnostics** (added today for Firebase Crashlytics — don't skip these or it's a mismatch reject).
- [ ] Do NOT declare precise location or audio.

## Part 9 — AI-content disclosure (NEW Apple requirement; 5 min)
Apple's 2025+ guidelines require a clear user-facing disclosure when an app shows AI-generated content. Gaita's **coach chat** and **shoe-scan analysis** qualify.
- [ ] In the App Review notes AND the description, state that coaching replies and scan analysis are AI-generated.
- [ ] Make sure the in-app coach/scan surfaces read as AI assistance, not medical advice (the copy already leans this way — just confirm).

## Part 10 — Archive & upload the build (15 min) — in Xcode
- [ ] Top bar: set the run destination to **Any iOS Device (arm64)** (NOT a simulator).
- [ ] **Product ▸ Scheme ▸ Edit Scheme** → confirm **Run/Archive = Release** (so DEBUG demo unlocks + the backtest tool are excluded).
- [ ] **Product ▸ Archive.** Wait for it to build.
- [ ] In the Organizer window: **Distribute App** → **TestFlight & App Store** → **Upload**. Let automatic signing handle certs.

## Part 11 — TestFlight device test (20 min) — REQUIRED, can't be faked on simulator
Install the uploaded build on your iPhone via TestFlight and confirm:
- [ ] Camera records a run and it analyzes
- [ ] A **coach chat message returns a real reply** (proves App Attest works in production — the #1 thing to verify)
- [ ] A **sandbox subscription purchase** completes and unlocks premium
- [ ] Sign in with Apple AND Google both work
- [ ] HealthKit permission + workout sync
- [ ] Lewis coach voice downloads and speaks (Wi-Fi, premium)

## Part 12 — Submit for review (5 min)
- [ ] Attach the uploaded build to the version.
- [ ] Answer export compliance = **No** (already set `ITSAppUsesNonExemptEncryption=false`).
- [ ] Add reviewer notes: a demo login if needed, and the AI-disclosure note from Part 9.
- [ ] **Submit for Review.** Watch status in App Store Connect; expect 1–3 days.

---

## Common rejection causes (all already handled in your build)
Restore Purchases ✓ · Sign in with Apple ✓ · in-app account deletion ✓ · permission strings ✓ ·
crash-data declared ✓ · no leaked backend errors ✓ · wake-word mic stops in background ✓.

## If you get rejected
Read the exact guideline number Apple cites in Resolution Center, fix that one thing, and
reply/ resubmit — most first-submission rejections are a single metadata or privacy detail, not the app.
