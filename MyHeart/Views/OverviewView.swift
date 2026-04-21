import SwiftUI
import Charts

/// The home tab — a scrollable "Today" overview pulling every category
/// HealthKit exposes. Each card drills into a category-specific detail view.
struct OverviewView: View {
    @EnvironmentObject private var viewModel: HealthOverviewViewModel
    @EnvironmentObject private var profile: UserProfile
    @EnvironmentObject private var heartVM: HeartRateViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header
                    activityCard
                    heartCard
                    sleepCard
                    metricsGrid
                    secondaryGrid
                    footer
                }
                .padding(.horizontal)
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Health")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        Task { await viewModel.refresh() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .refreshable { await viewModel.refresh() }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Date(), format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("Today")
                .font(.largeTitle.bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Activity

    private var activityCard: some View {
        NavigationLink {
            ActivityDetailView(snapshot: viewModel.overview.activity, stepsSeries: viewModel.overview.stepsLast7, energySeries: viewModel.overview.activeEnergyLast7)
        } label: {
            ActivityRingsCard(activity: viewModel.overview.activity)
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
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(viewModel.overview.heart.latestBPM.map { "\(Int($0.rounded()))" } ?? "—")
                            .font(.system(size: 36, weight: .bold, design: .rounded))
                            .foregroundStyle(.pink)
                            .monospacedDigit()
                        Text("BPM")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let date = viewModel.overview.heart.latestBPMAt {
                            Text(date, style: .relative)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack(spacing: 14) {
                        miniStat("Resting", value: HealthFormat.int(viewModel.overview.heart.restingBPM), unit: "bpm")
                        miniStat("HRV", value: HealthFormat.int(viewModel.overview.heart.hrvMs), unit: "ms")
                        miniStat("Walking", value: HealthFormat.int(viewModel.overview.heart.walkingHRAvg), unit: "bpm")
                        miniStat("VO₂", value: HealthFormat.one(viewModel.overview.heart.vo2Max), unit: "")
                    }

                    if !viewModel.overview.restingHRLast14.isEmpty {
                        TrendSparkline(points: viewModel.overview.restingHRLast14, color: .pink)
                            .frame(height: 36)
                            .padding(.top, 4)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Sleep

    @ViewBuilder
    private var sleepCard: some View {
        if let sleep = viewModel.overview.sleep {
            NavigationLink {
                SleepDetailView(sleep: sleep)
            } label: {
                CategoryCard(
                    icon: "bed.double.fill",
                    iconTint: .indigo,
                    title: "Sleep"
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(DurationFormat.hoursMinutes(sleep.totalSeconds))
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                                .foregroundStyle(.indigo)
                                .monospacedDigit()
                            Text("asleep last night")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        SleepPhaseBar(sleep: sleep)
                            .frame(height: 10)

                        HStack(spacing: 14) {
                            phaseLabel(.core, seconds: sleep.core)
                            phaseLabel(.deep, seconds: sleep.deep)
                            phaseLabel(.rem,  seconds: sleep.rem)
                            phaseLabel(.awake, seconds: sleep.awake)
                        }

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
            CategoryCard(
                icon: "bed.double",
                iconTint: .indigo,
                title: "Sleep"
            ) {
                Text("No recent sleep session found. Wear your Apple Watch to bed, or log sleep in Health.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Metrics Grid — primary tiles

    private var metricsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            NavigationLink {
                MetricDetailView(
                    title: "Steps",
                    icon: "figure.walk",
                    tint: .green,
                    unit: "steps",
                    kind: .cumulative,
                    todayValue: viewModel.overview.activity.steps.map { Double($0) },
                    last7: viewModel.overview.stepsLast7
                )
            } label: {
                MetricCard(
                    icon: "figure.walk",
                    tint: .green,
                    title: "Steps",
                    value: HealthFormat.steps(viewModel.overview.activity.steps),
                    unit: "steps",
                    sparkline: viewModel.overview.stepsLast7,
                    sparkColor: .green,
                    subtitle: viewModel.overview.activity.distanceKm.map { HealthFormat.km($0) }
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
                    todayValue: viewModel.overview.activity.activeEnergyKcal,
                    last7: viewModel.overview.activeEnergyLast7
                )
            } label: {
                MetricCard(
                    icon: "flame.fill",
                    tint: .orange,
                    title: "Active Energy",
                    value: HealthFormat.kcal(viewModel.overview.activity.activeEnergyKcal),
                    unit: "",
                    sparkline: viewModel.overview.activeEnergyLast7,
                    sparkColor: .orange,
                    subtitle: viewModel.overview.activity.basalEnergyKcal.map { "+ \(HealthFormat.kcal($0)) basal" }
                )
            }
            .buttonStyle(.plain)

            if viewModel.overview.respiratory.oxygenSaturation != nil {
                MetricCard(
                    icon: "lungs.fill",
                    tint: .teal,
                    title: "Blood Oxygen",
                    value: HealthFormat.percent(viewModel.overview.respiratory.oxygenSaturation),
                    unit: "",
                    sparkline: [],
                    sparkColor: .teal,
                    subtitle: viewModel.overview.respiratory.respiratoryRate.map {
                        "\(Int($0.rounded())) breaths / min"
                    }
                )
            }

            if viewModel.overview.respiratory.respiratoryRate != nil
                && viewModel.overview.respiratory.oxygenSaturation == nil {
                MetricCard(
                    icon: "wind",
                    tint: .cyan,
                    title: "Respiratory",
                    value: HealthFormat.one(viewModel.overview.respiratory.respiratoryRate),
                    unit: "br/min",
                    sparkline: [],
                    sparkColor: .cyan,
                    subtitle: nil
                )
            }

            if let vo2 = viewModel.overview.heart.vo2Max {
                MetricCard(
                    icon: "bolt.heart.fill",
                    tint: .purple,
                    title: "VO₂ Max",
                    value: String(format: "%.1f", vo2),
                    unit: "ml/kg·min",
                    sparkline: [],
                    sparkColor: .purple,
                    subtitle: vo2FitnessLevel(vo2)
                )
            }

            if let flights = viewModel.overview.activity.flightsClimbed, flights > 0 {
                MetricCard(
                    icon: "figure.stairs",
                    tint: .mint,
                    title: "Floors Climbed",
                    value: "\(flights)",
                    unit: "floors",
                    sparkline: [],
                    sparkColor: .mint,
                    subtitle: nil
                )
            }

            if viewModel.overview.body.weightKg != nil {
                NavigationLink {
                    BodyDetailView(snapshot: viewModel.overview.body, weightSeries: viewModel.overview.weightLast30)
                } label: {
                    MetricCard(
                        icon: "scalemass.fill",
                        tint: .brown,
                        title: "Body",
                        value: HealthFormat.kg(viewModel.overview.body.weightKg),
                        unit: "",
                        sparkline: viewModel.overview.weightLast30,
                        sparkColor: .brown,
                        subtitle: viewModel.overview.body.bmi.map { "BMI \(String(format: "%.1f", $0))" }
                    )
                }
                .buttonStyle(.plain)
            }

            if viewModel.overview.mindfulness.hasAny {
                MetricCard(
                    icon: "brain.head.profile",
                    tint: .pink,
                    title: "Mindful",
                    value: HealthFormat.minutes(viewModel.overview.mindfulness.todayMinutes),
                    unit: "",
                    sparkline: [],
                    sparkColor: .pink,
                    subtitle: "today"
                )
            }

            if let water = viewModel.overview.nutrition.waterMl, water > 0 {
                MetricCard(
                    icon: "drop.fill",
                    tint: .blue,
                    title: "Water",
                    value: "\(Int(water.rounded()))",
                    unit: "mL",
                    sparkline: [],
                    sparkColor: .blue,
                    subtitle: nil
                )
            }
        }
    }

    // MARK: Secondary Grid — mobility, audio, nutrition

    private var secondaryGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("More")
                .font(.headline)
                .padding(.leading, 4)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                if let v = viewModel.overview.mobility.walkingSpeed {
                    MiniMetricTile(icon: "figure.walk.motion", tint: .green, title: "Walking Speed", value: String(format: "%.2f", v), unit: "m/s")
                }
                if let v = viewModel.overview.mobility.walkingStepLength {
                    MiniMetricTile(icon: "ruler", tint: .green, title: "Step Length", value: String(format: "%.0f", v * 100), unit: "cm")
                }
                if let v = viewModel.overview.mobility.walkingAsymmetryPercent {
                    MiniMetricTile(icon: "arrow.left.arrow.right", tint: .teal, title: "Asymmetry", value: HealthFormat.percent(v), unit: "")
                }
                if let v = viewModel.overview.mobility.stairAscentSpeed {
                    MiniMetricTile(icon: "figure.stair.stepper", tint: .mint, title: "Stair Ascent", value: String(format: "%.2f", v), unit: "m/s")
                }
                if let v = viewModel.overview.audio.headphoneDBA {
                    MiniMetricTile(icon: "airpodsmax", tint: .purple, title: "Headphones", value: "\(Int(v.rounded()))", unit: "dBA")
                }
                if let v = viewModel.overview.audio.environmentalDBA {
                    MiniMetricTile(icon: "speaker.wave.3.fill", tint: .purple, title: "Environment", value: "\(Int(v.rounded()))", unit: "dBA")
                }
                if let v = viewModel.overview.nutrition.dietaryEnergyKcal, v > 0 {
                    MiniMetricTile(icon: "fork.knife", tint: .orange, title: "Calories In", value: "\(Int(v.rounded()))", unit: "kcal")
                }
                if let v = viewModel.overview.nutrition.caffeineMg, v > 0 {
                    MiniMetricTile(icon: "cup.and.saucer.fill", tint: .brown, title: "Caffeine", value: "\(Int(v.rounded()))", unit: "mg")
                }
                if let v = viewModel.overview.nutrition.proteinG, v > 0 {
                    MiniMetricTile(icon: "leaf.fill", tint: .green, title: "Protein", value: "\(Int(v.rounded()))", unit: "g")
                }
                if let v = viewModel.overview.body.heightCm {
                    MiniMetricTile(icon: "ruler.fill", tint: .gray, title: "Height", value: String(format: "%.0f", v), unit: "cm")
                }
                if let v = viewModel.overview.body.bodyFatPercent {
                    MiniMetricTile(icon: "percent", tint: .brown, title: "Body Fat", value: HealthFormat.percent(v), unit: "")
                }
                if let v = viewModel.overview.body.leanBodyMassKg {
                    MiniMetricTile(icon: "figure.arms.open", tint: .gray, title: "Lean Mass", value: HealthFormat.kg(v), unit: "")
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        Text("Data from Apple Health • Updated \(viewModel.overview.generatedAt, style: .relative) ago")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
    }

    // MARK: Shared helpers

    @ViewBuilder
    private func miniStat(_ title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                if !unit.isEmpty {
                    Text(unit).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func phaseLabel(_ phase: SleepPhase, seconds: TimeInterval) -> some View {
        HStack(spacing: 5) {
            Circle().fill(phase.color).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                Text(phase.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(DurationFormat.hoursMinutes(seconds))
                    .font(.caption.monospacedDigit().weight(.medium))
            }
        }
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

    private func vo2FitnessLevel(_ vo2: Double) -> String {
        switch vo2 {
        case ..<28: return "Low"
        case 28..<35: return "Below Average"
        case 35..<42: return "Average"
        case 42..<50: return "Above Average"
        default:      return "Excellent"
        }
    }
}

// MARK: - Sleep phase helper

enum SleepPhase {
    case core, deep, rem, awake, inBed
    var label: String {
        switch self {
        case .core: return "Core"
        case .deep: return "Deep"
        case .rem:  return "REM"
        case .awake: return "Awake"
        case .inBed: return "In Bed"
        }
    }
    var color: Color {
        switch self {
        case .core: return .blue
        case .deep: return .indigo
        case .rem:  return .mint
        case .awake: return .pink.opacity(0.7)
        case .inBed: return .gray
        }
    }
}

// MARK: - Cards

struct ActivityRingsCard: View {
    let activity: ActivitySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "figure.run")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.red)
                Text("Activity")
                    .font(.headline)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 18) {
                ActivityRings(activity: activity)
                    .frame(width: 120, height: 120)

                VStack(alignment: .leading, spacing: 8) {
                    ringStat(color: .red, label: "Move", current: activity.activeEnergyKcal, goal: activity.moveGoalKcal, unit: "kcal")
                    ringStat(color: .green, label: "Exercise", current: activity.exerciseMinutes.map(Double.init), goal: activity.exerciseGoalMinutes, unit: "min")
                    ringStat(color: .blue, label: "Stand", current: activity.standHours.map(Double.init), goal: activity.standGoalHours, unit: "hr")
                }
            }

            HStack(spacing: 12) {
                miniMetric("Steps", value: HealthFormat.steps(activity.steps))
                miniMetric("Distance", value: HealthFormat.km(activity.distanceKm))
                miniMetric("Floors", value: activity.flightsClimbed.map { "\($0)" } ?? "—")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    @ViewBuilder
    private func ringStat(color: Color, label: String, current: Double?, goal: Double?, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .frame(width: 70, alignment: .leading)
            Text(current.map { "\(Int($0.rounded()))" } ?? "—")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            if let g = goal {
                Text("/ \(Int(g.rounded())) \(unit)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func miniMetric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// Tiny dense tile for secondary metrics.
struct MiniMetricTile: View {
    let icon: String
    let tint: Color
    let title: String
    let value: String
    let unit: String

    var body: some View {
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
                    Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                    if !unit.isEmpty {
                        Text(unit).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }
}

/// Compact sparkline used on cards.
struct TrendSparkline: View {
    let points: [MetricPoint]
    let color: Color

    var body: some View {
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("date", p.date), y: .value("value", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                AreaMark(x: .value("date", p.date), y: .value("value", p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(
                        colors: [color.opacity(0.35), color.opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    ))
            }
        }
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        .chartPlotStyle { plot in
            plot.padding(.vertical, 2)
        }
    }
}

/// Horizontal sleep phase stacked bar.
struct SleepPhaseBar: View {
    let sleep: SleepSummary

    var body: some View {
        GeometryReader { geo in
            let total = max(sleep.asleep + sleep.awake, 1)
            HStack(spacing: 1) {
                segment(color: SleepPhase.awake.color, fraction: sleep.awake / total, width: geo.size.width)
                segment(color: SleepPhase.core.color, fraction: sleep.core / total, width: geo.size.width)
                segment(color: SleepPhase.deep.color, fraction: sleep.deep / total, width: geo.size.width)
                segment(color: SleepPhase.rem.color,  fraction: sleep.rem / total, width: geo.size.width)
            }
        }
    }

    private func segment(color: Color, fraction: Double, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color)
            .frame(width: max(0, CGFloat(fraction) * width - 1))
    }
}

#Preview {
    OverviewView()
        .environmentObject(HealthOverviewViewModel.preview)
        .environmentObject(UserProfile.shared)
        .environmentObject(HeartRateViewModel.preview)
}
