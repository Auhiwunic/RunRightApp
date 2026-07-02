# RunRight — Run Tab Components

This folder contains every file needed to build and integrate the **Run Tab** from the RunRight iOS app. The tab covers GPS run tracking, live stats, route mapping, weekly plan management, VDOT diagnostics, and Firebase persistence.

---

## Folder Structure

```
RunTab/
├── Core/               # UI views and live tracking logic
│   ├── RunView.swift
│   ├── ActiveRunView.swift
│   ├── ActivityTracker.swift
│   ├── ActivityTrackerView.swift
│   ├── RouteMapView.swift
│   └── AppTheme.swift
│
├── Firebase/           # Data persistence layer (Firestore + Auth)
│   ├── RunRepository.swift
│   ├── PlanRepository.swift
│   ├── FirestoreModels.swift
│   ├── FirebaseAuthManager.swift
│   └── FirebaseFirestoreService.swift
│
└── Utilities/          # Business logic helpers
    ├── HeartRateZonesManager.swift
    └── VDOTCalculator.swift
```

---

## File-by-File Breakdown

### Core/

**`RunView.swift`**
The main Run tab screen. Shows the map preview, START button, last run summary card, diagnostic run card, weather/shoe info cards, and today's training plan. Also contains the embedded types `DayPlan`, `WorkoutSegment`, `ZoneTarget`, `WeeklyPlannerSheet` (the sheet for editing weekly plans), and `DiagnosticRunSheet`.

**`ActiveRunView.swift`**
The full-screen overlay shown while a run is active. Displays live distance, pace, duration, heart rate, elevation, and a live route map. Has Pause/Resume and Stop controls. On stop, shows a summary screen with a Save button that writes the run to Firestore via `RunRepository`.

**`ActivityTracker.swift`**
The core GPS and location tracking engine. Uses `CoreLocation` and `Combine`. Publishes `liveSummary: ActivitySummary` and `finalSummary: ActivitySummary` for the views to observe. Also contains the value types `ActivitySummary`, `ElevationStats`, `ActivityCalculator`, and `ActivityFormatter`.

**`ActivityTrackerView.swift`**
A reusable stat display component used inside `ActiveRunView`. Shows labelled metric cards (distance, pace, heart rate, etc.).

**`RouteMapView.swift`**
A `UIViewRepresentable` wrapping `MKMapView` to draw the live GPS polyline during a run. Automatically follows the runner and updates as new locations arrive.

**`AppTheme.swift`**
Shared design constants — background colour (`#1A1A1C`), accent lime (`#C9FF4A`), tab bar height, and the `Color(hex:)` extension. Every view depends on this.

---

### Firebase/

**`RunRepository.swift`**
Handles all Firestore read/write for run summaries. Stores runs under `users/{uid}/runs/{runId}`. Key methods: `saveRunSummary(_:)`, `fetchLastRun(uid:)`, `fetchRuns(uid:limit:)`, `fetchTotalDurationSecondsForDay(uid:date:)`.

**`PlanRepository.swift`**
Handles Firestore persistence for weekly training plans. Stores plans under `users/{uid}/plans/{weekId}`. Key methods: `loadWeeklyPlan(uid:weekId:)`, `saveWeeklyPlan(uid:weekId:days:)`, plus `weekId(for:)` and `weekStart(for:)` date helpers.

**`FirestoreModels.swift`**
All DTO (Data Transfer Object) structs used for Firestore serialization. Relevant Run tab types: `RunSummaryDTO` (with `toFirestore()` and `fromFirestore(_:runId:)` methods), `DayPlanDTO`, `WeeklyPlanDTO`, `WorkoutSegmentDTO`, `ZoneTargetDTO`. Also includes shoe scan DTOs (`ShoeScanDTO`, `WearZonesDTO`) which are used by the Scan tab — safe to ignore for the Run tab.

