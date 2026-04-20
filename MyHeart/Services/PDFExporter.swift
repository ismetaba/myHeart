import Foundation
import UIKit
import PDFKit

enum PDFExporter {
    private static let pageWidth: CGFloat = 612   // US Letter @72dpi
    private static let pageHeight: CGFloat = 792
    private static let margin: CGFloat = 48

    private static let titleColor = UIColor.systemPink
    private static let gridColor = UIColor(white: 0.75, alpha: 1)
    private static let axisColor = UIColor(white: 0.55, alpha: 1)
    private static let lineColor = UIColor.systemPink
    private static let labelColor = UIColor.darkGray
    private static let bodyColor = UIColor.label

    // MARK: - Public API

    static func exportOverall(
        summary: HeartRateSummary,
        samples: [HeartRateSample],
        rangeTitle: String
    ) throws -> URL {
        let data = render { ctx in
            let header = Header(
                title: "MyHeart Report",
                subtitle: rangeTitle
            )
            ctx.beginPage()
            var y = margin
            y = drawHeader(header, y: y)
            y += 12

            y = drawSectionHeader("Summary", y: y)
            y = drawKeyValueTwoColumn([
                ("Latest", summary.latest.map { "\(Int($0.bpm)) BPM • \(shortDate($0.date))" } ?? "—"),
                ("Average", format(summary.averageBPM, unit: "BPM")),
                ("Resting", format(summary.restingBPM, unit: "BPM")),
                ("HRV (SDNN)", format(summary.hrvSDNN, unit: "ms")),
                ("Min", format(summary.minBPM, unit: "BPM")),
                ("Max", format(summary.maxBPM, unit: "BPM")),
                ("Samples", "\(summary.sampleCount)"),
            ], y: y)
            y += 16

            y = drawSectionHeader("Heart Rate Trend", y: y)
            let chartRect = CGRect(x: margin, y: y, width: pageWidth - 2 * margin, height: 240)
            drawLineChart(samples: samples, averageBPM: summary.averageBPM, in: chartRect)
            y += chartRect.height + 18

            // Sample table, paginated.
            y = drawSectionHeader("Samples", y: y)
            y = drawTableHeader(["Date / Time", "BPM", "Source"], widths: [240, 60, 180], y: y)
            for sample in samples {
                if y > pageHeight - margin - 20 {
                    ctx.beginPage()
                    y = margin
                    y = drawPageHeader("MyHeart Report — continued", y: y) + 8
                    y = drawTableHeader(["Date / Time", "BPM", "Source"], widths: [240, 60, 180], y: y)
                }
                y = drawTableRow(
                    [shortDate(sample.date), "\(Int(sample.bpm.rounded()))", sample.source],
                    widths: [240, 60, 180],
                    y: y
                )
            }

            drawFooter()
        }
        return try write(data, prefix: "MyHeart-Overall")
    }

