# Privacy Policy

**App:** Gaita
**Effective date:** June 22, 2026
**Last updated:** June 22, 2026

> **Fill before publishing:** `[LEGAL ENTITY NAME]` (the company or individual that owns Gaita), `[CONTACT EMAIL]`, `[BUSINESS ADDRESS]`, `[GOVERNING JURISDICTION]`. Replace every bracketed placeholder below, then have a lawyer review — this template covers the App Store, GDPR, and CCPA/CPRA bases but is not a substitute for legal advice, especially because Gaita handles health and location data.

This Privacy Policy explains how `[LEGAL ENTITY NAME]` ("Gaita," "we," "us," or "our") collects, uses, shares, and protects your information when you use the Gaita mobile application (the "App"). By using the App, you agree to the practices described here.

---

## ⚠️ Important: the Gaita AI Voice Coach

**The voice coach is the one feature in Gaita that streams content off your device in real time, so we call it out separately here.**

When the AI Voice Coach is **turned on** during a run:

- **Microphone & Siri:** Gaita listens for voice commands (e.g. "start a run," "what's my pace?"). Speech-to-text is handled by Apple's on-device/Siri speech services under Apple's privacy terms.
- **Cloud text-to-speech:** To speak coaching cues back to you in a natural voice, Gaita sends the **text of the cue** (for example, "Mile 3, pace 8:30, keep it steady") to our voice-generation service — a Gaita-operated proxy that relays the text to our text-to-speech provider (**ElevenLabs**). The provider returns synthesized audio, which Gaita plays and may cache on your device. **No microphone recording of your voice is sent to this service** — only the coaching text Gaita generates.
- **What is *not* sent:** We do not transmit recordings of your surroundings or conversations, and we do not use the microphone to build a profile of you.

**The voice coach is optional and off by default for cloud audio.** You can disable it at any time. With it off, Gaita falls back to Apple's on-device system voice and nothing is sent to the cloud for speech.

---

## 1. Who we are

Gaita is a running-form and training companion. The App analyzes your running form from video, scans your shoe wear, tracks runs, builds a weekly training plan, and (optionally) coaches you by voice.

**Data controller:** `[LEGAL ENTITY NAME]`
**Contact:** `[CONTACT EMAIL]`
**Address:** `[BUSINESS ADDRESS]`

## 2. Information we collect

### a) Information you provide
- **Account information:** email address and display name when you create an account or sign in with Google. You may also use the App as an anonymous guest, in which case no account identifiers are collected until you choose to sign in.
- **Onboarding profile:** your name, age, biological sex (used for heart-rate zone calculation), self-reported experience level, weekly mileage goal, and chosen training days.

### b) Health & fitness data
- **Apple Health (HealthKit):** with your permission, Gaita **reads** your step count and running workouts to display activity and inform your plan. Gaita does not write to Health unless you explicitly enable it. HealthKit data is handled under the special terms in Section 8.
- **Derived running metrics:** running power, impact, efficiency, cadence, pace, and form scores that Gaita computes from your videos and runs.

### c) Location data
- **GPS routes:** with your permission, Gaita records your location during a run (including in the background, if you allow it) to map your route, distance, pace, and splits.

### d) Camera, photos, and motion
- **Running videos:** videos you record or select for form analysis.
- **Shoe-sole photos:** images you capture or select for shoe-wear ("gait") analysis.
- **Device motion:** used only on-device to help you hold the phone level while scanning a shoe sole.

### e) Microphone & voice
- Microphone and Siri access for **voice commands** during runs, and the cloud text-to-speech described in the highlighted section above.

### f) Automatically collected technical data
- Basic device and diagnostic information needed to operate the App and our backend (e.g. app version, anonymous/authenticated user identifier, crash and error logs). We do **not** use third-party advertising or cross-app tracking SDKs.

## 3. How your data is processed (on-device vs. cloud)

| Feature | Where it runs | Leaves your device? |
|---|---|---|
| Running-form / skeleton analysis (pose detection) | On-device (Apple Vision) | **No** |
| Running metrics (power, impact, efficiency) | On-device | **No** |
| Step count & workouts (HealthKit) | On-device read | **No** |
| GPS run tracking | On-device; route saved to your account | Stored in your account (Firebase) |
| **Shoe-wear analysis** | **Cloud — photos sent to OpenAI** | **Yes** (see Section 5) |
| **AI Voice Coach (spoken cues)** | **Cloud — coaching text sent to TTS provider** | **Yes** (see highlighted section) |
| Account, settings, runs, plan, history | Stored in your account | Stored in Firebase (Google) |

