# Running Tracker Package

This folder contains the running tracker UI + logic + voice assistant pieces extracted from `RunRightApp`.

## Files Included
- `ActiveRunView.swift` — live run UI (Strava-style)
- `RunView.swift` — pre-run screen + start flow
- `ActivityTracker.swift` — GPS tracking + stats aggregation
- `VoiceAssistantManager.swift` — run announcements (start/pause/resume/finish/milestones)
- `RouteMapView.swift` — map rendering and tracking camera
- `ActivityTrackerView.swift` — supporting tracker UI
- `AppTheme.swift` — shared colors/fonts used by the run UI
- `MainTabView.swift` — host tab layout (needed if previewing in isolation)
- `HeartRateZonesManager.swift` / `TrainingZonesOnboarding.swift` — optional HR zones UI

## Integration Notes
- Requires iOS location permissions and `NSLocationWhenInUseUsageDescription` in Info.plist.
- Voice assistant uses `AVSpeechSynthesizer` in `VoiceAssistantManager.swift`.
- Map view uses MapKit via `RouteMapView.swift`.

If you want this pared down further, I can remove any optional files.  

