# Data Compliance Checklist — Gaita

Prioritized, Gaita-specific gaps found in an audit of the app's actual data flows (Firebase, OpenAI shoe photos, ElevenLabs coach text, HealthKit, background GPS, on-device pose). Severity reflects launch-blocking risk. **Not legal advice — have counsel confirm before release.**

---

## 🔴 CRITICAL — fix before any submission

### 1. Revoke the hardcoded OpenAI API key (security incident) — ✅ KEY REMOVED FROM APP (2026-07-02); REVOCATION AT platform.openai.com STILL UNVERIFIED
- ~~A live OpenAI key was hardcoded in `RunRightApp/Info.plist`.~~ **Fixed in code:** the key is gone from Info.plist and from all git history (verified 2026-07-02); the shoe scanner now calls the `analyzeShoe` Firebase function which verifies the Firebase ID token and holds the key as a server-side secret. **Still open (user action): confirm the old key is revoked in the OpenAI dashboard.**
- **Do now:** (a) **revoke that key** at platform.openai.com/api-keys (only you can do this — I won't handle credentials), (b) issue a new key, (c) **never ship it in the app** — route the shoe-photo call through a server-side proxy (mirror the ElevenLabs Cloudflare Worker pattern; you already reference a `SHOE_ANALYSIS_ENDPOINT`), (d) scrub the key from git history if it was ever committed.
- *Note:* the `AIzaSy…` key in `GoogleService-Info.plist` is a Firebase project identifier — **normal to ship**, protected by Security Rules, not a secret. Leave it.

### 2. In-app account deletion (Apple Guideline 5.1.1(v)) — ✅ DONE (2026-07-01)
- ~~Today `ProfileView.swift` only calls `auth.signOut()`~~ **Done:** `FirebaseAuthManager.deleteAccount()` wipes Firestore subcollections (runs/scans/shoes/plans/settings), Storage `users/{uid}`, and the Auth user with reauth; ProfileView exposes Delete Account + Export My Data.
- Implement a **Delete Account** flow: `Auth user.delete()` (with reauthentication) **plus** a full wipe of Firestore/Storage data (profile, runs, synced HealthKit workouts, shoe photos, videos). Must be easy to find and cover server-side data. Also satisfies GDPR Art. 17 erasure + CCPA right to delete.

### 3. iOS Privacy Manifest (`PrivacyInfo.xcprivacy`) — ✅ DONE (updated 2026-07-02)
- ~~No app-target manifest exists~~ **Done:** `RunRightApp/PrivacyInfo.xcprivacy` declares Email, Name, Health, Fitness, Photos/Videos, User ID, Other User Content (coach chat), Other Data (DOB/consent) plus required-reason APIs (UserDefaults CA92.1, FileTimestamp C617.1, DiskSpace E174.1, SystemBootTime 35F9.1). Keep in sync with App Store Connect answers.
- Add one declaring `NSPrivacyCollectedDataTypes` and `NSPrivacyAccessedAPITypes` with reason codes for the required-reason APIs Gaita uses: **UserDefaults (CA92.1)**, File Timestamp, System Boot Time, Disk Space.

### 4. Publish a GDPR/CCPA-grade privacy policy + surface it in-app and in App Store Connect
- Required by Apple (HealthKit + account apps), GDPR Arts. 13–14, CCPA/CPRA.
- Draft is ready at `legal/PRIVACY_POLICY.md` — fill the bracketed placeholders, host it at a public URL, link it in the app and in App Store Connect.
- **Washington MHMDA add-on:** because Gaita processes gait/pose + heart rate + health-related geolocation, Washington's My Health My Data Act requires a **separate, prominently linked consumer-health-data privacy policy** and a "Limit the Use of My Sensitive Personal Information" link.

---

## 🟠 HIGH — required for EU/UK launch and sensitive data

### 5. Explicit, granular consent layer + age gate — ✅ DONE IN APP (consent gate + DOB age gate); GDPR record-keeping review still open
- iOS permission prompts are **not** a GDPR lawful basis. Add explicit consent, recorded with timestamps, for: **HealthKit/health data (Art. 9(2)(a) explicit consent)**, **background GPS**, and **run video** (health/biometric-adjacent).
- Add an **age gate** blocking under-13 (under-16 in parts of the EU) at signup — prevents COPPA "actual knowledge" (amended COPPA Rule compliance deadline **April 22, 2026**).

### 6. Sub-processor agreements + international transfer mechanisms
- Execute/accept DPAs and confirm a valid transfer tool (SCCs / EU-US DPF / UK IDTA) for every US transfer:
  - **Google/Firebase** — Cloud Data Processing Terms; DPF-certified + SCCs.
  - **OpenAI** — [DPA](https://openai.com/policies/data-processing-addendum/); SCCs + IDTA, DPF-certified; API default retains inputs ≤30 days, no training on API data — consider **Zero Data Retention** for shoe images.
  - **ElevenLabs** — [DPA](https://elevenlabs.io/dpa); DPF-certified + SCCs.
- **Publish a sub-processor list** (Google, OpenAI, ElevenLabs, Cloudflare Worker proxy) with transfer mechanism + retention per entry; reference it in the privacy policy. Run **TIAs** per transfer.

### 7. Data Protection Impact Assessment (DPIA)
- Effectively mandatory under GDPR Art. 35: large-scale special-category (health) data + systematic location monitoring + run video. Complete and document it **before** EU/UK launch.

### 8. Lock down the biometric/video boundary
- **Good news:** pose/skeleton runs on-device (`PoseDetection.swift`, BlazePose + Vision fallback) and is used for **form analysis, not identification** → likely **outside GDPR Art. 9 "biometric identification"** and lower BIPA risk.
- **But:** the running **video contains the user's face/likeness** and the activity is health data, so the broader processing still pulls Gaita into Art. 9 + DPIA territory.
- **Washington MHMDA expressly lists "gait patterns" as biometric data** — Gaita's gait/pose + HR + GPS squarely implicates it.
- **Action:** confirm **no run-video frames or pose templates ever leave the device** (check `VideoProcessor.swift` → Firebase Storage). Keep extraction strictly on-device and identity-agnostic; document that no biometric template is created for identification; add a retention/destruction schedule. *(Any upload of face geometry triggers BIPA written notice+consent — private right of action, $1,000–$5,000/violation.)*

---

## 🟡 MEDIUM

### 9. HealthKit handling (Apple Guideline 5.1.3)
- `HealthKitManager.swift` copies step/workout/HR data into Firestore (US). Ensure it is **never** used for advertising or data-mining, **never** shared with third parties for those purposes, and **never** stored in iCloud. Lock down Firestore Security Rules + retention.

### 10. CCPA/CPRA request handling + Global Privacy Control
- Gaita collects SPI (precise geolocation, health). Honor **GPC** opt-out signals and implement Right-to-Know / Right-to-Delete / Limit-SPI handling within statutory timeframes (≈15 business days for opt-out/limit).

## 🟢 LOW

### 11. Tighten Info.plist permission purpose strings
- Make every usage string match real functionality (esp. `NSMicrophoneUsageDescription` "voice commands"). Inaccurate/unused strings are a common rejection reason and a transparency gap.

---

## Quick status table

| # | Item | Severity | Owner action |
|---|------|----------|--------------|
| 1 | Revoke + proxy the OpenAI key | 🔴 | **You** (revoke) + code (proxy) |
| 2 | In-app account deletion | 🔴 | Code |
| 3 | PrivacyInfo.xcprivacy | 🔴 | Code/config |
| 4 | Publish privacy policy (+WA MHMDA) | 🔴 | Fill draft + host |
| 5 | Consent layer + age gate | 🟠 | Code |
| 6 | DPAs + SCCs + sub-processor list | 🟠 | Legal/ops |
| 7 | DPIA | 🟠 | Legal |
| 8 | Biometric/video boundary + retention | 🟠 | Code + policy |
| 9 | HealthKit 5.1.3 handling | 🟡 | Code/config |
| 10 | CCPA requests + GPC | 🟡 | Code/ops |
| 11 | Permission string cleanup | 🟢 | Config |
