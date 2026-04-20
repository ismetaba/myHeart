import Foundation
import UIKit
import PDFKit

enum PDFExporter {
    private static let pageWidth: CGFloat = 612   // US Letter @72dpi
    private static let pageHeight: CGFloat = 792
    private static let margin: CGFloat = 48

    static func export(summary: HeartRateSummary, samples: [HeartRateSample]) throws -> URL {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextCreator as String: "MyHeart",
            kCGPDFContextTitle as String: "Heart Rate Report",
        ]

        let bounds = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)

        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .medium
        dateFmt.timeStyle = .short

        let data = renderer.pdfData { ctx in
            ctx.beginPage()
            var y: CGFloat = margin

            y = drawTitle("MyHeart Report", y: y)
            y += 4
            y = drawSubtitle(
                "\(dateFmt.string(from: summary.rangeStart)) — \(dateFmt.string(from: summary.rangeEnd))",
                y: y
            )
            y += 16

            y = drawSectionHeader("Summary", y: y)
            y = drawKeyValue("Latest", value: summary.latest.map { "\(Int($0.bpm)) BPM at \(dateFmt.string(from: $0.date))" } ?? "—", y: y)
            y = drawKeyValue("Resting Heart Rate", value: format(summary.restingBPM, unit: "BPM"), y: y)
            y = drawKeyValue("Average", value: format(summary.averageBPM, unit: "BPM"), y: y)
            y = drawKeyValue("Min / Max", value: "\(format(summary.minBPM, unit: "")) / \(format(summary.maxBPM, unit: "BPM"))", y: y)
            y = drawKeyValue("HRV (SDNN)", value: format(summary.hrvSDNN, unit: "ms"), y: y)
            y = drawKeyValue("Sample Count", value: "\(summary.sampleCount)", y: y)
            y += 12

            y = drawSectionHeader("Trend", y: y)
            let chartRect = CGRect(x: margin, y: y, width: pageWidth - 2 * margin, height: 180)
            drawChart(samples: samples, in: chartRect)
            y += chartRect.height + 16

            y = drawSectionHeader("Samples", y: y)
            y = drawTableHeader(y: y)

            for sample in samples {
                if y > pageHeight - margin - 20 {
                    ctx.beginPage()
                    y = margin
                    y = drawTableHeader(y: y)
                }
                y = drawTableRow(
                    date: dateFmt.string(from: sample.date),
                    bpm: "\(Int(sample.bpm.rounded()))",
                    source: sample.source,
                    y: y
                )
            }
        }

        let filename = "MyHeart-Report-\(Int(Date().timeIntervalSince1970)).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - Drawing helpers

    private static func format(_ value: Double?, unit: String) -> String {
        guard let value else { return "—" }
        return unit.isEmpty ? "\(Int(value.rounded()))" : "\(Int(value.rounded())) \(unit)"
    }

    private static func drawTitle(_ text: String, y: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 28, weight: .bold),
            .foregroundColor: UIColor.systemPink,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attrs)
        return y + size.height
    }

    private static func drawSubtitle(_ text: String, y: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: UIColor.darkGray,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attrs)
        return y + size.height
    }

    private static func drawSectionHeader(_ text: String, y: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: UIColor.label,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attrs)

        let lineY = y + size.height + 2
        let path = UIBezierPath()
        path.move(to: CGPoint(x: margin, y: lineY))
        path.addLine(to: CGPoint(x: pageWidth - margin, y: lineY))
        UIColor.lightGray.setStroke()
        path.lineWidth = 0.5
        path.stroke()

        return lineY + 8
    }

    private static func drawKeyValue(_ key: String, value: String, y: CGFloat) -> CGFloat {
        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: UIColor.darkGray,
        ]
        let valAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: UIColor.label,
        ]
        (key as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: keyAttrs)
        let valSize = (value as NSString).size(withAttributes: valAttrs)
        (value as NSString).draw(at: CGPoint(x: pageWidth - margin - valSize.width, y: y), withAttributes: valAttrs)
        return y + max(valSize.height, 14) + 4
    }

    private static func drawTableHeader(y: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: UIColor.darkGray,
        ]
        ("Date / Time" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attrs)
        ("BPM" as NSString).draw(at: CGPoint(x: margin + 220, y: y), withAttributes: attrs)
        ("Source" as NSString).draw(at: CGPoint(x: margin + 290, y: y), withAttributes: attrs)
        return y + 16
    }

    private static func drawTableRow(date: String, bpm: String, source: String, y: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: UIColor.label,
        ]
        (date as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attrs)
        (bpm as NSString).draw(at: CGPoint(x: margin + 220, y: y), withAttributes: attrs)
        (source as NSString).draw(at: CGPoint(x: margin + 290, y: y), withAttributes: attrs)
        return y + 14
    }

    private static func drawChart(samples: [HeartRateSample], in rect: CGRect) {
        UIColor(white: 0.96, alpha: 1).setFill()
        UIBezierPath(roundedRect: rect, cornerRadius: 8).fill()

        guard samples.count > 1 else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: UIColor.darkGray,
            ]
            let text = "Not enough data to plot."
            let size = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(
                at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                withAttributes: attrs
            )
            return
        }

        let bpms = samples.map(\.bpm)
        let minBPM = (bpms.min() ?? 0) - 5
        let maxBPM = (bpms.max() ?? 1) + 5
        let bpmRange = max(maxBPM - minBPM, 1)

        let dates = samples.map(\.date.timeIntervalSince1970).sorted()
        let minT = dates.first!
        let maxT = dates.last!
        let tRange = max(maxT - minT, 1)

        let inset: CGFloat = 12
        let plot = rect.insetBy(dx: inset, dy: inset)

        let path = UIBezierPath()
        let sorted = samples.sorted { $0.date < $1.date }
        for (i, s) in sorted.enumerated() {
            let x = plot.minX + CGFloat((s.date.timeIntervalSince1970 - minT) / tRange) * plot.width
            let y = plot.maxY - CGFloat((s.bpm - minBPM) / bpmRange) * plot.height
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        UIColor.systemPink.setStroke()
        path.lineWidth = 1.5
        path.stroke()

        let axisAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor.darkGray,
        ]
        ("\(Int(maxBPM))" as NSString).draw(at: CGPoint(x: rect.minX + 2, y: rect.minY + 2), withAttributes: axisAttrs)
        ("\(Int(minBPM))" as NSString).draw(at: CGPoint(x: rect.minX + 2, y: rect.maxY - 12), withAttributes: axisAttrs)
    }
}
