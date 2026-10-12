import Foundation
import UIKit

/// Renders the shareable heart-rate reports.
///
/// Safe to call off the main thread (the dashboard renders on a background
/// task so long ranges don't freeze the UI).
enum PDFExporter {
    private static let pageWidth: CGFloat = 612   // US Letter @72dpi
    private static let pageHeight: CGFloat = 792
    private static let margin: CGFloat = 48
    /// Content must end above this line; the page footer sits below it.
    private static var contentBottom: CGFloat { pageHeight - margin }
    private static var contentWidth: CGFloat { pageWidth - 2 * margin }

    // Fixed colors only. The page is always white, so dynamic system colors
    // (`.label`, `.systemPink`, …) would resolve to their Dark Mode variants
    // and make text invisible when the phone is in Dark Mode.
    private static let accentColor = UIColor(red: 0.91, green: 0.20, blue: 0.42, alpha: 1)
    private static let gridColor = UIColor(white: 0.80, alpha: 1)
    private static let axisColor = UIColor(white: 0.55, alpha: 1)
    private static let labelColor = UIColor(white: 0.35, alpha: 1)
    private static let bodyColor = UIColor(white: 0.10, alpha: 1)
    private static let ruleColor = UIColor(white: 0.86, alpha: 1)
    private static let averageColor = UIColor(white: 0.45, alpha: 1)
    private static let chartBackground = UIColor(white: 0.985, alpha: 1)
    private static let improvementColor = UIColor(red: 0.16, green: 0.62, blue: 0.30, alpha: 1)
    private static let declineColor = UIColor(red: 0.90, green: 0.49, blue: 0.10, alpha: 1)

    /// Up to this many samples are listed row by row; beyond that the report
    /// shows an hourly / daily summary table (a 6-month range would otherwise
    /// produce thousands of pages).
    private static let maxRawSampleRows = 500
    /// Above this many samples the trend chart is drawn from aggregated buckets.
    private static let maxRawChartPoints = 1500

    // MARK: - Public API

    static func exportOverall(
        summary: HeartRateSummary,
        previousSummary: HeartRateSummary,
        samples: [HeartRateSample],
        zones: ZoneBreakdown,
        maxHR: Double,
        rangeTitle: String,
        previousRangeLabel: String
    ) throws -> URL {
        let sorted = samples.sorted { $0.date < $1.date }

        let data = render { ctx in
            let page = Page(ctx: ctx, continuationTitle: "MyHeart Report — continued")
            page.begin()
            page.y = drawHeader(Header(title: "MyHeart Report", subtitle: rangeTitle), y: page.y) + 12

            page.y = drawSectionHeader("Summary", y: page.y)
            page.y = drawDeltaKeyValueGrid(
                [
                    ("Latest", summary.latest.map { "\(Int($0.bpm.rounded())) BPM • \(shortDate($0.date))" } ?? "—", nil, nil),
                    ("Average", format(summary.averageBPM, unit: "BPM"),
                     deltaText(current: summary.averageBPM, previous: previousSummary.averageBPM, unit: "bpm"),
                     deltaKind(current: summary.averageBPM, previous: previousSummary.averageBPM, lowerIsBetter: nil)),
                    ("Resting", format(summary.restingBPM, unit: "BPM"),
                     deltaText(current: summary.restingBPM, previous: previousSummary.restingBPM, unit: "bpm"),
                     deltaKind(current: summary.restingBPM, previous: previousSummary.restingBPM, lowerIsBetter: true)),
                    ("HRV (SDNN)", format(summary.hrvSDNN, unit: "ms"),
                     deltaText(current: summary.hrvSDNN, previous: previousSummary.hrvSDNN, unit: "ms"),
                     deltaKind(current: summary.hrvSDNN, previous: previousSummary.hrvSDNN, lowerIsBetter: false)),
                    ("Min", format(summary.minBPM, unit: "BPM"), nil, nil),
                    ("Max", format(summary.maxBPM, unit: "BPM"), nil, nil),
                    ("Samples", "\(summary.sampleCount)", nil, nil),
                    ("Compared with", previousRangeLabel, nil, nil),
                ],
                y: page.y
            ) + 14

            if zones.totalDuration > 0 {
                drawZonesSection(title: "Time in Zones", breakdown: zones, maxHR: maxHR, page: page)
            }

            let chartHeight: CGFloat = 220
            page.ensureSpace(sectionHeaderHeight + chartHeight + 18)
            page.y = drawSectionHeader("Heart Rate Trend", y: page.y)
            let chartRect = CGRect(x: margin, y: page.y, width: contentWidth, height: chartHeight)
            drawLineChart(samples: sorted, averageBPM: summary.averageBPM, in: chartRect)
            page.y += chartHeight + 18

            if sorted.count <= maxRawSampleRows {
                drawSampleTable(sorted, page: page)
            } else {
                drawAggregateTable(sorted, page: page)
            }
        }
        return try write(data, prefix: "MyHeart-Overall")
    }

