# App Store Listing — Gaita

Paste-ready copy for App Store Connect. Written in Gaita's voice: plain, direct,
no hyphens or em dashes, no AI-ish filler. Character limits noted per field.

---

## App name (30 char max)
```
Gaita: Running Form Coach
```
(25 chars. If "Gaita" alone is wanted as the name, put "Running Form Coach" in the subtitle.)

## Subtitle (30 char max)
```
See and fix your running form
```
(29 chars.)

Alternates:
- `Running form, on your phone` (27)
- `Your pocket running coach` (25)

## Promotional text (170 char max — editable anytime without review)
```
Film one run. Gaita reads your form frame by frame, scores it, and shows the one thing to fix next. Scan your shoes to see your gait. All on your phone.
```
(150 chars.)

---

## Description (4000 char max)

```
Gaita turns your phone into a running form coach.

Film yourself running for a few seconds. Gaita analyzes every frame on your device, tracks your body through the stride, and gives you an honest read on your form: cadence, foot strike, ground contact, how far your foot lands in front of you, posture, and arm swing. No wearables, no lab, no guessing.

Then it tells you the one thing worth fixing next, and the drill that fixes it.

WHAT YOU GET FREE
- Full running form analysis from a single video, processed on your device
- Your form score and a frame by frame breakdown
- Your stride compared against the shape of efficient running form
- Basic run tracking and history

WHAT PREMIUM ADDS
- A running coach you can talk to, in text or voice, that knows your last run
- Shoe scan: photograph your soles and Gaita reads your gait and wear pattern
- Your full analysis history and progress over time

HOW IT WORKS
Gaita uses on device pose detection to follow your joints through each stride, the same measurements sports scientists use: knee and hip flexion, shin angle at contact, cadence, ground contact time, vertical bounce. It compares your curves against published running biomechanics so you see where your form is strong and where it costs you speed or invites injury.

BUILT ON REAL SCIENCE, NOT VIBES
Every target range comes from published data. Cadence bands, ground contact norms, the optimal joint angle curves, the shoe wear reading. When Gaita says lift your cadence, it tells you why and by how much.

YOUR RUN VIDEO STAYS ON YOUR PHONE
Form analysis runs entirely on your device. Your running videos are never uploaded. You are in control of what syncs to your account.

Gaita gives general fitness guidance, not medical advice. For pain or injury, see a professional.

Start with a single run. See what your form is really doing.
```

---

## Keywords (100 char max, comma separated, no spaces after commas)
```
running form,gait analysis,run coach,running technique,cadence,foot strike,stride,running drills,pace
```
(99 chars. Do not repeat words already in the app name/subtitle — Apple indexes those separately, so "Gaita" and "coach" are covered.)

Keyword rationale (highest intent first): "running form" and "gait analysis" are the core searches with low competition and exact product match; "run coach" and "running technique" catch the coaching intent; "cadence / foot strike / stride" catch runners who already know the metric they want to fix; "running drills" catches the fix intent; "pace" is broad reach.

---

## What's New (version 1.0)
```
First release. Film a run, get your form analyzed on your phone, and see the one thing to fix next.
```

---

## Support & marketing URLs
- Support URL: (required) — a simple page or the Gaita site contact.
- Marketing URL: (optional) — the Gaita site.
- Privacy Policy URL: (required) — the hosted PRIVACY_POLICY.
- Terms of Use (EULA): the hosted TERMS_AND_CONDITIONS, or Apple's standard EULA.

---

## Category
- Primary: Health & Fitness
- Secondary: Sports

## Age rating
Run the questionnaire honestly. Expected result 4+. Note: the app collects health/fitness data and has user generated content (coach chat), but no objectionable content. The coach chat is scoped to running and refuses medical/diagnostic questions.

---

## App Privacy nutrition label — answer sheet
Set these in App Store Connect → App Privacy so they match `PrivacyInfo.xcprivacy`. All are "linked to you," none used for tracking.

| Data type | Collected? | Linked | Tracking | Purpose |
|---|---|---|---|---|
| Email address | Yes (if you sign in) | Yes | No | App Functionality |
| Name | Yes (if you provide) | Yes | No | App Functionality |
| User ID | Yes (Firebase uid) | Yes | No | App Functionality |
| Health | Yes (heart rate with workouts) | Yes | No | App Functionality |
| Fitness | Yes (runs, form metrics) | Yes | No | App Functionality |
| Photos or Videos | Yes (shoe photos; run videos processed on device, not uploaded) | Yes | No | App Functionality |
| Other User Content | Yes (coach chat messages) | Yes | No | App Functionality |
| Other Data | Yes (date of birth, consent record) | Yes | No | App Functionality |

Do NOT declare: precise location (used on device for run tracking, never uploaded — routes carry no coordinates), audio (the coach only speaks; voice input is transcribed on device and never uploaded). This matches the manifest exactly.

---

## Screenshots (6.7" required; 6.5" recommended)
Suggested order, each with a one line caption baked in:
1. The Analyze dashboard with the skeleton overlay on a real run — "Your form, read frame by frame."
2. The DRIVE / IMPACT / SMOOTH dials + FOCUS cue grid — "One score. One thing to fix."
3. The your run vs optimal gait curves — "See your stride against efficient form."
4. The shoe heat grid — "Scan your soles. See your gait."
5. The coach chat with a grounded reply — "A coach that knows your last run."

Capture on the simulator at 6.7" (iPhone 15/16/17 Pro Max) with the polished test data. Keep the status bar clean (Debug → clean status bar, or simctl status_bar override).
