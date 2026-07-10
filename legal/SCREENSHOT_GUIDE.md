# Gaita — App Store Screenshot Guide

Everything about producing, checking, and re-producing the store screenshots.
Redo these whenever the UI or scoring changes meaningfully.

## What Apple requires
- One set at the largest iPhone size. We capture on the **iPhone 17 Pro Max
  simulator (1320 x 2868)** — accepted as the 6.9 inch size.
- 3 to 10 images, PNG or JPEG, no transparency, no rounded device frames needed.
- They must show the real app. Mockups are allowed but the UI shown must exist.
- Upload location: App Store Connect → your app → the iOS App version page →
  App Previews and Screenshots.

## The five shots (order = the story a browser sees)
1. **01-analyze-dashboard** — the hero. Skeleton thumbnail + the three dials
   (Drive / Impact / Smooth) + cue cards. Sells "we score your form."
2. **02-full-metrics-skeleton** — pose skeleton drawn on the runner + the
   angles/targets table (cadence, torso, shin, GCT, strike). Sells the depth.
3. **03-coach** — the AI coach chat with suggestion chips + Plan Your Week card.
4. **04-run-plan** — Start Running screen: map, START, today's plan with
   segments and training zones, shoe wear.
5. **05-gait-vs-optimal** — knee/ankle curves vs the typical range bands.
   The "science" shot no competitor has.

## The footage rule (do not skip)
The Analyze shots show a real clip being analyzed, so the clip's rights matter:
- **Safest: your own recordings** (IMG_2658/2659/2660) — you own them fully.
- Stock is fine ONLY with a real license (Pexels/Mixkit yes; anything saved
  from Instagram/TikTok/Google Images **no** — likeness + copyright risk on a
  paid app).
- The three "perfect form" reference clips have unknown provenance (hash
  filenames). Confirm where they came from before ever using them in the store.

## The demo-state recipe (what makes the screenshots look right)
Seeded on the simulator before capturing (all via `xcrun simctl spawn <SIM>
defaults write com.runright.app ...`):
- `hasCompletedWeeklyOnboarding YES`, `hasSeenAppTour YES`,
  `hasSeenSyncPrompt YES` — no first-run interruptions
- `gaita.appearance dark` — the brand look
- `debug.premiumUnlocked YES` — premium features visible (DEBUG builds only)
- consent record seeded so no privacy sheet appears
- Clean status bar: `xcrun simctl status_bar <SIM> override --time 9:41
  --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3`
- Add the demo clip to Photos: `xcrun simctl addmedia <SIM> <clip>`

Then in the app: Analyze tab → tap the ANALYZE card → pick the clip → wait
(~1-2 min) → dashboard populates → navigate and capture.

## Capturing
`xcrun simctl io <SIM> screenshot out.png` — native resolution, no window
chrome. Never screenshot the Mac window itself.

Current output folder: `~/Downloads/gaita-appstore-screenshots/`

## Gotchas learned the hard way
- Reinstalling the app changes its data container — restage clips after any
  reinstall.
- The simulator camera doesn't exist; always use the upload path, not Record.
- Screenshot AFTER scoring changes: the dial numbers bake into the image.
- Captions/marketing frames on top of screenshots are allowed (Apple permits
  decorated screenshots); keep the app UI truthful inside them.
