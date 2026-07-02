# Firestore schema (RunRight / Corsa)

This document describes the collections/fields the iOS app currently reads/writes.

## Authentication
- Signed-in user context is used to scope all data under `users/{uid}/...`.
- Firestore security rules should enforce:
  - reads/writes only when `request.auth.uid == uid`

## Collections

### `users/{uid}`
- Notes:
  - Profile/preferences can be added later. Current app primarily writes to subcollections below.

### `users/{uid}/runs/{runId}`
Saved when a run is “Saved” from `ActiveRunView`.

Fields:
- `startTime` (Date)
- `distanceMeters` (Double)
- `durationSeconds` (Double)
- `avgSpeedMps` (Double)
- `avgHeartRateBpm` (Int, optional)

App queries:
- Last run: `orderBy("startTime", descending).limit(1)`
- Recent runs (graph): `orderBy("startTime", descending).limit(N)`
- Daily minutes (steps ring): `where startTime in [dayStart, nextDayStart)`

Suggested indexes:
- Composite index on `startTime` (descending) for the above queries.

### `users/{uid}/plans/{weekId}`
Saved from `WeeklyPlannerSheet` under the current week (week starts Monday).

Document id:
- `weekId` = `yyyy-MM-dd` for that week's Monday.

Fields:
- `weekId` (String)
- `weekStart` (Date)
- `days` (array of day objects):
  - `dayName` (String)
  - `runType` (String)
  - `isRest` (Bool)
  - `totalDistance` (String)
  - `targetPace` (String)
  - `segments` (array):
    - `name` (String)
    - `distance` (String)
    - `pace` (String)
  - `zoneTargets` (array):
    - `zoneName` (String)
    - `minutes` (Int)
    - `colorHex` (String)

App reads:
- Loads current week plan by doc id (no complex query).

### `users/{uid}/shoes/{shoeId}`
Created automatically by `ScanRepository.ensureShoeExists`.

Document id:
- `shoeId` derived from shoe name (lowercased, spaces -> underscores).

Fields:
- `shoeName` (String)
- `createdAt` (Date)

### `users/{uid}/scans/{scanId}`
Saved when the user uploads left/right shoe photos and analysis returns.

Fields:
- `shoeName` (String)
- `side` (String: `"left"` or `"right"`)
- `createdAt` (Date)
- `imageUrl` (String, optional)
- `wearZones` (object, optional) with 10 keys:
  - `bigToe`, `lesserToes`, `medialBall`, `centralBall`, `lateralBall`
  - `medialMidfoot`, `lateralMidfoot`
  - `medialHeel`, `centralHeel`, `lateralHeel`
  - each value is one of `"green" | "yellow" | "orange" | "red"`
- structured analysis fields (optional):
  - `gaitType`
  - `strikePattern`
  - `primaryWearAreas`
  - `gaitCause`
  - `concern`
  - `severity`

App queries:
- Wear trend: `whereField("shoeName" == shoeName).orderBy("createdAt", descending).limit(…)`

Suggested indexes:
- Composite index on `(shoeName, createdAt desc)`

