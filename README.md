# MyHeart

A native iOS (SwiftUI) app that reads your heart rate, resting heart rate, and HRV from Apple Health, displays a dashboard with a trend chart, and exports a shareable PDF report.

## Features

- HealthKit integration (`HKHealthStore`) for heart rate, resting HR, and HRV (SDNN)
- SwiftUI dashboard with 24h / Week / Month range picker
- Stats grid: latest, resting, average, min, max, HRV, sample count
- Live trend chart powered by Swift Charts
- History tab with the raw samples list
- One-tap PDF export (`UIGraphicsPDFRenderer` + `PDFKit`) shared via `UIActivityViewController`
- Pull-to-refresh

## Requirements

- iOS 16.0+ (uses Swift Charts)
- Xcode 15+
- A real device for HealthKit (the simulator returns no samples unless you seed Health)
- An Apple Watch (or any HealthKit data source) recording heart rate

## Project layout

```
MyHeart/
├── MyHeartApp.swift          # @main entry point
├── ContentView.swift         # Tab container
├── Models/
│   └── HeartRateSample.swift
├── Services/
│   ├── HealthKitManager.swift
│   └── PDFExporter.swift
├── ViewModels/
│   └── HeartRateViewModel.swift
├── Views/
│   ├── DashboardView.swift
│   ├── HistoryView.swift
│   └── ShareSheet.swift
├── Resources/
│   ├── Assets.xcassets/
│   └── Preview Content/
├── Info.plist
└── MyHeart.entitlements
```

## Generating the Xcode project

The repo uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate `MyHeart.xcodeproj` from `project.yml`, so the project file isn't checked in.

```bash
brew install xcodegen
xcodegen generate
open MyHeart.xcodeproj
```

Then in Xcode:

1. Select the `MyHeart` target → Signing & Capabilities → set your Team.
2. Confirm the **HealthKit** capability is enabled (it's wired up via `MyHeart.entitlements`).
3. Run on a real device.
4. On first launch, grant Health access for Heart Rate, Resting Heart Rate, and HRV.

## Exporting a PDF

Tap the share icon in the top right of the Dashboard. The app builds a multi-page PDF (summary, line chart, sample table) into the temp directory and presents the system share sheet so you can save to Files, AirDrop, email, etc.

## Privacy

The app only **reads** Health data. Nothing is uploaded — the PDF lives in the app's temp directory until you share or delete it. Usage descriptions are declared in `Info.plist` (`NSHealthShareUsageDescription`).

## Notes

- HealthKit calls won't work on iOS Simulator unless you manually add samples in the Health app.
- If you don't want XcodeGen, you can also create a fresh "iOS App" project in Xcode and drag the `MyHeart/` folder, `Info.plist`, and `MyHeart.entitlements` into it — then enable the HealthKit capability.
