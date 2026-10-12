# MyHeart

A native iOS (SwiftUI) app that reads your heart rate and other Apple Health data, shows dashboards and insights, exports PDF reports, and can share your live heart rate with family over iCloud.

## Features

- **Health tab** — today's activity rings, heart, sleep, body, respiratory, mobility, nutrition and audio metrics with sparklines
- **Heart tab** — 1D / 1W / 1M / 3M / 6M overview (latest, resting, average, HRV with period-over-period deltas, time in zones, insights, trend chart) and a per-day report for up to 31 days
- **History tab** — every sample in the selected range, filterable by source and elevated readings
- **PDF export** — overall or daily report, shared via the system share sheet
- **Family tab** — live heart-rate sharing via CloudKit (`CKShare`), following other people, high-HR and emergency alerts
- **Settings** — age / max HR (zones), elevated threshold, emergency thresholds and contact, display name

## Requirements

- iOS 16.0+
- Xcode 16+
- A real device for HealthKit (the simulator returns no samples unless you seed Health)
- An Apple Watch (or any HealthKit data source) recording heart rate
- For live sharing: an Apple Developer team with the iCloud container `iCloud.com.myheart.MyHeart`

## Project layout

```
MyHeart/
├── MyHeartApp.swift            # @main entry point, bootstrap + foreground refresh
├── AppDelegate.swift           # share acceptance, silent push, BG refresh, notifications
├── ContentView.swift           # tab container
├── Models/                     # samples, zones, health snapshot, live-share record, profile
├── Services/
│   ├── HealthKitManager(+Metrics).swift   # all HealthKit queries + heart-rate observer
│   ├── LiveStatusPublisher.swift          # HealthKit → live status → CloudKit
│   ├── LiveSharingService(+Watcher, +Subscriptions).swift
│   ├── EmergencyEvaluator.swift
│   ├── SharingError.swift
│   └── PDFExporter.swift
├── ViewModels/
├── Views/
├── Resources/
├── Info.plist
└── MyHeart.entitlements
```

## Building

The Xcode project is checked in (generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`). If you regenerate it, set your team again afterwards.

1. Open `MyHeart.xcodeproj`, select the `MyHeart` target → Signing & Capabilities → choose your Team.
2. Capabilities used (all declared in `MyHeart.entitlements`):
   - **HealthKit** with **Background Delivery** (live sharing keeps updating while the app is closed)
   - **iCloud → CloudKit**, container `iCloud.com.myheart.MyHeart`
   - **Push Notifications** (silent CloudKit pushes for followers)
   - **Time Sensitive Notifications** (emergency alerts)
   - **Background Modes**: Remote notifications, Background fetch
3. Run on a real device and grant Health access.

Every push is compiled on GitHub Actions (`.github/workflows/build.yml`, iOS Simulator, no signing).

## Live sharing

- The sharer's latest reading lives in one `LiveHeartStatus` record in a custom zone of their **private** CloudKit database; a `CKShare` with public read-only permission makes it visible to anyone who opens the invite link.
- `LiveStatusPublisher` registers an `HKObserverQuery` with background delivery at launch, so new Apple Watch readings are published even when MyHeart isn't open. Writes are throttled to one every 30 s; zone changes, big jumps and emergencies bypass the throttle.
- Followers get a silent push (`CKDatabaseSubscription`) plus a ~15 min background refresh, and local notifications for high heart rate (per-person threshold, default 130 bpm) and emergencies.

### CloudKit schema (important before TestFlight / App Store)

Builds run from Xcode use the CloudKit **Development** environment, where new record fields are created automatically. TestFlight and App Store builds use **Production**, which only accepts fields that were deployed. After running a development build that has written every field (enable sharing and set an emergency contact in Settings once), open the [CloudKit Console](https://icloud.developer.apple.com/) → your container → **Deploy Schema Changes**. The `LiveHeartStatus` record type uses:

`currentBPM, zoneRaw, restingBPM, hrvMs, updatedAt, isElevated, elevatedThreshold, displayName, deviceName, maxHR, note, trendHourlyBPM, trendUpdatedAt, isEmergency, emergencyKind, emergencySince, emergencyContactName, emergencyContactPhone`

## Privacy

MyHeart only **reads** Health data. PDF reports are generated on the device and shared only when you tap Export. Live sharing, when turned on, stores your latest reading in **your own** iCloud account; there is no MyHeart server.

MyHeart is not a medical device. Emergency alerts depend on your phone being online and may be delayed by iOS.