    static func exportDaily(
        stats: [DailyHeartRateStats],
        samples: [HeartRateSample],
        zonesByDay: [Date: ZoneBreakdown],
        maxHR: Double,
        start: Date,
        end: Date
    ) throws -> URL {
        let calendar = Calendar.current
        var samplesByDay: [Date: [HeartRateSample]] = [:]
        for sample in samples {
            samplesByDay[calendar.startOfDay(for: sample.date), default: []].append(sample)
        }

        // Aggregate zones across all days for the "Period Zones" section.
        let aggregateZones = HeartRateZoneAnalyzer.breakdown(samples: samples, maxHR: maxHR)

        let data = render { ctx in
            let page = Page(ctx: ctx, continuationTitle: "MyHeart Daily Report — continued")
            page.begin()
            let header = Header(
                title: "MyHeart Daily Report",
                subtitle: "\(dayOnly(start)) — \(dayOnly(end))   •   \(stats.count) day\(stats.count == 1 ? "" : "s")"
            )
            page.y = drawHeader(header, y: page.y) + 12

            // Aggregate summary
            let avgOfAvg = avg(stats.compactMap(\.avgBPM))
            let avgResting = avg(stats.compactMap(\.restingBPM))
            let minAll = stats.compactMap(\.minBPM).min()
            let maxAll = stats.compactMap(\.maxBPM).max()

            page.y = drawSectionHeader("Period Summary", y: page.y)
            page.y = drawKeyValueTwoColumn([
                ("Avg of Daily Avg", format(avgOfAvg, unit: "BPM")),
                ("Avg Resting", format(avgResting, unit: "BPM")),
                ("Lowest Daily Min", format(minAll, unit: "BPM")),
                ("Highest Daily Max", format(maxAll, unit: "BPM")),
            ], y: page.y) + 16

            if aggregateZones.totalDuration > 0 {
                drawZonesSection(title: "Time in Zones (entire range)", breakdown: aggregateZones, maxHR: maxHR, page: page)
            }

            // Per-day detail: one 24-hour chart per day
            let dayChartHeight: CGFloat = 140
            let dayBlockHeight: CGFloat = dayHeaderHeight + 12 + dayChartHeight + 18
            page.ensureSpace(sectionHeaderHeight + 4 + dayBlockHeight)
            page.y = drawSectionHeader("Per-Day Detail (24-Hour View)", y: page.y) + 4

            for day in stats {
                page.ensureSpace(dayBlockHeight)
                page.y = drawDayHeader(day: day, y: page.y)

                if let zb = zonesByDay[day.day], zb.totalDuration > 0 {
                    let stripRect = CGRect(x: margin, y: page.y, width: contentWidth, height: 6)
                    drawZoneStackedBar(breakdown: zb, in: stripRect, cornerRadius: 2)
                }
                page.y += 12

                let chartRect = CGRect(x: margin, y: page.y, width: contentWidth, height: dayChartHeight)
                drawDay24hChart(
                    samples: samplesByDay[day.day] ?? [],
                    dayStart: day.day,
                    averageBPM: day.avgBPM,
                    calendar: calendar,
                    in: chartRect
                )
                page.y += dayChartHeight + 18
            }

            // Per-day table, paginated
            let cols = ["Date", "Min", "Avg", "Max", "Resting", "Samples"]
            let widths: [CGFloat] = [150, 60, 60, 60, 70, contentWidth - 400]
            page.ensureSpace(sectionHeaderHeight + tableHeaderHeight + tableRowHeight * 3)
            page.y = drawSectionHeader("Per-Day Breakdown", y: page.y)
            page.y = drawTableHeader(cols, widths: widths, y: page.y)
            for day in stats {
                if page.ensureSpace(tableRowHeight) {
                    page.y = drawTableHeader(cols, widths: widths, y: page.y)
                }
                page.y = drawTableRow([
                    dayOnly(day.day),
                    intOrDash(day.minBPM),
                    intOrDash(day.avgBPM),
                    intOrDash(day.maxBPM),
                    intOrDash(day.restingBPM),
                    "\(day.sampleCount)",
                ], widths: widths, y: page.y)
            }
        }
        return try write(data, prefix: "MyHeart-Daily")
    }

    // MARK: - Rendering plumbing

    private struct Header {
        let title: String
        let subtitle: String
    }

    /// Current page + vertical cursor. Every page gets a numbered footer and
    /// every continuation page a small header.
    private final class Page {
        let ctx: UIGraphicsPDFRendererContext
        let continuationTitle: String
        private(set) var number = 0
        var y: CGFloat = 0

