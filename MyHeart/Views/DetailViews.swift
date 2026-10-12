import SwiftUI
import Charts

// MARK: - Generic metric detail (steps, energy, etc.)

enum MetricAggregation {
    case cumulative    // steps, kcal — sum per day
    case average       // resting HR, weight — average per day
}

struct MetricDetailView: View {
    let title: String
    let icon: String
    let tint: Color
    let unit: String
    let kind: MetricAggregation
    let todayValue: Double?
    let last7: [MetricPoint]

    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 48
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                chartCard
                if hasData {
                    statsCard
                }
            }
            .padding()
            .readableContentWidth()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Missing days come back as 0, so a new user's week is all zeros.
    private var hasData: Bool { HealthOverview.hasData(last7) }

    private var header: some View {
        let value = todayValue.map { formatValue($0) } ?? HealthFormat.missing
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: heroSize, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !unit.isEmpty && todayValue != nil {
                    Text(unit)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(kind == .cumulative ? "Today" : "Latest")
            .accessibilityValue(HealthFormat.spoken(value, unit: unit))

            Text(kind == .cumulative ? "Today" : "Latest")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last 7 days")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if hasData {
                let average = kind == .cumulative ? HealthOverview.completedDayAverage(last7) : mean
                DailyBarChart(
                    points: last7,
                    tint: tint,
                    metricName: title,
                    unit: unit,
                    format: { formatValue($0) },
                    average: average,
                    fadesToday: kind == .cumulative
                )
                if kind == .cumulative {
                    DailyBarChart.TodayNote(points: last7, average: average)
                }
            } else {
                ChartNoDataText()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Summary")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            statsLayout {
                if kind == .cumulative {
                    // Today is still running, so the average uses finished days
                    // and "Best day" is a more useful extreme than a partial "Min".
                    statTile(title: "Daily avg", value: formatValue(HealthOverview.completedDayAverage(last7)), unit: unit)
                    statTile(title: "Best day", value: formatValue(last7.map(\.value).max()), unit: unit)
                    statTile(title: "Total", value: formatValue(total), unit: unit)
                } else {
                    statTile(title: "Average", value: formatValue(mean), unit: unit)
                    statTile(title: "Min", value: formatValue(last7.map(\.value).min()), unit: unit)
                    statTile(title: "Max", value: formatValue(last7.map(\.value).max()), unit: unit)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var statsLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
    }

    @ViewBuilder
    private func statTile(title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                if !unit.isEmpty && value != HealthFormat.missing {
                    Text(unit).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemGroupedBackground)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(HealthFormat.spoken(value, unit: unit))
    }

    // MARK: - Math / formatting

    private var total: Double? {
        guard !last7.isEmpty else { return nil }
        return last7.reduce(0) { $0 + $1.value }
    }

    private var mean: Double? {
        guard !last7.isEmpty else { return nil }
        return last7.reduce(0) { $0 + $1.value } / Double(last7.count)
    }

    private func formatValue(_ v: Double?) -> String {
        if unit == "steps" || unit == "floors" || unit.lowercased() == "kcal" {
            return HealthFormat.number(v)
        }
        return HealthFormat.number(v, fraction: 1)
    }
}

// MARK: - Activity Detail

struct ActivityDetailView: View {
    let snapshot: ActivitySnapshot
    let stepsSeries: [MetricPoint]
    let energySeries: [MetricPoint]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Not a link here, and the grid below already has steps,
                // distance and floors.
                ActivityRingsCard(activity: snapshot, showsChevron: false, showsSummaryRow: false)
                    .padding(.top, 4)

                statsBreakdown

                dailyChart("Steps", tint: .green, unit: "steps", points: stepsSeries)
                dailyChart("Active Energy", tint: .orange, unit: "kcal", points: energySeries)
            }
            .padding()
            .readableContentWidth()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statsBreakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: DetailGrid.columns(for: dynamicTypeSize), spacing: 10) {
                StatRow(icon: "figure.walk", tint: .green, title: "Steps", value: HealthFormat.steps(snapshot.steps), unit: "")
                let distance = HealthFormat.distance(snapshot.distanceKm)
                StatRow(icon: "figure.walk.circle", tint: .green, title: "Distance", value: distance.value, unit: distance.unit)
                StatRow(icon: "flame.fill", tint: .orange, title: "Active Energy", value: HealthFormat.number(snapshot.activeEnergyKcal), unit: "kcal")
                StatRow(icon: "flame", tint: .pink, title: "Basal Energy", value: HealthFormat.number(snapshot.basalEnergyKcal), unit: "kcal")
                StatRow(icon: "stopwatch", tint: .green, title: "Exercise", value: HealthFormat.number(snapshot.exerciseMinutes.map { Double($0) }), unit: "min")
                StatRow(icon: "figure.stand", tint: .blue, title: "Stand Hours", value: HealthFormat.number(snapshot.standHours.map { Double($0) }), unit: "hr")
                StatRow(icon: "figure.stairs", tint: .mint, title: "Floors", value: HealthFormat.number(snapshot.flightsClimbed.map { Double($0) }), unit: "")
                if let total = snapshot.totalEnergyKcal {
                    StatRow(icon: "sum", tint: .red, title: "Total Energy", value: HealthFormat.number(total), unit: "kcal")
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    /// Same chart as the Steps / Active Energy detail screens, so the two
    /// routes to the same data look the same.
    private func dailyChart(_ title: String, tint: Color, unit: String, points: [MetricPoint]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(title) — last 7 days")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if HealthOverview.hasData(points) {
                let average = HealthOverview.completedDayAverage(points)
                DailyBarChart(
                    points: points,
                    tint: tint,
                    metricName: title,
                    unit: unit,
                    format: { HealthFormat.number($0) },
                    average: average
                )
                DailyBarChart.TodayNote(points: points, average: average)
            } else {
                ChartNoDataText()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

// MARK: - Body Detail

struct BodyDetailView: View {
    let snapshot: BodySnapshot
    let weightSeries: [MetricPoint]

    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 44
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                hero
                measurements
                if !weightSeries.isEmpty {
                    ChartBlock(
                        title: "Weight — last 30 days",
                        color: .brown,
                        // Stored in kg; drawn in the unit the hero shows.
                        points: weightSeries.map {
                            MetricPoint(date: $0.date, value: HealthFormat.massInPreferredUnit($0.value))
                        },
                        compact: false,
                        style: .line,
                        metricName: "Weight",
                        unit: HealthFormat.massUnit
                    )
                }
            }
            .padding()
            .readableContentWidth()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Body")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hero: some View {
        let weight = HealthFormat.mass(snapshot.weightKg)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "scalemass.fill")
                    .foregroundStyle(.brown)
                Text("Weight")
                    .font(.headline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(weight.value)
                    .font(.system(size: heroSize, weight: .bold, design: .rounded))
                    .foregroundStyle(.brown)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !weight.unit.isEmpty && weight.value != HealthFormat.missing {
                    Text(weight.unit)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if let d = snapshot.weightAt {
                    SampleAgeText(date: d)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Latest weight")
            .accessibilityValue(
                [
                    HealthFormat.spoken(weight.value, unit: weight.unit),
                    snapshot.weightAt.map { "measured \($0.formatted(.relative(presentation: .named)))" },
                ]
                .compactMap { $0 }
                .joined(separator: ", ")
            )
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var measurements: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Measurements")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: DetailGrid.columns(for: dynamicTypeSize), spacing: 10) {
                let weight = HealthFormat.mass(snapshot.weightKg)
                StatRow(icon: "scalemass", tint: .brown, title: "Weight", value: weight.value, unit: weight.unit)
                let height = HealthFormat.height(snapshot.heightCm)
                StatRow(icon: "ruler", tint: .gray, title: "Height", value: height.value, unit: height.unit)
                StatRow(icon: "percent", tint: .orange, title: "BMI", value: HealthFormat.number(snapshot.bmi, fraction: 1), unit: "")
                StatRow(icon: "figure.arms.open", tint: .indigo, title: "Body Fat", value: HealthFormat.percent(snapshot.bodyFatPercent), unit: "")
                if let lean = snapshot.leanBodyMassKg {
                    let leanMass = HealthFormat.mass(lean)
                    StatRow(icon: "bolt.heart", tint: .red, title: "Lean Mass", value: leanMass.value, unit: leanMass.unit)
                }
                if let b = snapshot.bmi {
                    StatRow(icon: "flag", tint: .gray, title: "BMI Status", value: bmiCategory(b), unit: "")
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private func bmiCategory(_ b: Double) -> String {
        switch b {
        case ..<18.5: return "Underweight"
        case 18.5..<25: return "Normal"
        case 25..<30: return "Overweight"
        default: return "Obese"
        }
    }
}

// MARK: - Sleep Detail

struct SleepDetailView: View {
    let sleep: SleepSummary

    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 44
    @ScaledMetric(relativeTo: .caption) private var percentColumnWidth: CGFloat = 44
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                hero
                phases
                if sleep.bedtime != nil || sleep.wakeTime != nil {
                    schedule
                }
            }
            .padding()
            .readableContentWidth()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Sleep")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "bed.double.fill")
                    .foregroundStyle(.indigo)
                Text("Last Night")
                    .font(.headline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            heroCaptionLayout {
                DurationHero(
                    seconds: sleep.totalSeconds,
                    // Capped because the hero never shrinks to fit; past this
                    // "12h 59m" would outgrow a phone-width card.
                    numberFont: .system(size: min(heroSize, 72), weight: .bold, design: .rounded),
                    unitFont: .title2.weight(.semibold),
                    tint: .indigo
                )
                Text(sleep.isInBedOnly ? "in bed" : "asleep")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if sleep.isInBedOnly {
                Text("Only time in bed was recorded. Wear Apple Watch to bed to see sleep stages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            SleepPhaseBar(sleep: sleep)
                .frame(height: 14)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    private var phases: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Phases")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 10) {
                if sleep.hasStages {
                    phaseRow(.core,  seconds: sleep.core)
                    phaseRow(.deep,  seconds: sleep.deep)
                    phaseRow(.rem,   seconds: sleep.rem)
                }
                if sleep.unspecified > 0 {
                    phaseRow(.asleep, seconds: sleep.unspecified)
                }
                phaseRow(.awake, seconds: sleep.awake)
                if sleep.isInBedOnly {
                    phaseRow(.inBed, seconds: sleep.inBed)
                }
            }
            if let eff = sleep.efficiencyPercent {
                Divider().padding(.vertical, 4)
                HStack {
                    Text("Sleep Efficiency")
                        .font(.subheadline)
                    Spacer()
                    Text(HealthFormat.percent(eff))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    @ViewBuilder
    private func phaseRow(_ phase: SleepPhase, seconds: TimeInterval) -> some View {
        let share = HealthFormat.percent(seconds / max(sleep.inBed, 1))
        HStack(spacing: 10) {
            Circle().fill(phase.color).frame(width: 10, height: 10)
            Text(phase.label)
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(HealthFormat.duration(seconds))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            // Neutral text: the phase colors are too light for small text,
            // and the dot already carries the color.
            Text(share)
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(minWidth: percentColumnWidth, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase.label)
        .accessibilityValue("\(HealthFormat.spokenDuration(seconds)), \(share)")
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Schedule")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            scheduleLayout {
                if let bed = sleep.bedtime {
                    scheduleTile(icon: "moon.fill", tint: .indigo, title: "Bedtime", date: bed)
                }
                if let wake = sleep.wakeTime {
                    scheduleTile(icon: "sun.max.fill", tint: .orange, title: "Wake", date: wake)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    /// At accessibility sizes the caption goes under the hero digits, which
    /// would otherwise leave it a few points and break it mid-word.
    private var heroCaptionLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
    }

    private var scheduleLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 20))
    }

    @ViewBuilder
    private func scheduleTile(icon: String, tint: Color, title: String, date: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(date, format: .dateTime.hour().minute())
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.tertiarySystemGroupedBackground)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Reusable

/// Grid columns for stat rows inside a card: two on iPhone (the card's inner
/// width is ~311 pt on a 375 pt phone), more on iPad, one at accessibility sizes.
enum DetailGrid {
    static func columns(for size: DynamicTypeSize) -> [GridItem] {
        size.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.adaptive(minimum: 140), spacing: 10)]
    }
}

struct StatRow: View {
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                    if !unit.isEmpty && value != HealthFormat.missing {
                        Text(unit).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(HealthFormat.spoken(value, unit: unit))
    }
}

/// The one empty-chart message, so every chart says the same thing.
struct ChartNoDataText: View {
    var body: some View {
        Text("No data for this period")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160)
    }
}

/// Daily bars for the last week (steps, energy). Today's bar is lighter
/// while the day is still running, and the caller passes an average that
/// leaves it out, so mornings don't look like a sudden drop.
struct DailyBarChart: View {
    let points: [MetricPoint]
    let tint: Color
    /// Axis and VoiceOver name of the plotted value ("Steps").
    let metricName: String
    let unit: String
    let format: (Double) -> String
    var average: Double? = nil
    var fadesToday: Bool = true

    var body: some View {
        Chart {
            ForEach(points) { p in
                BarMark(
                    x: .value("Day", p.date, unit: .day),
                    y: .value(metricName, p.value)
                )
                .foregroundStyle(tint.gradient)
                .cornerRadius(4)
                .opacity(isPartial(p) ? 0.45 : 1)
                .accessibilityLabel(Text(p.date, format: .dateTime.weekday(.wide).month().day()))
                .accessibilityValue(Text(spokenValue(p)))
            }
            if let average {
                RuleMark(y: .value("Average", average))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .topTrailing) {
                        Text("avg \(format(average))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(Text("Daily average"))
                    .accessibilityValue(Text(HealthFormat.spoken(format(average), unit: unit)))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.gray.opacity(0.2))
                AxisTick()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(v.formatted(.number.notation(.compactName)))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { value in
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(d, format: .dateTime.weekday(.abbreviated))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(height: 200)
    }

    private func isPartial(_ p: MetricPoint) -> Bool {
        fadesToday && Calendar.current.isDateInToday(p.date)
    }

    private func spokenValue(_ p: MetricPoint) -> String {
        let spoken = HealthFormat.spoken(format(p.value), unit: unit)
        return isPartial(p) ? "\(spoken) so far" : spoken
    }

    /// Explains the lighter bar, shown under the chart while today has one.
    struct TodayNote: View {
        let points: [MetricPoint]
        /// The average line drawn on the chart, if any. A first day has no
        /// finished day to average, so the note mustn't mention one.
        let average: Double?

        var body: some View {
            // A zero bar isn't drawn, so there's nothing to explain.
            if let today = points.first(where: { Calendar.current.isDateInToday($0.date) }), today.value > 0 {
                Text(average == nil
                     ? "Today's bar is still filling up."
                     : "Today's bar is still filling up and isn't counted in the average.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ChartBlock: View {
    enum Style { case bars, line }

    let title: String
    let color: Color
    let points: [MetricPoint]
    let compact: Bool
    var style: Style = .bars
    /// Axis and VoiceOver name of the plotted value ("Weight").
    var metricName: String = "Value"
    var unit: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if HealthOverview.hasData(points) {
                chart
                    .frame(height: 200)
            } else {
                ChartNoDataText()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }

    @ViewBuilder
    private var chart: some View {
        switch style {
        case .bars:
            Chart {
                ForEach(points) { p in
                    BarMark(
                        x: .value("Day", p.date, unit: .day),
                        y: .value(metricName, p.value)
                    )
                    .foregroundStyle(color.gradient)
                    .cornerRadius(4)
                    .accessibilityLabel(dayLabel(p))
                    .accessibilityValue(Text(spokenValue(p)))
                }
            }
            .chartYAxis { yAxis }
            .chartXAxis { xAxis }
        case .line:
            // Body measurements: bars from zero would make 73 kg and 74 kg
            // look identical — use a line on a fitted scale instead.
            Chart {
                ForEach(points) { p in
                    LineMark(
                        x: .value("Day", p.date, unit: .day),
                        y: .value(metricName, p.value)
                    )
                    .foregroundStyle(color)
                    .interpolationMethod(.monotone)
                    .accessibilityLabel(dayLabel(p))
                    .accessibilityValue(Text(spokenValue(p)))
                    PointMark(
                        x: .value("Day", p.date, unit: .day),
                        y: .value(metricName, p.value)
                    )
                    .foregroundStyle(color)
                    .symbolSize(24)
                    // Same value as the line point; don't read it twice.
                    .accessibilityHidden(true)
                }
            }
            .chartYScale(domain: fittedDomain)
            .chartYAxis { yAxis }
            .chartXAxis { xAxis }
        }
    }

    private func dayLabel(_ p: MetricPoint) -> Text {
        Text(p.date, format: .dateTime.weekday(.wide).month().day())
    }

    private func spokenValue(_ p: MetricPoint) -> String {
        HealthFormat.spoken(HealthFormat.number(p.value, fraction: style == .line ? 1 : 0), unit: unit)
    }

    private var yAxis: some AxisContent {
        AxisMarks(position: .leading) { _ in
            AxisGridLine().foregroundStyle(.gray.opacity(0.2))
            AxisValueLabel().font(.caption2)
        }
    }

    private var xAxis: some AxisContent {
        AxisMarks(values: .stride(by: .day, count: dayStride)) { value in
            AxisValueLabel {
                if let d = value.as(Date.self) {
                    Text(d, format: compact ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated))
                        .font(.caption2)
                }
            }
        }
    }

    /// One label per day for a week; thinner for longer ranges.
    private var dayStride: Int {
        guard let first = points.first?.date, let last = points.last?.date else { return 1 }
        let days = Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0
        return max(1, Int((Double(days + 1) / 7).rounded(.up)))
    }

    private var fittedDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.2, 0.5)
        return (lo - pad)...(hi + pad)
    }
}