    static func exportDaily(
        stats: [DailyHeartRateStats],
        samples: [HeartRateSample],
        start: Date,
        end: Date
    ) throws -> URL {
        let calendar = Calendar.current
        var samplesByDay: [Date: [HeartRateSample]] = [:]
        for sample in samples {
            let day = calendar.startOfDay(for: sample.date)
            samplesByDay[day, default: []].append(sample)
        }

        let data = render { ctx in
            let header = Header(
                title: "MyHeart Daily Report",
                subtitle: "\(dayOnly(start)) — \(dayOnly(end))   •   \(stats.count) day\(stats.count == 1 ? "" : "s")"
            )
            ctx.beginPage()
            var y = margin
            y = drawHeader(header, y: y)
            y += 12

            // Aggregate summary
            let avgOfAvg = avg(stats.compactMap(\.avgBPM))
            let avgResting = avg(stats.compactMap(\.restingBPM))
            let minAll = stats.compactMap(\.minBPM).min()
            let maxAll = stats.compactMap(\.maxBPM).max()

            y = drawSectionHeader("Period Summary", y: y)
            y = drawKeyValueTwoColumn([
                ("Avg of Daily Avg", format(avgOfAvg, unit: "BPM")),
                ("Avg Resting", format(avgResting, unit: "BPM")),
                ("Lowest Daily Min", format(minAll, unit: "BPM")),
                ("Highest Daily Max", format(maxAll, unit: "BPM")),
            ], y: y)
            y += 16

            // Per-day detail: one 24-hour chart per day
            y = drawSectionHeader("Per-Day Detail (24-Hour View)", y: y)
            y += 4

            let dayChartHeight: CGFloat = 140
            let dayBlockHeight: CGFloat = dayChartHeight + 46  // header lines + chart + spacing
            for day in stats {
                if y + dayBlockHeight > pageHeight - margin {
                    ctx.beginPage()
                    y = margin
                    y = drawPageHeader("MyHeart Daily Report — continued", y: y) + 8
                }
                y = drawDayHeader(day: day, y: y)
                let daySamples = samplesByDay[day.day] ?? []
                let chartRect = CGRect(x: margin, y: y, width: pageWidth - 2 * margin, height: dayChartHeight)
                drawDay24hChart(samples: daySamples, dayStart: day.day, averageBPM: day.avgBPM, in: chartRect)
                y += chartRect.height + 18
            }

            // Per-day table, paginated
            if y + 80 > pageHeight - margin {
                ctx.beginPage()
                y = margin
                y = drawPageHeader("MyHeart Daily Report — continued", y: y) + 8
            }
            y = drawSectionHeader("Per-Day Breakdown", y: y)
            let cols = ["Date", "Min", "Avg", "Max", "Resting", "Samples"]
            let widths: [CGFloat] = [130, 60, 60, 60, 70, 80]
            y = drawTableHeader(cols, widths: widths, y: y)
            for day in stats {
                if y > pageHeight - margin - 20 {
                    ctx.beginPage()
                    y = margin
                    y = drawPageHeader("MyHeart Daily Report — continued", y: y) + 8
                    y = drawTableHeader(cols, widths: widths, y: y)
                }
                y = drawTableRow([
                    dayOnly(day.day),
                    intOrDash(day.minBPM),
                    intOrDash(day.avgBPM),
                    intOrDash(day.maxBPM),
                    intOrDash(day.restingBPM),
                    "\(day.sampleCount)",
                ], widths: widths, y: y)
            }

            drawFooter()
        }
        return try write(data, prefix: "MyHeart-Daily")
    }

    // MARK: - Rendering plumbing

    private struct Header {
        let title: String
        let subtitle: String
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
        let filename = "\(prefix)-\(Int(Date().timeIntervalSince1970)).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Header / footer

    private static func drawHeader(_ header: Header, y: CGFloat) -> CGFloat {
        var y = y
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 26, weight: .bold),
            .foregroundColor: titleColor,
        ]
        y = drawString(header.title, at: CGPoint(x: margin, y: y), attrs: titleAttrs)
        y += 2
        y = drawString(header.subtitle, at: CGPoint(x: margin, y: y), attrs: [
            .font: UIFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: labelColor,
        ])
        y += 4