**`FirebaseAuthManager.swift`**
`@MainActor ObservableObject` singleton (`FirebaseAuthManager.shared`) that wraps Firebase Auth. Publishes `uid`, `isAuthenticated`, `isAnonymous`, and `errorMessage`. Handles anonymous sign-in on launch and Apple Sign In linking. The Run tab repositories call `Auth.auth().currentUser?.uid` directly — this manager is needed to ensure the user is signed in before those calls are made.

**`FirebaseFirestoreService.swift`**
A thin wrapper around `Firestore.firestore()`. Provides `collection(_:)`, `document(_:)`, and `serverTimestamp()` helpers. The repositories don't currently go through this wrapper (they call Firestore directly), but it's included as a shared utility.

---

### Utilities/

**`HeartRateZonesManager.swift`**
`ObservableObject` that calculates personalised heart rate training zones from user profile data (`UserFitnessProfile`). Contains `HeartRateZone`, `CalculatedZones`, and `UserFitnessProfile` types. Used by `DiagnosticRunSheet` inside `RunView`.

**`VDOTCalculator.swift`**
Calculates VDOT fitness score from race times and produces training pace recommendations. Contains `RunGoal` enum (used in `RunView`'s diagnostic sheet), `TrainingPaces`, and `VDOTCalculator` struct. Fully self-contained, no external dependencies.

---

## Dependencies to Add to the Target

### CocoaPods (add to Podfile)
```ruby
pod 'FirebaseAuth'
pod 'FirebaseFirestore'
```

### Apple Frameworks (already available, no extra setup)
- `CoreLocation` — GPS tracking in `ActivityTracker`
- `MapKit` — route drawing in `RouteMapView` and `ActiveRunView`
- `Combine` — reactive updates in `ActivityTracker`

---

## Firebase Setup Required

1. Add `GoogleService-Info.plist` to the Xcode target.
2. Call `FirebaseApp.configure()` in your `@main` App `init()`.
3. In the Firebase Console (console.firebase.google.com):
   - **Authentication → Sign-in method → Anonymous** → Enable
   - **Firestore Database** → Create database (Start in test mode for dev, then apply security rules for prod)

### Firestore Security Rules (recommended for prod)
```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /users/{userId}/{document=**} {
      allow read, write: if request.auth != null && request.auth.uid == userId;
    }
  }
}
```

### Firestore Data Schema
```
users/
  {uid}/
    runs/
      {runId}/
        startTime: Timestamp
        distanceMeters: Double
        durationSeconds: Double
        avgSpeedMps: Double
        avgHeartRateBpm: Int (optional)
    plans/
      {weekId}/           ← format: "YYYY-MM-DD" (Monday of that week)
        weekId: String
        weekStart: Timestamp
        days: Array of DayPlan dicts
```

---

## How to Integrate Into an Existing App

1. Drag all files from `Core/`, `Firebase/`, and `Utilities/` into your Xcode project.
2. Make sure `GoogleService-Info.plist` is in the target.
3. In your root `App` struct, call `FirebaseApp.configure()` before any views load.
4. Bootstrap auth by calling `await FirebaseAuthManager.shared.signInAnonymouslyIfNeeded()` from a `.task {}` modifier on your root view.
5. Add `RunView()` as a tab in your `TabView`.

---

## Notes for the Developer

- `RunView` is self-contained — it manages its own state for weekly plans, VDOT, shoe selection, and the active run overlay.
- `ActiveRunView` expects an `@ObservedObject var tracker: ActivityTracker` and an `@Binding var elapsedTime: TimeInterval` passed from `RunView`. Do not instantiate it independently.
- All Firestore writes require a signed-in user (anonymous or Apple). The guard statements in `RunRepository` and `PlanRepository` will throw if `Auth.auth().currentUser` is nil.
- `AppTheme.swift` must be included — all views depend on `AppTheme.bgColor`, `AppTheme.tabBarHeight`, and the `Color(hex:)` extension.
