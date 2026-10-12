import SwiftUI
import Charts
import HealthKit

/// The home tab — a scrollable "Today" overview pulling every category
/// HealthKit exposes. Each card drills into a category-specific detail view.
struct OverviewView: View {
    @EnvironmentObject private var viewModel: HealthOverviewViewModel
    @EnvironmentObject private var profile: UserProfile
    @EnvironmentObject private var heartVM: HeartRateViewModel
    @EnvironmentObject private var router: AppRouter
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let healthDataAvailable = HKHealthStore.isHealthDataAvailable()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    if healthUnavailable {
                        unavailableCard
                    } else {
                        if let message = viewModel.errorMessage {
                            InlineBanner(message: message, onDismiss: { viewModel.errorMessage = nil })
                        }
                        if viewModel.hasLoaded && !hasAnyData {
                            noDataCard
                        } else {
                            cards
                        }
                        footer
                    }
                }
                .padding(.horizontal)
                .padding(.vertical)
                .readableContentWidth()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Health")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !healthUnavailable {
                        refreshButton
                    }
                }
            }
            .refreshable { await viewModel.refresh() }
        }
    }

    /// Until the first refresh finishes, cards render this fixed snapshot
    /// redacted instead of a screen of dashes that looks like "no data".
    private var overview: HealthOverview {
        viewModel.hasLoaded ? viewModel.overview : .placeholder
    }

    private var healthUnavailable: Bool {
        heartVM.healthUnavailable || !Self.healthDataAvailable
    }

    private var hasAnyData: Bool {
        let o = viewModel.overview
        return o.activity.hasAny || o.heart.hasAny || o.sleep != nil || o.body.hasAny
            || o.respiratory.hasAny || o.mobility.hasAny || o.nutrition.hasAny
            || o.mindfulness.hasAny || o.audio.hasAny
    }

    /// Side by side normally; stacked at accessibility text sizes, where a
    /// row of three or four stats can't fit.
    private var rowLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
    }

    /// Two columns on iPhone, more on iPad, one at accessibility sizes.
    private var gridColumns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 160), spacing: 12)]
    }

    private var refreshButton: some View {
        Button {
            Task {
                await viewModel.refresh()
                if viewModel.errorMessage != nil { Haptics.error() }
            }
        } label: {
            if viewModel.isLoading || !viewModel.hasLoaded {
                ProgressView()
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        // The first load is already running; a tap would only restart it.
        .disabled(!viewModel.hasLoaded)
        .accessibilityLabel("Refresh")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Date(), format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            if !viewModel.hasLoaded && !healthUnavailable {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading Health data…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Cards

    private var cards: some View {
        VStack(spacing: 16) {
            activityCard
            heartCard
            sleepCard
            metricsGrid
            secondarySections
        }
        .redacted(reason: viewModel.hasLoaded ? [] : .placeholder)
        .disabled(!viewModel.hasLoaded)
        // The placeholder values aren't real; the header says it's loading.
        .accessibilityHidden(!viewModel.hasLoaded)
        .animation(.easeInOut(duration: 0.25), value: viewModel.hasLoaded)
    }

    // MARK: Empty states

    private var noDataCard: some View {
        EmptyStateView(
            systemImage: "heart.text.square",
            title: "No Health data yet",
            message: "MyHeart shows heart rate, activity and sleep from Apple Health. They appear here once your iPhone or Apple Watch records them.\n\nAlready have data in Health? Check that MyHeart may read it. \(HealthCopy.permissionPath)"
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { noDataButtons }
                VStack(spacing: 12) { noDataButtons }
            }
        }
        .cardBackground()
    }

    @ViewBuilder
    private var noDataButtons: some View {
        Button("Open Health") {
            if let url = URL(string: "x-apple-health://") {
                UIApplication.shared.open(url)
            }
        }
        .buttonStyle(.borderedProminent)

        Button("Try Again") {
            Task { await viewModel.refresh() }
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.isLoading)
    }

    private var unavailableCard: some View {
        EmptyStateView(
            systemImage: "heart.text.square",
            title: "Apple Health isn't available on this device",
            message: "You can still follow family members' live heart rate on the Family tab."
        ) {
            Button("Go to Family") { router.openFamily() }
                .buttonStyle(.borderedProminent)
        }
        .cardBackground()
    }

    // MARK: Activity

    private var activityCard: some View {
        NavigationLink {
            ActivityDetailView(snapshot: overview.activity, stepsSeries: overview.stepsLast7, energySeries: overview.activeEnergyLast7)
        } label: {
            ActivityRingsCard(activity: overview.activity)
        }
        .buttonStyle(.plain)
    }

    // MARK: Heart

    private var heartCard: some View {
        NavigationLink {
            // Reuse the existing deep heart tab for the detail.
            DashboardView()
        } label: {
            CategoryCard(
                icon: "heart.fill",
                iconTint: .pink,
                title: "Heart"
            ) {
                if overview.heart.hasAny {
                    VStack(alignment: .leading, spacing: 10) {
                        heartHero

                        rowLayout {
                            miniStat("Resting", value: HealthFormat.int(overview.heart.restingBPM), unit: "bpm",
                                     spokenTitle: "Resting heart rate", asOf: overview.heart.restingAt)
                            miniStat("HRV", value: HealthFormat.int(overview.heart.hrvMs), unit: "ms",
                                     spokenTitle: "Heart rate variability", asOf: overview.heart.hrvAt)
                            miniStat("Walking HR", value: HealthFormat.int(overview.heart.walkingHRAvg), unit: "bpm",
                                     spokenTitle: "Walking heart rate average", asOf: overview.heart.walkingHRAt)
                        }

                        if !overview.restingHRLast14.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                TrendSparkline(points: overview.restingHRLast14, color: .pink)
                                    .frame(height: 36)
                                Text("Resting HR · last 14 days")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel(restingTrendDescription)
                            }
                            .padding(.top, 4)
                        }
                    }
                } else {
                    Text("No heart data yet. Wear Apple Watch to record heart rate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var heartHero: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let bpm = overview.heart.latestBPM {
                Text(HealthFormat.int(bpm))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(.pink)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityLabel("Latest heart rate, \(HealthFormat.int(bpm)) beats per minute")
                Text("BPM")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            } else {
                Text(HealthFormat.missing)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(.pink)
                    .accessibilityLabel("No recent heart rate")
            }
            Spacer()
            if let date = overview.heart.latestBPMAt {
                SampleAgeText(date: date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .animation(.default, value: overview.heart.latestBPM)
    }

    private var restingTrendDescription: String {
        let values = overview.restingHRLast14.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return "Resting heart rate, last 14 days" }
        return "Resting heart rate over the last 14 days, between \(HealthFormat.int(lo)) and \(HealthFormat.int(hi)) beats per minute"
    }

    // MARK: Sleep

    @ViewBuilder
    private var sleepCard: some View {
        if let sleep = overview.sleep {
            NavigationLink {
                SleepDetailView(sleep: sleep)
            } label: {
                CategoryCard(
                    icon: "bed.double.fill",
                    iconTint: .indigo,
                    title: "Sleep"
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            DurationHero(
                                seconds: sleep.totalSeconds,
                                numberFont: .system(.largeTitle, design: .rounded, weight: .bold),
                                unitFont: .title3.weight(.semibold),
                                tint: .indigo
                            )
                            Text(sleep.isInBedOnly ? "in bed last night" : "asleep last night")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .animation(.default, value: sleep.totalSeconds)

                        SleepPhaseBar(sleep: sleep)
                            .frame(height: 10)

                        phaseLegend(sleep)

                        if let bed = sleep.bedtime, let wake = sleep.wakeTime {
                            HStack(spacing: 16) {
                                scheduleLabel("Bedtime", date: bed, icon: "moon.fill")
                                Spacer()
                                scheduleLabel("Wake", date: wake, icon: "sun.max.fill")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        } else {
            // Not a link: there's nothing to open.
            CategoryCard(
                icon: "bed.double",
                iconTint: .indigo,
                title: "Sleep",
                showsChevron: false
            ) {
                Text("No recent sleep session found. Wear your Apple Watch to bed, or log sleep in Health.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One row while it fits; two columns, then a single column, when the
    /// text is too large for up to five labels side by side.
    private func phaseLegend(_ sleep: SleepSummary) -> some View {
        let phases = legendPhases(for: sleep)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                ForEach(phases, id: \.self) { phase in
                    phaseLabel(phase, seconds: phase.duration(in: sleep))
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(Array(stride(from: 0, to: phases.count, by: 2)), id: \.self) { i in
                    GridRow {
                        phaseLabel(phases[i], seconds: phases[i].duration(in: sleep))
                        if i + 1 < phases.count {
                            phaseLabel(phases[i + 1], seconds: phases[i + 1].duration(in: sleep))
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(phases, id: \.self) { phase in
                    phaseLabel(phase, seconds: phase.duration(in: sleep))
                }
            }
        }
    }

    private func legendPhases(for sleep: SleepSummary) -> [SleepPhase] {
        var phases: [SleepPhase] = sleep.hasStages ? [.core, .deep, .rem] : []
        if sleep.unspecified > 0 { phases.append(.asleep) }
        phases.append(.awake)
        return phases
    }

    // MARK: Metrics Grid — primary tiles

    private var metricsGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: 12) {
            NavigationLink {
                MetricDetailView(
                    title: "Steps",
                    icon: "figure.walk",
                    tint: .green,
                    unit: "steps",
                    kind: .cumulative,
                    todayValue: overview.activity.steps.map { Double($0) },
                    last7: overview.stepsLast7
                )
            } label: {
                MetricCard(
                    icon: "figure.walk",
                    tint: .green,
                    title: "Steps",
                    value: HealthFormat.steps(overview.activity.steps),
                    unit: "steps",
                    sparkline: completedDaysSparkline(overview.stepsLast7),
                    sparkColor: .green,
                    subtitle: HealthOverview.completedDayAverage(overview.stepsLast7).map {
                        "Daily avg \(HealthFormat.number($0))"
                    },
                    isNavigable: true
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                MetricDetailView(
                    title: "Active Energy",
                    icon: "flame.fill",
                    tint: .orange,
                    unit: "kcal",
                    kind: .cumulative,
                    todayValue: overview.activity.activeEnergyKcal,
                    last7: overview.activeEnergyLast7
                )
            } label: {
                MetricCard(
                    icon: "flame.fill",
                    tint: .orange,
                    title: "Active Energy",
                    value: HealthFormat.number(overview.activity.activeEnergyKcal),
                    unit: "kcal",
                    sparkline: completedDaysSparkline(overview.activeEnergyLast7),
                    sparkColor: .orange,
                    subtitle: overview.activity.basalEnergyKcal.map { "+ \(HealthFormat.kcal($0)) basal" },
                    isNavigable: true
                )
            }
            .buttonStyle(.plain)

            if overview.respiratory.oxygenSaturation != nil {
                MetricCard(
                    icon: "lungs.fill",
                    tint: .teal,
                    title: "Blood Oxygen",
                    value: HealthFormat.percent(overview.respiratory.oxygenSaturation),
                    unit: "",
                    sparkline: [],
                    sparkColor: .teal,
                    subtitle: overview.respiratory.respiratoryRate.map {
                        "\(HealthFormat.int($0)) breaths / min"
                    },
                    asOf: overview.respiratory.oxygenSaturationAt
                )
            }

            if overview.respiratory.respiratoryRate != nil
                && overview.respiratory.oxygenSaturation == nil {
                MetricCard(
                    icon: "wind",
                    tint: .cyan,
                    title: "Respiratory",
                    value: HealthFormat.one(overview.respiratory.respiratoryRate),
                    unit: "br/min",
                    sparkline: [],
                    sparkColor: .cyan,
                    subtitle: nil,
                    asOf: overview.respiratory.respiratoryRateAt
                )
            }

            if let vo2 = overview.heart.vo2Max {
                MetricCard(
                    icon: "bolt.heart.fill",
                    tint: .purple,
                    title: "VO₂ Max",
                    value: HealthFormat.number(vo2, fraction: 1),
                    unit: "mL/kg/min",
                    sparkline: [],
                    sparkColor: .purple,
                    subtitle: "Cardio fitness",
                    asOf: overview.heart.vo2At
                )
            }

            if overview.body.weightKg != nil {
                let weight = HealthFormat.mass(overview.body.weightKg)
                NavigationLink {
                    BodyDetailView(snapshot: overview.body, weightSeries: overview.weightLast30)
                } label: {
                    MetricCard(
                        icon: "scalemass.fill",
                        tint: .brown,
                        title: "Body",
                        value: weight.value,
                        unit: weight.unit,
                        sparkline: overview.weightLast30,
                        sparkColor: .brown,
                        subtitle: overview.body.bmi.map { "BMI \(HealthFormat.number($0, fraction: 1))" },
                        isNavigable: true,
                        asOf: overview.body.weightAt
                    )
                }
                .buttonStyle(.plain)
            }

            if overview.mindfulness.hasAny {
                MetricCard(
                    icon: "brain.head.profile",
                    tint: .pink,
                    title: "Mindful",
                    value: HealthFormat.number(overview.mindfulness.todayMinutes),
                    unit: "min",
                    sparkline: [],
                    sparkColor: .pink,
                    subtitle: "today"
                )
            }

            if let water = overview.nutrition.waterMl, water > 0 {
                MetricCard(
                    icon: "drop.fill",
                    tint: .blue,
                    title: "Water",
                    value: HealthFormat.number(water),
                    unit: "mL",
                    sparkline: [],
                    sparkColor: .blue,
                    subtitle: nil
                )
            }
        }
    }

    /// Today's partial total would dip at the right edge every morning, and an
    /// all-zero week means nothing was recorded — draw no line for that.
    private func completedDaysSparkline(_ points: [MetricPoint]) -> [MetricPoint] {
        let past = points.filter { !Calendar.current.isDateInToday($0.date) }
        return HealthOverview.hasData(past) ? past : []
    }

    // MARK: Secondary sections — mobility, hearing, nutrition, body

    /// One small tile in the lower sections. Built as data so a section can
    /// hide itself (heading included) when it has nothing to show.
    private struct MiniTile: Identifiable {
        let icon: String
        let tint: Color
        let title: String
        let measure: FormattedMeasure
        var asOf: Date? = nil
        var id: String { title }
    }

    @ViewBuilder
    private var secondarySections: some View {
        tileSection("Mobility", tiles: mobilityTiles)
        tileSection("Hearing", tiles: hearingTiles)
        tileSection("Nutrition", tiles: nutritionTiles)
        tileSection("Body Measurements", tiles: bodyTiles)
    }

    @ViewBuilder
    private func tileSection(_ title: LocalizedStringKey, tiles: [MiniTile]) -> some View {
        if !tiles.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                    .padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)

                LazyVGrid(columns: gridColumns, spacing: 12) {
                    ForEach(tiles) { tile in
                        MiniMetricTile(
                            icon: tile.icon,
                            tint: tile.tint,
                            title: tile.title,
                            value: tile.measure.value,
                            unit: tile.measure.unit,
                            asOf: tile.asOf
                        )
                    }
                }
            }
        }
    }

    private var mobilityTiles: [MiniTile] {
        let m = overview.mobility
        var tiles: [MiniTile] = []
        if m.walkingSpeed != nil {
            tiles.append(MiniTile(icon: "figure.walk.motion", tint: .green, title: "Walking Speed",
                                  measure: HealthFormat.walkingSpeed(m.walkingSpeed), asOf: m.walkingSpeedAt))
        }
        if m.walkingStepLength != nil {
            tiles.append(MiniTile(icon: "ruler", tint: .green, title: "Step Length",
                                  measure: HealthFormat.stepLength(m.walkingStepLength), asOf: m.walkingStepLengthAt))
        }
        if let v = m.walkingAsymmetryPercent {
            tiles.append(MiniTile(icon: "arrow.left.arrow.right", tint: .teal, title: "Asymmetry",
                                  measure: FormattedMeasure(value: HealthFormat.percent(v), unit: ""), asOf: m.walkingAsymmetryAt))
        }
        if m.stairAscentSpeed != nil {
            tiles.append(MiniTile(icon: "figure.stair.stepper", tint: .mint, title: "Stair Ascent",
                                  measure: HealthFormat.stairSpeed(m.stairAscentSpeed), asOf: m.stairAscentSpeedAt))
        }
        return tiles
    }

    /// Both are averages over the last 24 hours, so the titles say so.
    private var hearingTiles: [MiniTile] {
        let a = overview.audio
        var tiles: [MiniTile] = []
        if let v = a.headphoneDBA {
            tiles.append(MiniTile(icon: "airpodsmax", tint: .purple, title: "Headphones (24h)",
                                  measure: FormattedMeasure(value: HealthFormat.number(v), unit: "dBA")))
        }
        if let v = a.environmentalDBA {
            tiles.append(MiniTile(icon: "speaker.wave.3.fill", tint: .purple, title: "Noise (24h)",
                                  measure: FormattedMeasure(value: HealthFormat.number(v), unit: "dBA")))
        }
        return tiles
    }

    private var nutritionTiles: [MiniTile] {
        let n = overview.nutrition
        var tiles: [MiniTile] = []
        if let v = n.dietaryEnergyKcal, v > 0 {
            tiles.append(MiniTile(icon: "fork.knife", tint: .orange, title: "Calories In",
                                  measure: FormattedMeasure(value: HealthFormat.number(v), unit: "kcal")))
        }
        if let v = n.caffeineMg, v > 0 {
            tiles.append(MiniTile(icon: "cup.and.saucer.fill", tint: .brown, title: "Caffeine",
                                  measure: FormattedMeasure(value: HealthFormat.number(v), unit: "mg")))
        }
        if let v = n.proteinG, v > 0 {
            tiles.append(MiniTile(icon: "leaf.fill", tint: .green, title: "Protein",
                                  measure: FormattedMeasure(value: HealthFormat.number(v), unit: "g")))
        }
        return tiles
    }

    private var bodyTiles: [MiniTile] {
        let b = overview.body
        // The Body tile and its detail screen already show these.
        guard b.weightKg == nil else { return [] }
        var tiles: [MiniTile] = []
        if b.heightCm != nil {
            tiles.append(MiniTile(icon: "ruler.fill", tint: .gray, title: "Height",
                                  measure: HealthFormat.height(b.heightCm)))
        }
        if let v = b.bodyFatPercent {
            tiles.append(MiniTile(icon: "percent", tint: .brown, title: "Body Fat",
                                  measure: FormattedMeasure(value: HealthFormat.percent(v), unit: "")))
        }
        if b.leanBodyMassKg != nil {
            tiles.append(MiniTile(icon: "figure.arms.open", tint: .gray, title: "Lean Mass",
                                  measure: HealthFormat.mass(b.leanBodyMassKg)))
        }
        return tiles
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        if viewModel.hasLoaded {
            // Once a minute is enough; a ticking seconds counter is distracting.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text("Data from Apple Health • Updated \(updatedLabel(now: context.date))")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
        }
    }

    private func updatedLabel(now: Date) -> String {
        let generatedAt = viewModel.overview.generatedAt
        if now.timeIntervalSince(generatedAt) < 60 { return "just now" }
        return generatedAt.formatted(.relative(presentation: .named))
    }

    // MARK: Shared helpers

    private func miniStat(_ title: String, value: String, unit: String, spokenTitle: String, asOf: Date? = nil) -> some View {
        let stale = HealthOverview.isStale(asOf)
        return VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(stale ? Color.secondary : Color.primary)
                if !unit.isEmpty && value != HealthFormat.missing {
                    Text(unit).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if stale, let asOf {
                SampleDateCaption(date: asOf)
            }
        }
        // Inside the card's link, so one combined label rather than label + value.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            [spokenTitle, HealthFormat.spoken(value, unit: unit), SampleDateCaption.spoken(asOf)]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }

    private func phaseLabel(_ phase: SleepPhase, seconds: TimeInterval) -> some View {
        HStack(spacing: 5) {
            Circle().fill(phase.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                Text(phase.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(HealthFormat.duration(seconds))
                    .font(.caption.monospacedDigit().weight(.medium))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(phase.label), \(HealthFormat.spokenDuration(seconds))")
    }

    @ViewBuilder
    private func scheduleLabel(_ title: String, date: Date, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(date, format: .dateTime.hour().minute())
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Sleep phase helper

enum SleepPhase {
    case core, deep, rem, asleep, awake, inBed
    var label: String {
        switch self {
        case .core: return "Core"
        case .deep: return "Deep"
        case .rem:  return "REM"
        case .asleep: return "Asleep"
        case .awake: return "Awake"
        case .inBed: return "In Bed"
        }
    }
    var color: Color {
        switch self {
        case .core: return .blue
        case .deep: return .indigo
        case .rem:  return .mint
        case .asleep: return .cyan
        case .awake: return .pink.opacity(0.7)
        case .inBed: return .gray
        }
    }
    func duration(in sleep: SleepSummary) -> TimeInterval {
        switch self {
        case .core: return sleep.core
        case .deep: return sleep.deep
        case .rem:  return sleep.rem
        case .asleep: return sleep.unspecified
        case .awake: return sleep.awake
        case .inBed: return sleep.inBed
        }
    }
}

// MARK: - Cards

struct ActivityRingsCard: View {
    let activity: ActivitySnapshot
    /// Off where the card isn't a link (e.g. on the Activity detail screen).
    var showsChevron: Bool = true
    /// Steps / Distance / Floors; off where a fuller grid follows.
    var showsSummaryRow: Bool = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.redactionReasons) private var redactionReasons

    /// Goals only come from the Activity summary (Apple Watch or Fitness).
    /// Without them every ring would sit empty next to real numbers.
    /// The loading skeleton still shows the empty tracks.
    private var showsRings: Bool {
        activity.hasGoals || redactionReasons.contains(.placeholder)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "figure.run")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                Text("Activity")
                    .font(.headline)
                Spacer()
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .unredacted()

            if showsRings {
                ringsLayout {
                    ActivityRings(activity: activity)
                        .frame(width: 120, height: 120)
                    ringStats
                }
            } else {
                Text("Rings appear once Apple Watch or the Fitness app sets your goals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ringStats
            }

            if showsSummaryRow {
                summaryLayout {
                    miniMetric("Steps", value: HealthFormat.steps(activity.steps), unit: "")
                    let distance = HealthFormat.distance(activity.distanceKm)
                    miniMetric("Distance", value: distance.value, unit: distance.unit)
                    miniMetric("Floors", value: HealthFormat.number(activity.flightsClimbed.map { Double($0) }), unit: "")
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    /// Rings beside the stats normally; above them at accessibility sizes so
    /// "412 / 600 kcal" isn't squeezed.
    private var ringsLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 18))
    }

    private var summaryLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    /// A grid instead of fixed-width labels, so "Exercise" never truncates.
    private var ringStats: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
            ringStat(color: .red, label: "Move", current: activity.activeEnergyKcal, goal: activity.moveGoalKcal, unit: "kcal")
            ringStat(color: .green, label: "Exercise", current: activity.exerciseMinutes.map(Double.init), goal: activity.exerciseGoalMinutes, unit: "min")
            ringStat(color: .blue, label: "Stand", current: activity.standHours.map(Double.init), goal: activity.standGoalHours, unit: "hr")
        }
    }

    /// The label is neutral text with a colored dot: red / green / blue
    /// caption text is too low-contrast on the white card.
    private func ringStat(color: Color, label: String, current: Double?, goal: Double?, unit: String) -> some View {
        GridRow {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(HealthFormat.number(current))
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .accessibilityLabel(current == nil ? "no data" : HealthFormat.number(current))
            Text(goal.map { "/ \(HealthFormat.number($0)) \(unit)" } ?? unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel(
                    goal.map { "of \(HealthFormat.number($0)) \(HealthFormat.spokenUnit(unit))" }
                        ?? HealthFormat.spokenUnit(unit)
                )
        }
    }

    private func miniMetric(_ label: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                if !unit.isEmpty && value != HealthFormat.missing {
                    Text(unit).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(HealthFormat.spoken(value, unit: unit))")
    }
}

/// Three concentric rings (Move / Exercise / Stand).
struct ActivityRings: View {
    let activity: ActivitySnapshot

    var body: some View {
        ZStack {
            ring(
                progress: safeProgress(activity.activeEnergyKcal, activity.moveGoalKcal),
                color: .red,
                lineWidth: 12,
                radius: 55
            )
            ring(
                progress: safeProgress(activity.exerciseMinutes.map(Double.init), activity.exerciseGoalMinutes),
                color: .green,
                lineWidth: 12,
                radius: 41
            )
            ring(
                progress: safeProgress(activity.standHours.map(Double.init), activity.standGoalHours),
                color: .blue,
                lineWidth: 12,
                radius: 27
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity rings")
        .accessibilityValue(ringSummary)
        .accessibilityHidden(ringSummary.isEmpty)
    }

    /// "Move 69 percent, Exercise 140 percent" — only rings that have a goal.
    private var ringSummary: String {
        let rings: [(name: String, current: Double?, goal: Double?)] = [
            ("Move", activity.activeEnergyKcal, activity.moveGoalKcal),
            ("Exercise", activity.exerciseMinutes.map { Double($0) }, activity.exerciseGoalMinutes),
            ("Stand", activity.standHours.map { Double($0) }, activity.standGoalHours),
        ]
        var parts: [String] = []
        for ring in rings {
            guard let goal = ring.goal, goal > 0 else { continue }
            let percent = Int(((ring.current ?? 0) / goal * 100).rounded())
            parts.append("\(ring.name) \(percent) percent")
        }
        return parts.joined(separator: ", ")
    }

    private func ring(progress: Double, color: Color, lineWidth: CGFloat, radius: CGFloat) -> some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.18), lineWidth: lineWidth)
                .frame(width: radius * 2, height: radius * 2)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: radius * 2, height: radius * 2)
                .animation(.easeOut(duration: 0.7), value: progress)
        }
    }

    private func safeProgress(_ current: Double?, _ goal: Double?) -> Double {
        guard let current, let goal, goal > 0 else { return 0 }
        return current / goal
    }
}

/// Reusable outer card frame used by sleep/heart sections.
struct CategoryCard<Content: View>: View {
    let icon: String
    let iconTint: Color
    let title: String
    /// Only where the card is wrapped in a NavigationLink.
    var showsChevron: Bool = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(iconTint)
                Text(title)
                    .font(.headline)
                Spacer()
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .unredacted()
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

/// Medium-sized metric card with big value + sparkline + optional subtitle.
struct MetricCard: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let unit: String
    let sparkline: [MetricPoint]
    let sparkColor: Color
    let subtitle: String?
    /// Draws a chevron. Set it only when the card is wrapped in a NavigationLink.
    var isNavigable: Bool = false
    /// Sample date of a "most recent" value, so an old reading isn't taken
    /// for today's.
    var asOf: Date? = nil

    var body: some View {
        let stale = HealthOverview.isStale(asOf)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                // Neutral text: the tints are too light for caption text.
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if isNavigable {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .unredacted()

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(stale ? Color.secondary : Color.primary)
                if !unit.isEmpty && value != HealthFormat.missing {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if stale, let asOf {
                SampleDateCaption(date: asOf)
            }

            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !sparkline.isEmpty {
                TrendSparkline(points: sparkline, color: sparkColor)
                    .frame(height: 28)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .cardBackground()
        .accessibilityElement(children: .ignore)
        // A link's label already becomes one button, so fold the value into it.
        .accessibilityLabel(isNavigable ? "\(title), \(spokenValue)" : title)
        .accessibilityValue(isNavigable ? "" : spokenValue)
    }

    private var spokenValue: String {
        [HealthFormat.spoken(value, unit: unit), SampleDateCaption.spoken(asOf), subtitle]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// Tiny dense tile for secondary metrics.
struct MiniMetricTile: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let unit: String
    /// Sample date of a "most recent" value; old readings are dimmed.
    var asOf: Date? = nil

    var body: some View {
        let stale = HealthOverview.isStale(asOf)
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.18))
                Image(systemName: icon)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(stale ? Color.secondary : Color.primary)
                    if !unit.isEmpty && value != HealthFormat.missing {
                        Text(unit).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if stale, let asOf {
                    SampleDateCaption(date: asOf)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(
            [HealthFormat.spoken(value, unit: unit), SampleDateCaption.spoken(asOf)]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }
}

/// A sleep duration as large digits with small grey unit letters ("7h 30m"),
/// so it can't be read as a clock time next to bedtime and wake times.
struct DurationHero: View {
    let seconds: TimeInterval
    let numberFont: Font
    let unitFont: Font
    let tint: Color

    var body: some View {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            if hours > 0 {
                Text("\(hours)")
                    .font(numberFont)
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                Text("h")
                    .font(unitFont)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 4)
            }
            Text("\(minutes)")
                .font(numberFont)
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text("m")
                .font(unitFont)
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HealthFormat.spokenDuration(seconds))
    }
}

/// "2 min. ago" / "Yesterday", refreshed once a minute. Under a minute it
/// says "Just now" rather than a seconds count that would sit frozen.
struct SampleAgeText: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(Self.label(for: date, now: context.date))
        }
    }

    static func label(for date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "Just now" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

/// Small "3 days ago" under a value whose latest sample is over a day old.
struct SampleDateCaption: View {
    let date: Date

    var body: some View {
        Text(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// "measured 3 days ago" for VoiceOver, or nil when the value is recent.
    static func spoken(_ date: Date?) -> String? {
        guard let date, HealthOverview.isStale(date) else { return nil }
        return "measured \(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))"
    }
}

/// Compact sparkline used on cards. The y-axis is fitted to the data so a
/// resting HR moving between 55 and 62 is visible instead of a flat line.
struct TrendSparkline: View {
    let points: [MetricPoint]
    let color: Color

    var body: some View {
        let domain = yDomain
        Chart {
            ForEach(points) { p in
                AreaMark(
                    x: .value("date", p.date),
                    yStart: .value("base", domain.lowerBound),
                    yEnd: .value("value", p.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(
                    colors: [color.opacity(0.35), color.opacity(0)],
                    startPoint: .top, endPoint: .bottom
                ))
                LineMark(x: .value("date", p.date), y: .value("value", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            if points.count == 1, let only = points.first {
                PointMark(x: .value("date", only.date), y: .value("value", only.value))
                    .foregroundStyle(color)
                    .symbolSize(16)
            }
        }
        .chartYScale(domain: domain)
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        .chartPlotStyle { plot in
            plot.padding(.vertical, 2)
        }
        .accessibilityHidden(true)
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        if hi - lo < 0.0001 {
            // Flat series: centre it.
            let pad = max(abs(hi) * 0.05, 1)
            return (lo - pad)...(hi + pad)
        }
        let pad = (hi - lo) * 0.15
        // Counts (steps, kcal) never go below zero.
        let lower = lo >= 0 ? max(0, lo - pad) : lo - pad
        return lower...(hi + pad)
    }
}

/// Horizontal sleep phase stacked bar.
struct SleepPhaseBar: View {
    let sleep: SleepSummary
    /// `.redacted` doesn't mask shapes, so the loading skeleton greys them here.
    @Environment(\.redactionReasons) private var redactionReasons

    var body: some View {
        GeometryReader { geo in
            let parts: [(Color, TimeInterval)] = sleep.isInBedOnly
                ? [(SleepPhase.inBed.color, sleep.inBed)]
                : [
                    (SleepPhase.awake.color, sleep.awake),
                    (SleepPhase.core.color, sleep.core),
                    (SleepPhase.deep.color, sleep.deep),
                    (SleepPhase.rem.color, sleep.rem),
                    (SleepPhase.asleep.color, sleep.unspecified),
                ]
            let visible = parts.filter { $0.1 > 0 }
            let total = max(visible.reduce(0) { $0 + $1.1 }, 1)
            let spacing: CGFloat = 1
            let usable = max(0, geo.size.width - spacing * CGFloat(max(visible.count - 1, 0)))
            let isPlaceholder = redactionReasons.contains(.placeholder)
            HStack(spacing: spacing) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, part in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(isPlaceholder ? Color(.systemFill) : part.0)
                        .frame(width: usable * CGFloat(part.1 / total))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    OverviewView()
        .environmentObject(HealthOverviewViewModel.preview)
        .environmentObject(UserProfile.shared)
        .environmentObject(HeartRateViewModel.preview)
        .environmentObject(AppRouter.shared)
        .environmentObject(NotificationPermission.shared)
}
