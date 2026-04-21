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

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                chartCard
                statsCard
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.headline)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(todayValue.map { formatValue($0) } ?? "—")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(kind == .cumulative ? "Today" : "Latest")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Last 7 days")
                .font(.headline)
            if last7.isEmpty {
                Text("No data to display.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Chart {
                    ForEach(last7) { p in
                        BarMark(
                            x: .value("Day", p.date, unit: .day),
                            y: .value(title, p.value)
                        )
                        .foregroundStyle(tint.gradient)
                        .cornerRadius(4)
                    }
                    if let avg = average {
                        RuleMark(y: .value("avg", avg))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .topTrailing) {
                                Text("avg \(formatValue(avg))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(.gray.opacity(0.2))
                        AxisTick()
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(formatValueCompact(v))
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
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Summary")
                .font(.headline)
            HStack(spacing: 12) {
                statTile(title: kind == .cumulative ? "Total" : "Average", value: formatValue(sum), unit: unit)
                statTile(title: "Min", value: formatValue(last7.map(\.value).min()), unit: unit)
                statTile(title: "Max", value: formatValue(last7.map(\.value).max()), unit: unit)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
    }

    @ViewBuilder
    private func statTile(title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.subheadline.weight(.semibold)).monospacedDigit()
                if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemGroupedBackground)))
    }

    // MARK: - Math / formatting

    private var sum: Double? {
        guard !last7.isEmpty else { return nil }
        return kind == .cumulative
            ? last7.reduce(0) { $0 + $1.value }
            : last7.reduce(0) { $0 + $1.value } / Double(last7.count)
    }

    private var average: Double? {
        guard !last7.isEmpty else { return nil }
        return last7.reduce(0) { $0 + $1.value } / Double(last7.count)
    }

    private func formatValue(_ v: Double?) -> String {
        guard let v else { return "—" }
        if unit == "steps" || unit == "floors" {
            return NumberFormatter.localizedString(from: NSNumber(value: Int(v.rounded())), number: .decimal)
        }
        if unit.lowercased() == "kcal" {
            return "\(Int(v.rounded()))"
        }
        return String(format: "%.1f", v)
    }

    private func formatValueCompact(_ v: Double) -> String {
        if abs(v) >= 1000 { return String(format: "%.1fk", v / 1000) }
        return "\(Int(v.rounded()))"
    }
}

// MARK: - Activity Detail

struct ActivityDetailView: View {
    let snapshot: ActivitySnapshot
    let stepsSeries: [MetricPoint]
    let energySeries: [MetricPoint]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ActivityRingsCard(activity: snapshot)
                        .padding(.top, 4)

                statsBreakdown