## 4. How we use your information

We use your information to:
- provide and improve form analysis, shoe-wear analysis, run tracking, and your weekly plan;
- compute and display your metrics and progress history;
- generate spoken coaching cues (when enabled);
- create and maintain your account and sync your data across devices;
- diagnose problems, prevent abuse, and keep the App secure; and
- comply with legal obligations.

We do **not** sell your personal information, and we do **not** use your health, location, or media data for advertising.

## 5. Third-party services and sub-processors

Gaita relies on the following providers, which process certain data on our behalf. Each operates under its own privacy policy.

| Provider | Purpose | Data shared |
|---|---|---|
| **Google Firebase** (Google LLC) — Authentication, Firestore, Cloud Storage | Account sign-in, storing your settings/runs/plan/history, hosting processed media | Account identifiers, profile, runs, plan, and any media you save to your account |
| **Google Sign-In** | Optional sign-in | Email, name, Google account identifier |
| **OpenAI** | Shoe-sole **wear analysis** (vision model) | The shoe-sole **photo(s)** you submit for analysis, plus minimal prompt context |
| **ElevenLabs** (via a Gaita-operated proxy) | AI Voice Coach text-to-speech | The **text** of coaching cues (no recordings of you) |
| **Apple HealthKit / Siri** | Health data read; voice command recognition | Processed on-device under Apple's terms |

We share information with these providers only to deliver the features you use. We do not authorize them to use your data for their own independent purposes beyond providing the service to us. Please review their policies:
- Google/Firebase: https://policies.google.com/privacy
- OpenAI: https://openai.com/policies/privacy-policy
- ElevenLabs: https://elevenlabs.io/privacy
- Apple: https://www.apple.com/legal/privacy/

We may also disclose information if required by law, to enforce our Terms, or to protect the rights, safety, and property of our users or others.

## 6. Data storage, security, and retention

- Your account data is stored on Google Firebase infrastructure, which may be located in the United States or other countries.
- We use industry-standard safeguards (encryption in transit, access controls). No method of transmission or storage is 100% secure.
- We retain your data for as long as your account is active or as needed to provide the App. You can delete your data at any time (Section 9). On-device data (such as your local analysis history and cached coach audio) is removed when you delete the App or clear it in-app.

## 7. Your privacy rights

Depending on where you live, you may have the right to:
- access, correct, or delete your personal information;
- export a copy of your data (portability);
- object to or restrict certain processing; and
- withdraw consent (e.g. revoke camera, microphone, location, or Health permissions in iOS Settings at any time).

**California (CCPA/CPRA):** you have the right to know, delete, and correct your personal information, and to not be discriminated against for exercising these rights. We do **not** sell or "share" personal information as those terms are defined under California law.

**EEA/UK (GDPR):** our legal bases are your **consent** (camera, microphone, location, Health, voice coach), **performance of a contract** (providing the App and your account), and our **legitimate interests** (security, diagnostics, improving the App). You may lodge a complaint with your local data protection authority.

To exercise any right, contact us at `[CONTACT EMAIL]`.

## 8. Apple Health (HealthKit) specific terms

- We use HealthKit data **only** to provide in-app features (activity display and training plan).
- We will **never** use HealthKit data for advertising, marketing, or data-mining, and we will **never** sell it.
- We will not share HealthKit data with third parties except as needed to provide a feature you request, and never for their own purposes.
- You can revoke Gaita's Health access at any time in **Settings → Privacy & Security → Health**.

## 9. Account and data deletion

You can delete your account and associated cloud data from within the App, or by emailing `[CONTACT EMAIL]`. Deleting the App from your device also removes locally stored data (analysis history, cached coach audio, settings). Cloud-stored data tied to your account is deleted on request within `[30]` days, subject to legal retention requirements.

## 10. Children's privacy

Gaita is not directed to children under **13** (or the minimum age of digital consent in your country, e.g. 16 in parts of the EEA). We do not knowingly collect personal information from children under that age. If you believe a child has provided us information, contact us and we will delete it.

## 11. Changes to this policy

We may update this Privacy Policy from time to time. We will revise the "Last updated" date and, for material changes, provide notice in the App. Your continued use after an update constitutes acceptance.

## 12. Contact us

`[LEGAL ENTITY NAME]`
Email: `[CONTACT EMAIL]`
Address: `[BUSINESS ADDRESS]`