        let generated = "Generated \(shortDate(Date()))"
        let genAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: axisColor,
        ]
        let size = (generated as NSString).size(withAttributes: genAttrs)
        (generated as NSString).draw(at: CGPoint(x: pageWidth - margin - size.width, y: margin + 2), withAttributes: genAttrs)

        // Underline rule
        drawHorizontalLine(at: y + 6, color: UIColor(white: 0.85, alpha: 1), dashed: false)
        return y + 12
    }

    private static func drawPageHeader(_ text: String, y: CGFloat) -> CGFloat {
        drawString(text, at: CGPoint(x: margin, y: y), attrs: [
            .font: UIFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: labelColor,
        ])
    }

    private static func drawFooter() {
        let text = "MyHeart • data sourced from Apple Health"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: axisColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: CGPoint(x: pageWidth / 2 - size.width / 2, y: pageHeight - margin + 12),
            withAttributes: attrs
        )
    }

    // MARK: - Sections

    private static func drawSectionHeader(_ text: String, y: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: bodyColor,
        ]
        let next = drawString(text, at: CGPoint(x: margin, y: y), attrs: attrs)
        drawHorizontalLine(at: next + 2, color: UIColor(white: 0.88, alpha: 1), dashed: false)
        return next + 10
    }

    private static func drawKeyValueTwoColumn(_ items: [(String, String)], y: CGFloat) -> CGFloat {
        let colWidth = (pageWidth - margin * 2) / 2
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
            (left.0 as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: keyAttrs)
            let leftValSize = (left.1 as NSString).size(withAttributes: valAttrs)
            (left.1 as NSString).draw(at: CGPoint(x: margin + colWidth - leftValSize.width - 8, y: y), withAttributes: valAttrs)

            if i + 1 < items.count {
                let right = items[i + 1]
                (right.0 as NSString).draw(at: CGPoint(x: margin + colWidth, y: y), withAttributes: keyAttrs)
                let rightValSize = (right.1 as NSString).size(withAttributes: valAttrs)
                (right.1 as NSString).draw(
                    at: CGPoint(x: pageWidth - margin - rightValSize.width, y: y),
                    withAttributes: valAttrs
                )
            }
            y += rowHeight
        }
        return y
    }

    // MARK: - Tables

    private static func drawTableHeader(_ columns: [String], widths: [CGFloat], y: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: labelColor,
        ]
        var x = margin
        for (i, col) in columns.enumerated() {
            (col as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
            x += widths[i]
        }
        let underline = y + 14
        drawHorizontalLine(at: underline, color: UIColor(white: 0.85, alpha: 1), dashed: false)
        return underline + 4
    }

    private static func drawTableRow(_ values: [String], widths: [CGFloat], y: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: bodyColor,
        ]
        var x = margin
        for (i, v) in values.enumerated() {
            (v as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
            x += widths[i]
        }
        return y + 15
    }

    // MARK: - Line chart (overall)

    private static func drawLineChart(
        samples: [HeartRateSample],
        averageBPM: Double?,
        in rect: CGRect
    ) {
        drawChartBackground(in: rect)
        guard samples.count > 1 else {
            drawCenteredText("Not enough data to plot.", in: rect)
            return
        }

        let padLeft: CGFloat = 40
        let padRight: CGFloat = 12
        let padTop: CGFloat = 12
        let padBottom: CGFloat = 28

        let plot = CGRect(
            x: rect.minX + padLeft,
            y: rect.minY + padTop,
            width: rect.width - padLeft - padRight,
            height: rect.height - padTop - padBottom
        )

        let bpms = samples.map(\.bpm)
        let (yMin, yMax, yTicks) = niceYAxis(min: bpms.min() ?? 40, max: bpms.max() ?? 160)

        let dates = samples.map(\.date).sorted()
        let tMin = dates.first!.timeIntervalSince1970
        let tMax = dates.last!.timeIntervalSince1970
        let tRange = max(tMax - tMin, 1)

        // Y gridlines + labels
        for tick in yTicks {
            let y = plot.maxY - CGFloat((tick - yMin) / (yMax - yMin)) * plot.height
            drawDashedHorizontalLine(from: CGPoint(x: plot.minX, y: y), to: CGPoint(x: plot.maxX, y: y), color: gridColor)
            drawString("\(Int(tick))", at: CGPoint(x: rect.minX + 4, y: y - 6), attrs: axisLabelAttrs, align: .left)
        }

        // Average rule
        if let avg = averageBPM, avg >= yMin, avg <= yMax {
            let y = plot.maxY - CGFloat((avg - yMin) / (yMax - yMin)) * plot.height
            drawDashedHorizontalLine(from: CGPoint(x: plot.minX, y: y), to: CGPoint(x: plot.maxX, y: y), color: UIColor.systemGray)
            drawString("avg \(Int(avg))", at: CGPoint(x: plot.maxX - 44, y: y - 12), attrs: axisLabelAttrs, align: .left)
        }

        // X ticks
        let xTickCount = 5
        let xFmt = DateFormatter()
        xFmt.dateFormat = tRange > 60 * 60 * 48 ? "MMM d" : "HH:mm"
        for i in 0...xTickCount {
            let t = tMin + Double(i) * (tRange / Double(xTickCount))
            let x = plot.minX + CGFloat((t - tMin) / tRange) * plot.width
            drawVerticalLine(from: CGPoint(x: x, y: plot.maxY), to: CGPoint(x: x, y: plot.maxY + 3), color: axisColor)
            let label = xFmt.string(from: Date(timeIntervalSince1970: t))
            drawString(label, at: CGPoint(x: x, y: plot.maxY + 6), attrs: axisLabelAttrs, align: .center)
        }

        // Axes
        drawLine(from: CGPoint(x: plot.minX, y: plot.maxY), to: CGPoint(x: plot.maxX, y: plot.maxY), color: axisColor)
        drawLine(from: CGPoint(x: plot.minX, y: plot.minY), to: CGPoint(x: plot.minX, y: plot.maxY), color: axisColor)

        // Line
        let path = UIBezierPath()
        let sorted = samples.sorted { $0.date < $1.date }
        for (i, s) in sorted.enumerated() {
            let x = plot.minX + CGFloat((s.date.timeIntervalSince1970 - tMin) / tRange) * plot.width
            let y = plot.maxY - CGFloat((s.bpm - yMin) / (yMax - yMin)) * plot.height
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        lineColor.setStroke()
        path.lineWidth = 1.4
        path.stroke()

        // Y-axis label
        drawString("BPM", at: CGPoint(x: rect.minX + 4, y: rect.minY + 2), attrs: [
            .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: labelColor,
        ], align: .left)
    }

    // MARK: - Per-day detail (24-hour chart)

    private static func drawDayHeader(day: DailyHeartRateStats, y: CGFloat) -> CGFloat {
        var y = y
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: bodyColor,
        ]
        let dateStr = "\(weekdayName(day.day)), \(dayOnly(day.day))"
        y = drawString(dateStr, at: CGPoint(x: margin, y: y), attrs: titleAttrs)

        let statsStr = [
            "min \(intOrDash(day.minBPM))",
            "avg \(intOrDash(day.avgBPM))",
            "max \(intOrDash(day.maxBPM))",
            "resting \(intOrDash(day.restingBPM))",
            "\(day.sampleCount) samples",
        ].joined(separator: "   •   ")
        let statsAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: labelColor,
        ]
        y = drawString(statsStr, at: CGPoint(x: margin, y: y), attrs: statsAttrs)
        return y + 4
    }

    private static func drawDay24hChart(
        samples: [HeartRateSample],
        dayStart: Date,
        averageBPM: Double?,
        in rect: CGRect
    ) {
        drawChartBackground(in: rect)

        let padLeft: CGFloat = 40
        let padRight: CGFloat = 12
        let padTop: CGFloat = 10
        let padBottom: CGFloat = 22

        let plot = CGRect(
            x: rect.minX + padLeft,
            y: rect.minY + padTop,
            width: rect.width - padLeft - padRight,
            height: rect.height - padTop - padBottom
        )

        let tMin = dayStart.timeIntervalSince1970
        let tMax = tMin + 86400
        let tRange = tMax - tMin

        // X ticks — every 3 hours across the full 24-hour day
        let hourStride = 3
        for hour in stride(from: 0, through: 24, by: hourStride) {
            let t = tMin + Double(hour) * 3600
            let x = plot.minX + CGFloat((t - tMin) / tRange) * plot.width
            drawVerticalLine(from: CGPoint(x: x, y: plot.maxY), to: CGPoint(x: x, y: plot.maxY + 3), color: axisColor)
            let label = String(format: "%02d", hour % 24)
            drawString(label, at: CGPoint(x: x, y: plot.maxY + 6), attrs: axisLabelAttrs, align: .center)
        }

        let daySamples = samples.filter {
            let t = $0.date.timeIntervalSince1970
            return t >= tMin && t <= tMax
        }

        guard !daySamples.isEmpty else {
            drawLine(from: CGPoint(x: plot.minX, y: plot.maxY), to: CGPoint(x: plot.maxX, y: plot.maxY), color: axisColor)
            drawLine(from: CGPoint(x: plot.minX, y: plot.minY), to: CGPoint(x: plot.minX, y: plot.maxY), color: axisColor)
            drawCenteredText("No samples for this day.", in: plot)
            return
        }

        let bpms = daySamples.map(\.bpm)
        let (yMin, yMax, yTicks) = niceYAxis(min: bpms.min() ?? 40, max: bpms.max() ?? 160)

        // Y gridlines + labels
        for tick in yTicks {
            let y = plot.maxY - CGFloat((tick - yMin) / (yMax - yMin)) * plot.height
            drawDashedHorizontalLine(from: CGPoint(x: plot.minX, y: y), to: CGPoint(x: plot.maxX, y: y), color: gridColor)
            drawString("\(Int(tick))", at: CGPoint(x: rect.minX + 4, y: y - 6), attrs: axisLabelAttrs, align: .left)
        }

        // Average rule
        if let avg = averageBPM, avg >= yMin, avg <= yMax {
            let y = plot.maxY - CGFloat((avg - yMin) / (yMax - yMin)) * plot.height
            drawDashedHorizontalLine(from: CGPoint(x: plot.minX, y: y), to: CGPoint(x: plot.maxX, y: y), color: UIColor.systemGray)
            drawString("avg \(Int(avg))", at: CGPoint(x: plot.maxX - 44, y: y - 12), attrs: axisLabelAttrs, align: .left)
        }

        // Axes
        drawLine(from: CGPoint(x: plot.minX, y: plot.maxY), to: CGPoint(x: plot.maxX, y: plot.maxY), color: axisColor)
        drawLine(from: CGPoint(x: plot.minX, y: plot.minY), to: CGPoint(x: plot.minX, y: plot.maxY), color: axisColor)

        // Line
        let path = UIBezierPath()
        let sorted = daySamples.sorted { $0.date < $1.date }
        for (i, s) in sorted.enumerated() {
            let x = plot.minX + CGFloat((s.date.timeIntervalSince1970 - tMin) / tRange) * plot.width
            let y = plot.maxY - CGFloat((s.bpm - yMin) / (yMax - yMin)) * plot.height
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        lineColor.setStroke()
        path.lineWidth = 1.0
        path.stroke()

        // Y-axis label
        drawString("BPM", at: CGPoint(x: rect.minX + 4, y: rect.minY + 2), attrs: [
            .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: labelColor,
        ], align: .left)
    }

    private static func weekdayName(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE"
        return fmt.string(from: date)
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
        UIColor(white: 0.985, alpha: 1).setFill()
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

    private static func drawHorizontalLine(at y: CGFloat, color: UIColor, dashed: Bool) {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: y))
        path.addLine(to: CGPoint(x: pageWidth - margin, y: y))
        if dashed { path.setLineDash([2, 3], count: 2, phase: 0) }
        color.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private static func drawDashedHorizontalLine(from a: CGPoint, to b: CGPoint, color: UIColor) {
        let path = UIBezierPath()
        path.move(to: a)
        path.addLine(to: b)
        path.setLineDash([2, 3], count: 2, phase: 0)
        color.setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private static func drawLine(from a: CGPoint, to b: CGPoint, color: UIColor) {
        let path = UIBezierPath()
        path.move(to: a); path.addLine(to: b)
        color.setStroke()
        path.lineWidth = 0.6
        path.stroke()
    }

    private static func drawVerticalLine(from a: CGPoint, to b: CGPoint, color: UIColor) {
        drawLine(from: a, to: b, color: color)
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
        var lo = (minV - padding)
        var hi = (maxV + padding)
        // Round to nearest 10
        lo = (lo / 10).rounded(.down) * 10
        hi = (hi / 10).rounded(.up) * 10
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
        let candidates: [Double] = [5, 10, 20, 25, 50]
        for c in candidates where approx <= c { return c }
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

    private static func shortDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    private static func dayOnly(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .none
        return fmt.string(from: date)
    }
}
