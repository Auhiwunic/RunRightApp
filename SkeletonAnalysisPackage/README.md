# Skeleton Analysis Package

This folder contains the skeleton analysis and review flow extracted from `RunRightApp`.

## Files Included
- `AnalyzeView.swift` — analysis entry + results UI
- `VideoSkeletonView.swift` — standalone skeleton review page
- `VideoProcessor.swift` — pose detection, skeleton overlay, metrics
- `PoseDetection.swift` — BlazePose/Vision abstraction
- `ScanView.swift` / `ScanResultsView.swift` — scan flow and results UI
- `AppTheme.swift` — shared colors/fonts used by analysis UI
- `SkeletonAnalysisTabView.swift` — isolated tab UI for analysis + scan + review
- `Models/pose_landmarker_heavy.task` — BlazePose model asset

## Integration Notes
- Requires `MediaPipeTasksVision` via CocoaPods.
- Uses `PhotosPicker` and `AVFoundation`.
- Needs `NSPhotoLibraryUsageDescription` in Info.plist.

## Xcode Standalone Setup
1. Create a new iOS App in Xcode.
2. Drag the entire `SkeletonAnalysisPackage` folder into the project.
3. Set `SkeletonAnalysisApp` as the app entry point (App file).
4. Use the included `Podfile` and run:
   - `pod install`
5. Open the generated `.xcworkspace`.
6. Add `NSPhotoLibraryUsageDescription` to Info.plist.

## MediaPipe Integration Included
- `PoseDetection.swift` contains the BlazePose integration and fallback to Vision.
- `Podfile` includes `MediaPipeTasksVision`.
- `Models/pose_landmarker_heavy.task` is bundled for BlazePose.

If you want this slimmer, tell me what to remove.