        init(ctx: UIGraphicsPDFRendererContext, continuationTitle: String) {
            self.ctx = ctx
            self.continuationTitle = continuationTitle
        }

        func begin() {
            ctx.beginPage()
            number += 1
            PDFExporter.drawFooter(page: number)
            y = PDFExporter.margin
        }

        /// Starts a new page unless `height` more points still fit.
        /// Returns true when a page break happened.
        @discardableResult
        func ensureSpace(_ height: CGFloat) -> Bool {
            guard y + height > PDFExporter.contentBottom else { return false }
            begin()
            y = PDFExporter.drawPageHeader(continuationTitle, y: y) + 8
            return true
        }
    }

    private static func render(_ draw: (UIGraphicsPDFRendererContext) -> Void) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextCreator as String: "MyHeart",
            kCGPDFContextTitle as String: "Heart Rate Report",
        ]
        let bounds = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        return renderer.pdfData(actions: draw)
    }

    private static func write(_ data: Data, prefix: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        // Drop reports from earlier exports so the temp folder doesn't grow.
        if let old = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in old where url.lastPathComponent.hasPrefix("MyHeart-") && url.pathExtension == "pdf" {
                try? fm.removeItem(at: url)
            }
        }
        let stamp = fileStampFormatter.string(from: Date())
        let url = dir.appendingPathComponent("\(prefix)-\(stamp).pdf")
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Header / footer

    private static func drawHeader(_ header: Header, y: CGFloat) -> CGFloat {
        var y = y
        y = drawString(header.title, at: CGPoint(x: margin, y: y), attrs: [
            .font: UIFont.systemFont(ofSize: 26, weight: .bold),
            .foregroundColor: accentColor,
        ])
        y += 2
        y = drawString(header.subtitle, at: CGPoint(x: margin, y: y), attrs: [
            .font: UIFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: labelColor,
        ])
        y += 4

        drawString("Generated \(shortDate(Date()))", at: CGPoint(x: pageWidth - margin, y: margin + 2), attrs: [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: axisColor,
        ], align: .right)

        drawHorizontalLine(at: y + 6, color: ruleColor)
        return y + 12
    }

    private static func drawPageHeader(_ text: String, y: CGFloat) -> CGFloat {
        drawString(text, at: CGPoint(x: margin, y: y), attrs: [
            .font: UIFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: labelColor,
        ])
    }

    private static func drawFooter(page: Int) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: axisColor,
        ]
        let footerY = pageHeight - margin + 14
        drawString("MyHeart • data sourced from Apple Health • not a medical device", at: CGPoint(x: margin, y: footerY), attrs: attrs)
        drawString("Page \(page)", at: CGPoint(x: pageWidth - margin, y: footerY), attrs: attrs, align: .right)
    }

    // MARK: - Sections

    private static let sectionHeaderHeight: CGFloat = 28

    private static func drawSectionHeader(_ text: String, y: CGFloat) -> CGFloat {
        let next = drawString(text, at: CGPoint(x: margin, y: y), attrs: [
            .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: bodyColor,
        ])
        drawHorizontalLine(at: next + 2, color: ruleColor)
        return next + 10
    }

    private static func drawNote(_ text: String, y: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: labelColor,
        ]
        let rect = CGRect(x: margin, y: y, width: contentWidth, height: 40)
        let bounds = (text as NSString).boundingRect(
            with: rect.size, options: [.usesLineFragmentOrigin], attributes: attrs, context: nil
        )
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
        return y + ceil(bounds.height) + 6
    }

    private static func drawZonesSection(title: String, breakdown: ZoneBreakdown, maxHR: Double, page: Page) {
        let height = sectionHeaderHeight + 16 + 10 + zoneRowHeight * CGFloat(HeartRateZone.allCases.count) + 10
        page.ensureSpace(height)
        page.y = drawSectionHeader(title, y: page.y)
        let barRect = CGRect(x: margin, y: page.y, width: contentWidth, height: 16)
        drawZoneStackedBar(breakdown: breakdown, in: barRect)
        page.y += barRect.height + 10
        page.y = drawZoneTable(breakdown: breakdown, maxHR: maxHR, y: page.y) + 10
    }

    private static func drawKeyValueTwoColumn(_ items: [(String, String)], y: CGFloat) -> CGFloat {
        let colWidth = contentWidth / 2
        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: labelColor,
        ]
        let valAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: bodyColor,
        ]

        var y = y
        let rowHeight: CGFloat = 18
        for i in stride(from: 0, to: items.count, by: 2) {
            let left = items[i]
            drawString(left.0, at: CGPoint(x: margin, y: y), attrs: keyAttrs)
            drawString(left.1, at: CGPoint(x: margin + colWidth - 8, y: y), attrs: valAttrs, align: .right)

            if i + 1 < items.count {
                let right = items[i + 1]
                drawString(right.0, at: CGPoint(x: margin + colWidth, y: y), attrs: keyAttrs)
                drawString(right.1, at: CGPoint(x: pageWidth - margin, y: y), attrs: valAttrs, align: .right)
            }
            y += rowHeight
        }
        return y
    }

    // MARK: - Tables

    private static let tableHeaderHeight: CGFloat = 18
    private static let tableRowHeight: CGFloat = 15

    private static func drawTableHeader(_ columns: [String], widths: [CGFloat], y: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: labelColor,
        ]
        drawCells(columns, widths: widths, y: y, attrs: attrs)
        let underline = y + 14
        drawHorizontalLine(at: underline, color: ruleColor)
        return underline + 4
    }

    private static func drawTableRow(_ values: [String], widths: [CGFloat], y: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: bodyColor,
        ]
        drawCells(values, widths: widths, y: y, attrs: attrs)
        return y + tableRowHeight
    }

    /// Draws one line of cells, truncating text that doesn't fit its column.
    private static func drawCells(_ values: [String], widths: [CGFloat], y: CGFloat, attrs: [NSAttributedString.Key: Any]) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        var cellAttrs = attrs
        cellAttrs[.paragraphStyle] = paragraph

        var x = margin
        for (i, value) in values.enumerated() {
            let width = i < widths.count ? widths[i] : 60
            let rect = CGRect(x: x, y: y, width: max(10, width - 6), height: 14)
            (value as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: cellAttrs, context: nil)
            x += width
        }
    }

    private static func drawSampleTable(_ samples: [HeartRateSample], page: Page) {
        let columns = ["Date / Time", "BPM", "Source"]
        let widths: [CGFloat] = [200, 60, contentWidth - 260]
        page.ensureSpace(sectionHeaderHeight + tableHeaderHeight + tableRowHeight * 3)
        page.y = drawSectionHeader("Samples", y: page.y)
        page.y = drawTableHeader(columns, widths: widths, y: page.y)
        for sample in samples {
            if page.ensureSpace(tableRowHeight) {
                page.y = drawTableHeader(columns, widths: widths, y: page.y)
            }
            page.y = drawTableRow(
                [shortDate(sample.date), "\(Int(sample.bpm.rounded()))", sample.source],
                widths: widths,
                y: page.y
            )
        }
    }

    /// Hourly (≤ 2 days of data) or daily summary rows for large sample sets.
    private static func drawAggregateTable(_ samples: [HeartRateSample], page: Page) {
        guard let first = samples.first?.date, let last = samples.last?.date else { return }
        let calendar = Calendar.current
        let hourly = last.timeIntervalSince(first) <= 2 * 86_400
        let component: Calendar.Component = hourly ? .hour : .day
        let groups = Dictionary(grouping: samples) {
            calendar.dateInterval(of: component, for: $0.date)?.start ?? $0.date
        }

        let columns = [hourly ? "Hour" : "Day", "Min", "Avg", "Max", "Samples"]
        let widths: [CGFloat] = [200, 70, 70, 70, contentWidth - 410]
        page.ensureSpace(sectionHeaderHeight + 24 + tableHeaderHeight + tableRowHeight * 3)
        page.y = drawSectionHeader(hourly ? "Hourly Summary" : "Daily Summary", y: page.y)
        page.y = drawNote(
            "\(samples.count) samples are too many to list individually, so they are summarised per \(hourly ? "hour" : "day").",
            y: page.y
        )
        page.y = drawTableHeader(columns, widths: widths, y: page.y)

        for key in groups.keys.sorted() {
            guard let bucket = groups[key], !bucket.isEmpty else { continue }
            let bpms = bucket.map(\.bpm)
            let mean = bpms.reduce(0, +) / Double(bpms.count)
            if page.ensureSpace(tableRowHeight) {
                page.y = drawTableHeader(columns, widths: widths, y: page.y)
            }
            page.y = drawTableRow([
                hourly ? shortDate(key) : dayOnly(key),
                intOrDash(bpms.min()),
                intOrDash(mean),
                intOrDash(bpms.max()),
                "\(bucket.count)",
            ], widths: widths, y: page.y)
        }
    }

    // MARK: - Line chart (overall)

    private static func drawLineChart(
        samples: [HeartRateSample],
        averageBPM: Double?,
        in rect: CGRect
    ) {
        drawChartBackground(in: rect)
        guard samples.count > 1,
              let firstDate = samples.first?.date,
              let lastDate = samples.last?.date else {
            drawCenteredText("Not enough data to plot.", in: rect)
            return
        }

        let plot = CGRect(
            x: rect.minX + 40,
            y: rect.minY + 12,
            width: rect.width - 52,
            height: rect.height - 40
        )

        let tMin = firstDate.timeIntervalSince1970
        let tMax = lastDate.timeIntervalSince1970
        let tRange = max(tMax - tMin, 1)

        // Long ranges: aggregate into buckets (min–max band + mean line)
        // instead of a path through tens of thousands of points.
        let buckets: [HeartRateBucket] = samples.count > maxRawChartPoints
            ? HeartRateBucket.make(from: samples, start: firstDate, end: lastDate.addingTimeInterval(1), maxBuckets: 600)
            : []

        let lowValue = buckets.isEmpty ? (samples.map(\.bpm).min() ?? 40) : (buckets.map(\.minBPM).min() ?? 40)
        let highValue = buckets.isEmpty ? (samples.map(\.bpm).max() ?? 160) : (buckets.map(\.maxBPM).max() ?? 160)
        let (yMin, yMax, yTicks) = niceYAxis(min: lowValue, max: highValue)

        func xFor(_ date: Date) -> CGFloat {
            plot.minX + CGFloat((date.timeIntervalSince1970 - tMin) / tRange) * plot.width
        }
        func yFor(_ bpm: Double) -> CGFloat {
            plot.maxY - CGFloat((bpm - yMin) / (yMax - yMin)) * plot.height
        }

        drawYGrid(ticks: yTicks, yFor: yFor, plot: plot, labelX: rect.minX + 4)
        drawAverageRule(averageBPM, yMin: yMin, yMax: yMax, yFor: yFor, plot: plot)

        // X ticks
        let xFormatter = tRange > 60 * 60 * 48 ? axisDayFormatter : axisTimeFormatter
        let xTickCount = 5
        for i in 0...xTickCount {
            let t = tMin + Double(i) * (tRange / Double(xTickCount))
            let x = plot.minX + CGFloat((t - tMin) / tRange) * plot.width
            drawLine(from: CGPoint(x: x, y: plot.maxY), to: CGPoint(x: x, y: plot.maxY + 3), color: axisColor)
            let label = xFormatter.string(from: Date(timeIntervalSince1970: t))
            drawString(label, at: CGPoint(x: x, y: plot.maxY + 6), attrs: axisLabelAttrs, align: .center)
        }

        drawAxes(plot)

        if buckets.isEmpty {
            let path = UIBezierPath()
            for (i, s) in samples.enumerated() {
                let p = CGPoint(x: xFor(s.date), y: yFor(s.bpm))
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            accentColor.setStroke()
            path.lineWidth = 1.4
            path.lineJoinStyle = .round
            path.stroke()
        } else {
            let band = UIBezierPath()
            for (i, b) in buckets.enumerated() {
                let p = CGPoint(x: xFor(b.mid), y: yFor(b.maxBPM))
                if i == 0 { band.move(to: p) } else { band.addLine(to: p) }
            }
            for b in buckets.reversed() {
                band.addLine(to: CGPoint(x: xFor(b.mid), y: yFor(b.minBPM)))
            }
            band.close()
            accentColor.withAlphaComponent(0.16).setFill()
            band.fill()

            let mean = UIBezierPath()
            for (i, b) in buckets.enumerated() {
                let p = CGPoint(x: xFor(b.mid), y: yFor(b.avgBPM))
                if i == 0 { mean.move(to: p) } else { mean.addLine(to: p) }
            }
            accentColor.setStroke()
            mean.lineWidth = 1.4
            mean.lineJoinStyle = .round
            mean.stroke()

            drawString("shaded: min–max range • line: average", at: CGPoint(x: plot.maxX, y: rect.minY + 2), attrs: axisLabelAttrs, align: .right)
        }

        drawString("BPM", at: CGPoint(x: rect.minX + 4, y: rect.minY + 2), attrs: [
            .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: labelColor,
        ])
    }

    // MARK: - Per-day detail (24-hour chart)

    private static let dayHeaderHeight: CGFloat = 34

    private static func drawDayHeader(day: DailyHeartRateStats, y: CGFloat) -> CGFloat {
        var y = y
        y = drawString(weekdayDayFormatter.string(from: day.day), at: CGPoint(x: margin, y: y), attrs: [
            .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: bodyColor,
        ])

        let statsStr = [
            "min \(intOrDash(day.minBPM))",
            "avg \(intOrDash(day.avgBPM))",
            "max \(intOrDash(day.maxBPM))",
            "resting \(intOrDash(day.restingBPM))",
            "\(day.sampleCount) samples",
        ].joined(separator: "   •   ")
        y = drawString(statsStr, at: CGPoint(x: margin, y: y), attrs: [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: labelColor,
        ])
        return y + 4
    }

    private static func drawDay24hChart(
        samples: [HeartRateSample],
        dayStart: Date,
        averageBPM: Double?,
        calendar: Calendar,
        in rect: CGRect
    ) {
        drawChartBackground(in: rect)

        let plot = CGRect(
            x: rect.minX + 40,
            y: rect.minY + 10,
            width: rect.width - 52,
            height: rect.height - 32
        )

        // Use the real day length (23/25 h on DST changes).
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let tMin = dayStart.timeIntervalSince1970
        let tMax = dayEnd.timeIntervalSince1970
        let tRange = max(tMax - tMin, 1)

        // X ticks — every 3 hours across the day
        for hour in stride(from: 0, through: 24, by: 3) {
            let t = tMin + Double(hour) * 3600
            guard t <= tMax + 1 else { break }
            let x = plot.minX + CGFloat((t - tMin) / tRange) * plot.width
            drawLine(from: CGPoint(x: x, y: plot.maxY), to: CGPoint(x: x, y: plot.maxY + 3), color: axisColor)
            drawString(String(format: "%02d", hour % 24), at: CGPoint(x: x, y: plot.maxY + 6), attrs: axisLabelAttrs, align: .center)
        }

        let daySamples = samples
            .filter { $0.date >= dayStart && $0.date < dayEnd }
            .sorted { $0.date < $1.date }

        guard !daySamples.isEmpty else {
            drawAxes(plot)
            drawCenteredText("No samples for this day.", in: plot)
            return
        }

        // Workouts record every few seconds; thin very dense days to
        // 2-minute averages so the PDF stays small and readable.
        let points: [(Date, Double)] = daySamples.count > 1440
            ? HeartRateBucket.make(from: daySamples, start: dayStart, end: dayEnd, maxBuckets: 720).map { ($0.mid, $0.avgBPM) }
            : daySamples.map { ($0.date, $0.bpm) }

        let values = points.map { $0.1 }
        let (yMin, yMax, yTicks) = niceYAxis(min: values.min() ?? 40, max: values.max() ?? 160)

        func yFor(_ bpm: Double) -> CGFloat {
            plot.maxY - CGFloat((bpm - yMin) / (yMax - yMin)) * plot.height
        }

        drawYGrid(ticks: yTicks, yFor: yFor, plot: plot, labelX: rect.minX + 4)
        drawAverageRule(averageBPM, yMin: yMin, yMax: yMax, yFor: yFor, plot: plot)
        drawAxes(plot)

        // Scatter: faint connector + dot at each sample
        let connector = UIBezierPath()
        var plotted: [CGPoint] = []
        plotted.reserveCapacity(points.count)
        for (i, point) in points.enumerated() {
            let x = plot.minX + CGFloat((point.0.timeIntervalSince1970 - tMin) / tRange) * plot.width
            let p = CGPoint(x: x, y: yFor(point.1))
            plotted.append(p)
            if i == 0 { connector.move(to: p) } else { connector.addLine(to: p) }
        }
        accentColor.withAlphaComponent(0.22).setStroke()
        connector.lineWidth = 0.6
        connector.lineCapStyle = .round
        connector.stroke()

        // Dots — smaller on dense days so they don't blob together
        let dotRadius: CGFloat = plotted.count > 600 ? 1.2 : (plotted.count > 200 ? 1.5 : 1.9)
        accentColor.setFill()
        for p in plotted {
            UIBezierPath(ovalIn: CGRect(x: p.x - dotRadius, y: p.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)).fill()
        }

        drawString("BPM", at: CGPoint(x: rect.minX + 4, y: rect.minY + 2), attrs: [
            .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: labelColor,
        ])
    }

    // MARK: - Chart helpers

    private static func drawYGrid(ticks: [Double], yFor: (Double) -> CGFloat, plot: CGRect, labelX: CGFloat) {
        for tick in ticks {
            let y = yFor(tick)
            drawDashedLine(from: CGPoint(x: plot.minX, y: y), to: CGPoint(x: plot.maxX, y: y), color: gridColor)
            drawString("\(Int(tick))", at: CGPoint(x: labelX, y: y - 6), attrs: axisLabelAttrs)
        }
    }

    private static func drawAverageRule(_ average: Double?, yMin: Double, yMax: Double, yFor: (Double) -> CGFloat, plot: CGRect) {
        guard let avg = average, avg >= yMin, avg <= yMax else { return }
        let y = yFor(avg)
        drawDashedLine(from: CGPoint(x: plot.minX, y: y), to: CGPoint(x: plot.maxX, y: y), color: averageColor)
        drawString("avg \(Int(avg.rounded()))", at: CGPoint(x: plot.maxX - 2, y: y - 12), attrs: axisLabelAttrs, align: .right)
    }

    private static func drawAxes(_ plot: CGRect) {
        drawLine(from: CGPoint(x: plot.minX, y: plot.maxY), to: CGPoint(x: plot.maxX, y: plot.maxY), color: axisColor)
        drawLine(from: CGPoint(x: plot.minX, y: plot.minY), to: CGPoint(x: plot.minX, y: plot.maxY), color: axisColor)
    }

    // MARK: - Drawing primitives

    private enum TextAlign { case left, center, right }

    @discardableResult
    private static func drawString(
        _ text: String,
        at point: CGPoint,
        attrs: [NSAttributedString.Key: Any],
        align: TextAlign = .left
    ) -> CGFloat {
        let ns = text as NSString
        let size = ns.size(withAttributes: attrs)
        let x: CGFloat
        switch align {
        case .left: x = point.x
        case .center: x = point.x - size.width / 2
        case .right: x = point.x - size.width
        }
        ns.draw(at: CGPoint(x: x, y: point.y), withAttributes: attrs)
        return point.y + size.height
    }

    private static func drawChartBackground(in rect: CGRect) {
        chartBackground.setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 6).fill()
    }

    private static func drawCenteredText(_ text: String, in rect: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attrs
        )
    }

    private static func drawHorizontalLine(at y: CGFloat, color: UIColor) {
        drawLine(from: CGPoint(x: margin, y: y), to: CGPoint(x: pageWidth - margin, y: y), color: color, width: 0.5)
    }

    private static func drawDashedLine(from a: CGPoint, to b: CGPoint, color: UIColor) {
        let path = UIBezierPath()
        path.move(to: a)
        path.addLine(to: b)
        path.setLineDash([2, 3], count: 2, phase: 0)
        color.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private static func drawLine(from a: CGPoint, to b: CGPoint, color: UIColor, width: CGFloat = 0.6) {
        let path = UIBezierPath()
        path.move(to: a)
        path.addLine(to: b)
        color.setStroke()
        path.lineWidth = width
        path.stroke()
    }

    private static var axisLabelAttrs: [NSAttributedString.Key: Any] {
        [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: axisColor,
        ]
    }

    // MARK: - Formatting helpers

    private static func niceYAxis(min minV: Double, max maxV: Double) -> (Double, Double, [Double]) {
        let padding = max(5, (maxV - minV) * 0.1)
        var lo = ((minV - padding) / 10).rounded(.down) * 10
        var hi = ((maxV + padding) / 10).rounded(.up) * 10
        if lo < 30 { lo = 30 }
        if hi - lo < 20 { hi = lo + 20 }
        let step = niceStep(for: hi - lo)
        var ticks: [Double] = []
        var v = lo
        while v <= hi + 0.01 {
            ticks.append(v)
            v += step
        }
        return (lo, hi, ticks)
    }

    private static func niceStep(for range: Double) -> Double {
        let approx = range / 5
        for c in [5.0, 10, 20, 25, 50] where approx <= c { return c }
        return 100
    }

    private static func format(_ value: Double?, unit: String) -> String {
        guard let value else { return "—" }
        return unit.isEmpty ? "\(Int(value.rounded()))" : "\(Int(value.rounded())) \(unit)"
    }

    private static func intOrDash(_ value: Double?) -> String {
        value.map { "\(Int($0.rounded()))" } ?? "—"
    }

    private static func avg(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    // DateFormatter is expensive to create; these are only used for
    // formatting, which is thread-safe.
    private static let shortDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt
    }()

    private static let dayOnlyFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt
    }()

    private static let weekdayDayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("EEEEMMMdy")
        return fmt
    }()

    private static let axisDayFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("MMMd")
        return fmt
    }()

    private static let axisTimeFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.setLocalizedDateFormatFromTemplate("jmm")
        return fmt
    }()

    private static let fileStampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd-HHmm"
        return fmt
    }()

    private static func shortDate(_ date: Date) -> String { shortDateFormatter.string(from: date) }
    private static func dayOnly(_ date: Date) -> String { dayOnlyFormatter.string(from: date) }

    // MARK: - Delta helpers

    private enum DeltaKind {
        case improvement, decline, neutral
        var color: UIColor {
            switch self {
            case .improvement: return PDFExporter.improvementColor
            case .decline:     return PDFExporter.declineColor
            case .neutral:     return PDFExporter.labelColor
            }
        }
    }

    private static func deltaText(current: Double?, previous: Double?, unit: String) -> String? {
        guard let c = current, let p = previous else { return nil }
        let d = c - p
        guard abs(d) >= 0.5 else { return nil }
        let sign = d > 0 ? "+" : "−"
        return "\(sign)\(Int(abs(d).rounded())) \(unit)"
    }

    private static func deltaKind(current: Double?, previous: Double?, lowerIsBetter: Bool?) -> DeltaKind? {
        guard let c = current, let p = previous else { return nil }
        let d = c - p
        guard abs(d) >= 0.5 else { return .neutral }
        guard let lowerIsBetter else { return .neutral }
        let goingDown = d < 0
        let improvement = (goingDown && lowerIsBetter) || (!goingDown && !lowerIsBetter)
        return improvement ? .improvement : .decline
    }

    /// Key/value two-column grid with optional per-row delta text.
    private static func drawDeltaKeyValueGrid(
        _ items: [(String, String, String?, DeltaKind?)],
        y: CGFloat
    ) -> CGFloat {
        let colWidth = contentWidth / 2
        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: labelColor,
        ]
        let valAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: bodyColor,
        ]

        var y = y
        let rowHeight: CGFloat = 20
        for i in stride(from: 0, to: items.count, by: 2) {
            drawDeltaRow(items[i], x: margin, width: colWidth, y: y, keyAttrs: keyAttrs, valAttrs: valAttrs)
            if i + 1 < items.count {
                drawDeltaRow(items[i + 1], x: margin + colWidth, width: colWidth, y: y, keyAttrs: keyAttrs, valAttrs: valAttrs)
            }
            y += rowHeight
        }
        return y
    }

    private static func drawDeltaRow(
        _ item: (String, String, String?, DeltaKind?),
        x: CGFloat,
        width: CGFloat,
        y: CGFloat,
        keyAttrs: [NSAttributedString.Key: Any],
        valAttrs: [NSAttributedString.Key: Any]
    ) {
        drawString(item.0, at: CGPoint(x: x, y: y), attrs: keyAttrs)

        let rightEdge = x + width - 4
        var valX = rightEdge

        // Draw delta (if any) first so we know how much space it takes
        if let deltaStr = item.2, let kind = item.3 {
            let deltaAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: kind.color,
            ]
            let size = (deltaStr as NSString).size(withAttributes: deltaAttrs)
            let deltaOrigin = CGPoint(x: rightEdge - size.width, y: y + 1)
            (deltaStr as NSString).draw(at: deltaOrigin, withAttributes: deltaAttrs)
            valX = deltaOrigin.x - 6
        }

        drawString(item.1, at: CGPoint(x: valX, y: y), attrs: valAttrs, align: .right)
    }

    // MARK: - Zones

    private static let zoneRowHeight: CGFloat = 14

    private static func drawZoneStackedBar(
        breakdown: ZoneBreakdown,
        in rect: CGRect,
        cornerRadius: CGFloat = 3
    ) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let track = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)
        UIColor(white: 0.92, alpha: 1).setFill()
        track.fill()

        guard breakdown.totalDuration > 0 else { return }

        // Clip to the rounded track so the outer slices get rounded ends.
        context.saveGState()
        track.addClip()
        var cursor = rect.minX
        for zone in HeartRateZone.allCases {
            let frac = breakdown.fraction(zone)
            guard frac > 0 else { continue }
            let width = rect.width * CGFloat(frac)
            zone.uiColor.setFill()
            UIBezierPath(rect: CGRect(x: cursor, y: rect.minY, width: width, height: rect.height)).fill()
            cursor += width
        }
        context.restoreGState()
    }

    private static func drawZoneTable(
        breakdown: ZoneBreakdown,
        maxHR: Double,
        y: CGFloat
    ) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: bodyColor,
        ]
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: bodyColor,
        ]
        let secondaryAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: labelColor,
        ]

        var y = y
        for zone in HeartRateZone.allCases {
            zone.uiColor.setFill()
            UIBezierPath(roundedRect: CGRect(x: margin, y: y + 2, width: 10, height: 10), cornerRadius: 2).fill()

            drawString(zone.label, at: CGPoint(x: margin + 16, y: y), attrs: labelAttrs)

            let range = zone.range(maxHR: maxHR)
            let rangeText = zone == .peak ? "\(range.lowerBound)+ bpm" : "\(range.lowerBound)–\(range.upperBound) bpm"
            drawString(rangeText, at: CGPoint(x: margin + 100, y: y), attrs: secondaryAttrs)

            drawString(DurationFormat.compact(breakdown.duration(zone)), at: CGPoint(x: margin + 220, y: y), attrs: attrs)

            let pct = "\(Int((breakdown.fraction(zone) * 100).rounded()))%"
            drawString(pct, at: CGPoint(x: pageWidth - margin, y: y), attrs: labelAttrs, align: .right)

            y += zoneRowHeight
        }
        return y
    }
}