                stepsChart
                energyChart
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statsBreakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Today")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatRow(icon: "figure.walk", tint: .green, title: "Steps", value: HealthFormat.steps(snapshot.steps), unit: "")
                StatRow(icon: "figure.walk.circle", tint: .green, title: "Distance", value: HealthFormat.km(snapshot.distanceKm), unit: "")
                StatRow(icon: "flame.fill", tint: .orange, title: "Active Energy", value: HealthFormat.kcal(snapshot.activeEnergyKcal), unit: "")
                StatRow(icon: "flame", tint: .pink, title: "Basal Energy", value: HealthFormat.kcal(snapshot.basalEnergyKcal), unit: "")
                StatRow(icon: "stopwatch", tint: .green, title: "Exercise", value: snapshot.exerciseMinutes.map { "\($0) min" } ?? "—", unit: "")
                StatRow(icon: "figure.stand", tint: .blue, title: "Stand Hours", value: snapshot.standHours.map { "\($0) hr" } ?? "—", unit: "")
                StatRow(icon: "figure.stairs", tint: .mint, title: "Floors", value: snapshot.flightsClimbed.map { "\($0)" } ?? "—", unit: "")
                if let total = snapshot.totalEnergyKcal {
                    StatRow(icon: "sum", tint: .red, title: "Total Energy", value: HealthFormat.kcal(total), unit: "")
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var stepsChart: some View {
        ChartBlock(title: "Steps — last 7 days", color: .green, points: stepsSeries, compact: true)
    }

    private var energyChart: some View {
        ChartBlock(title: "Active Energy — last 7 days", color: .orange, points: energySeries, compact: true)
    }
}

// MARK: - Body Detail

struct BodyDetailView: View {
    let snapshot: BodySnapshot
    let weightSeries: [MetricPoint]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                hero
                measurements
                if !weightSeries.isEmpty {
                    ChartBlock(title: "Weight — last 30 days", color: .brown, points: weightSeries, compact: false)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Body")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "scalemass.fill")
                    .foregroundStyle(.brown)
                Text("Weight")
                    .font(.headline)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(HealthFormat.kg(snapshot.weightKg))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.brown)
                    .monospacedDigit()
                if let d = snapshot.weightAt {
                    Text(d, style: .relative)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var measurements: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Measurements")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatRow(icon: "scalemass", tint: .brown, title: "Weight", value: HealthFormat.kg(snapshot.weightKg), unit: "")
                StatRow(icon: "ruler", tint: .gray, title: "Height", value: snapshot.heightCm.map { "\(Int($0.rounded())) cm" } ?? "—", unit: "")
                StatRow(icon: "percent", tint: .orange, title: "BMI", value: snapshot.bmi.map { String(format: "%.1f", $0) } ?? "—", unit: "")
                StatRow(icon: "figure.arms.open", tint: .indigo, title: "Body Fat", value: HealthFormat.percent(snapshot.bodyFatPercent), unit: "")
                if let lean = snapshot.leanBodyMassKg {
                    StatRow(icon: "bolt.heart", tint: .red, title: "Lean Mass", value: HealthFormat.kg(lean), unit: "")
                }
                if let b = snapshot.bmi {
                    StatRow(icon: "flag", tint: .gray, title: "BMI Status", value: bmiCategory(b), unit: "")
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
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

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                hero
                phases
                schedule
            }
            .padding()
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
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(DurationFormat.hoursMinutes(sleep.totalSeconds))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.indigo)
                    .monospacedDigit()
                Text("asleep")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            SleepPhaseBar(sleep: sleep)
                .frame(height: 14)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var phases: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Phases")
                .font(.headline)
            VStack(spacing: 10) {
                phaseRow(.core,  seconds: sleep.core)
                phaseRow(.deep,  seconds: sleep.deep)
                phaseRow(.rem,   seconds: sleep.rem)
                phaseRow(.awake, seconds: sleep.awake)
            }
            if let eff = sleep.efficiencyPercent {
                Divider().padding(.vertical, 4)
                HStack {
                    Text("Sleep Efficiency")
                        .font(.subheadline)
                    Spacer()
                    Text(HealthFormat.percent(eff))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.indigo)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
    }

    @ViewBuilder
    private func phaseRow(_ phase: SleepPhase, seconds: TimeInterval) -> some View {
        HStack(spacing: 10) {
            Circle().fill(phase.color).frame(width: 10, height: 10)
            Text(phase.label)
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(DurationFormat.hoursMinutes(seconds))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            Text("\(Int(((seconds / max(sleep.inBed, 1)) * 100).rounded()))%")
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 44, alignment: .trailing)
                .foregroundStyle(phase.color)
        }
    }

    private var schedule: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Schedule")
                .font(.headline)
            HStack(spacing: 20) {
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
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
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
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.tertiarySystemGroupedBackground)))
    }
}

// MARK: - Reusable

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
                    if !unit.isEmpty { Text(unit).font(.caption2).foregroundStyle(.secondary) }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct ChartBlock: View {
    let title: String
    let color: Color
    let points: [MetricPoint]
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if points.isEmpty {
                Text("No data")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Chart {
                    ForEach(points) { p in
                        BarMark(
                            x: .value("date", p.date, unit: .day),
                            y: .value("value", p.value)
                        )
                        .foregroundStyle(color.gradient)
                        .cornerRadius(4)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) { _ in
                        AxisGridLine().foregroundStyle(.gray.opacity(0.2))
                        AxisValueLabel().font(.caption2)
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisValueLabel {
                            if let d = value.as(Date.self) {
                                Text(d, format: compact ? .dateTime.weekday(.abbreviated) : .dateTime.day().month(.abbreviated))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .frame(height: 200)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemGroupedBackground)))
    }
}
