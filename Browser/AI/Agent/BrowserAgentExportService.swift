import Foundation
import PDFKit
import UIKit
import WebKit

@MainActor
enum BrowserAgentExportService {
    static let maximumExportBytes = 12 * 1_024 * 1_024
    private static let maximumPagePDFHeight: CGFloat = 100_000

    enum ExportError: LocalizedError {
        case invalidDataset
        case pageTooTall
        case pagePDFTimeout
        case outputTooLarge

        var errorDescription: String? {
            switch self {
            case .invalidDataset:
                return "The selected browser dataset could not be exported."
            case .pageTooTall:
                return "The page is too tall to create a complete PDF safely."
            case .pagePDFTimeout:
                return "The page did not respond in time to prepare a PDF."
            case .outputTooLarge:
                return "The generated PDF exceeds the browser's export size limit."
            }
        }
    }

    struct Comparison: Equatable {
        struct Row: Equatable {
            let label: String
            let values: [String]
        }

        let title: String
        let summary: String
        let sources: [BrowserAgentDataset]
        let rows: [Row]
    }

    static func csv(for dataset: BrowserAgentDataset) -> Data {
        var rows: [[String]] = []
        switch dataset.kind {
        case .links:
            rows.append(["Source URL", "Page title", "Truncated", "Truncation reasons", "Link text", "Link title", "Link URL"])
            if dataset.links.isEmpty {
                rows.append([dataset.sourceURL, dataset.pageTitle, dataset.wasTruncated ? "yes" : "no", dataset.truncationReasons.joined(separator: "; "), "", "", ""])
            }
            for link in dataset.links {
                rows.append([dataset.sourceURL, dataset.pageTitle, dataset.wasTruncated ? "yes" : "no", dataset.truncationReasons.joined(separator: "; "), link.text, link.title, link.url])
            }
        case .htmlTable:
            for table in dataset.tables {
                let columnCount = max(table.headers.count, table.rows.map(\.count).max() ?? 0)
                let columnNames = (0..<columnCount).map { index in
                    let label = table.headers.indices.contains(index) ? table.headers[index] : ""
                    return label.isEmpty ? "Column \(index + 1)" : label
                }
                let width = 8 + columnCount
                rows.append(padded(["Source URL", "Page title", "Table", "Row type", "Row", "Truncated", "Truncation reasons", "Layout note"] + columnNames, to: width))
                rows.append([
                    dataset.sourceURL,
                    dataset.pageTitle,
                    table.title.isEmpty ? "Table \(table.index + 1)" : table.title,
                    "headers",
                    "",
                    table.wasTruncated || dataset.wasTruncated ? "yes" : "no",
                    (dataset.truncationReasons + (table.wasTruncated ? ["table_limit"] : [])).joined(separator: "; "),
                    table.layoutNote ?? ""
                ] + table.headers)
                for (rowIndex, row) in table.rows.enumerated() {
                    rows.append([
                        dataset.sourceURL,
                        dataset.pageTitle,
                        table.title.isEmpty ? "Table \(table.index + 1)" : table.title,
                        "data",
                        String(rowIndex + 1),
                        table.wasTruncated || dataset.wasTruncated ? "yes" : "no",
                        (dataset.truncationReasons + (table.wasTruncated ? ["table_limit"] : [])).joined(separator: "; "),
                        table.layoutNote ?? ""
                    ] + row)
                }
            }
        case .fetchedPage:
            rows.append(["Source URL", "Page title", "Truncated", "Truncation reasons", "Readable text"])
            rows.append([
                dataset.sourceURL,
                dataset.pageTitle,
                dataset.wasTruncated ? "yes" : "no",
                dataset.truncationReasons.joined(separator: "; "),
                dataset.fetchedText ?? ""
            ])
        }

        let width = rows.map(\.count).max() ?? 0
        let csv = rows.map { padded($0, to: width).map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        return Data(csv.utf8)
    }

    static func csv(for comparison: Comparison) -> Data {
        var rows: [[String]] = []
        let sourceHeaders = comparison.sources.enumerated().map { index, dataset in
            "Source \(index + 1): \(dataset.pageTitle.isEmpty ? dataset.title : dataset.pageTitle)"
        }
        rows.append(["Model-authored comparison", comparison.title])
        rows.append(["Summary", comparison.summary])
        for (index, dataset) in comparison.sources.enumerated() {
            rows.append(["Source \(index + 1) URL", dataset.sourceURL])
            rows.append(["Source \(index + 1) title", dataset.pageTitle])
            if dataset.wasTruncated {
                rows.append(["Source \(index + 1) truncation", dataset.truncationReasons.joined(separator: "; ")])
            }
        }
        rows.append(["Finding"] + sourceHeaders)
        rows.append(contentsOf: comparison.rows.map { [$0.label] + $0.values })
        let width = rows.map(\.count).max() ?? 0
        let csv = rows.map { padded($0, to: width).map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        return Data(csv.utf8)
    }

    static func pagePDF(from webView: WKWebView) async throws -> Data {
        try Task.checkCancellation()
        let measurement: String = try await AsyncTimeout.run(
            seconds: 6,
            timeoutError: { ExportError.pagePDFTimeout },
            operation: { @MainActor in
                try Task.checkCancellation()
                let value = try await webView.callAsyncJavaScript(
                    """
                    if (document.fonts && document.fonts.ready) {
                      await Promise.race([document.fonts.ready, new Promise(resolve => setTimeout(resolve, 1500))]);
                    }
                    const twoFrames = new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
                    await Promise.race([twoFrames, new Promise(resolve => setTimeout(resolve, 250))]);
                    const root = document.documentElement;
                    const body = document.body;
                    return JSON.stringify({
                      width: Math.ceil(Math.max(window.innerWidth || 0, root?.scrollWidth || 0, body?.scrollWidth || 0)),
                      height: Math.ceil(Math.max(window.innerHeight || 0, root?.scrollHeight || 0, body?.scrollHeight || 0))
                    });
                    """,
                    arguments: [:],
                    in: nil,
                    contentWorld: .page
                )
                try Task.checkCancellation()
                return value as? String ?? ""
            }
        )
        try Task.checkCancellation()
        guard let measurementData = measurement.data(using: .utf8),
              let dimensions = try? JSONSerialization.jsonObject(with: measurementData) as? [String: NSNumber] else {
            throw ExportError.invalidDataset
        }
        let width = max(max(webView.bounds.width, webView.scrollView.contentSize.width), max(CGFloat(dimensions["width"]?.doubleValue ?? 0), 1))
        let height = max(max(webView.bounds.height, webView.scrollView.contentSize.height), max(CGFloat(dimensions["height"]?.doubleValue ?? 0), 1))
        guard height <= maximumPagePDFHeight else { throw ExportError.pageTooTall }
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        try Task.checkCancellation()
        let pageData: Data = try await AsyncTimeout.run(
            seconds: 20,
            timeoutError: { ExportError.pagePDFTimeout },
            operation: { @MainActor in
                try Task.checkCancellation()
                let data = try await webView.pdf(configuration: configuration)
                try Task.checkCancellation()
                return data
            }
        )
        try Task.checkCancellation()
        guard isPDF(pageData) else { throw ExportError.invalidDataset }
        let sourceURL = webView.url.flatMap(BrowserAgentExtractionParser.safeSourceURL)?.absoluteString ?? ""
        let data = try addingCover(to: pageData, title: webView.title ?? "Webpage", sourceURL: sourceURL)
        guard data.count <= maximumExportBytes else { throw ExportError.outputTooLarge }
        return data
    }

    static func reportPDF(for datasets: [BrowserAgentDataset]) throws -> Data {
        guard !datasets.isEmpty else { throw ExportError.invalidDataset }
        let content = reportLines(for: datasets)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let data = renderer.pdfData { context in
            let margin: CGFloat = 42
            let lineAreaWidth = page.width - margin * 2
            let bottom = page.height - margin
            let bodyFont = UIFont.systemFont(ofSize: 9.5)
            let bodyBoldFont = UIFont.systemFont(ofSize: 9.5, weight: .semibold)
            var pageNumber = 0
            var cursorY: CGFloat = 0

            @MainActor func beginPage() {
                context.beginPage()
                UIColor.white.setFill()
                context.cgContext.fill(page)
                pageNumber += 1
                cursorY = margin
                if pageNumber > 1 {
                    let header = "Browser Agent Report • page \(pageNumber)"
                    draw(header, at: CGPoint(x: margin, y: 20), font: UIFont.systemFont(ofSize: 8), color: .darkGray)
                }
            }

            beginPage()
            for line in content {
                let font: UIFont
                let color: UIColor
                let gap: CGFloat
                switch line.style {
                case .title:
                    font = UIFont.systemFont(ofSize: 19, weight: .bold)
                    color = .black
                    gap = 6
                case .section:
                    font = UIFont.systemFont(ofSize: 12, weight: .bold)
                    color = .black
                    gap = 5
                case .label:
                    font = bodyBoldFont
                    color = .black
                    gap = 0
                case .body:
                    font = bodyFont
                    color = .darkGray
                    gap = 0
                case .note:
                    font = UIFont.italicSystemFont(ofSize: 9)
                    color = .darkGray
                    gap = 4
                case .spacer:
                    cursorY += 7
                    continue
                }

                for wrappedLine in wrapped(line.text, font: font, width: lineAreaWidth) {
                    let lineHeight = ceil(font.lineHeight + 2)
                    if cursorY + lineHeight > bottom {
                        beginPage()
                    }
                    draw(wrappedLine, at: CGPoint(x: margin, y: cursorY), font: font, color: color)
                    cursorY += lineHeight
                }
                cursorY += gap
            }
        }
        guard isPDF(data) else { throw ExportError.invalidDataset }
        guard data.count <= maximumExportBytes else { throw ExportError.outputTooLarge }
        return data
    }

    static func comparisonPDF(for comparison: Comparison) throws -> Data {
        guard !comparison.sources.isEmpty, !comparison.rows.isEmpty else { throw ExportError.invalidDataset }
        var lines = [ReportLine(text: "Model-Authored Comparison Report", style: .title),
                     ReportLine(text: comparison.title, style: .section),
                     ReportLine(text: comparison.summary, style: .body),
                     ReportLine(text: "The comparison below was composed by the browser agent from the captured datasets listed here.", style: .note)]
        for (index, source) in comparison.sources.enumerated() {
            lines.append(.init(text: "Source \(index + 1): \(source.pageTitle.isEmpty ? source.title : source.pageTitle)", style: .label))
            lines.append(.init(text: source.sourceURL, style: .body))
            if source.wasTruncated {
                lines.append(.init(text: "Source truncation: \(source.truncationReasons.joined(separator: ", "))", style: .note))
            }
        }
        lines.append(.init(text: "Comparison", style: .section))
        for (rowIndex, row) in comparison.rows.enumerated() {
            lines.append(.init(text: "\(rowIndex + 1). \(row.label)", style: .label))
            for (index, value) in row.values.enumerated() where comparison.sources.indices.contains(index) {
                let source = comparison.sources[index]
                lines.append(.init(text: "Source \(index + 1) (\(source.pageTitle.isEmpty ? source.title : source.pageTitle)): \(value)", style: .body))
            }
        }
        let data = try renderReport(lines)
        guard data.count <= maximumExportBytes else { throw ExportError.outputTooLarge }
        return data
    }

    static func filename(for dataset: BrowserAgentDataset, fileExtension: String) -> String {
        let stem = dataset.title.isEmpty ? "browser-agent-export" : dataset.title
        let safe = BrowserDownloadManager.sanitizeFilename(stem)
        return "\((safe as NSString).deletingPathExtension).\(fileExtension)"
    }

    static func reportFilename(for datasets: [BrowserAgentDataset]) -> String {
        let title = datasets.count > 1 ? "browser-comparison-report" : (datasets.first?.title ?? "browser-report")
        let safe = BrowserDownloadManager.sanitizeFilename(title)
        return "\((safe as NSString).deletingPathExtension).pdf"
    }

    static func comparisonFilename(for comparison: Comparison) -> String {
        let safe = BrowserDownloadManager.sanitizeFilename(comparison.title.isEmpty ? "browser-comparison" : comparison.title)
        return "\((safe as NSString).deletingPathExtension).pdf"
    }

    static func isPDF(_ data: Data) -> Bool {
        data.starts(with: Data("%PDF-".utf8))
    }

    private enum LineStyle {
        case title
        case section
        case label
        case body
        case note
        case spacer
    }

    private struct ReportLine {
        let text: String
        let style: LineStyle
    }

    private static func reportLines(for datasets: [BrowserAgentDataset]) -> [ReportLine] {
        var lines = [ReportLine(text: datasets.count > 1 ? "Browser Comparison Report" : "Browser Research Report", style: .title)]
        lines.append(ReportLine(text: "Collected from the browser on \(ISO8601DateFormatter().string(from: Date())).", style: .note))
        for (index, dataset) in datasets.enumerated() {
            lines.append(.init(text: "\(index + 1). \(dataset.title)", style: .section))
            lines.append(.init(text: "Source URL: \(dataset.sourceURL)", style: .body))
            lines.append(.init(text: "Page title: \(dataset.pageTitle)", style: .body))
            lines.append(.init(text: "Captured: \(dataset.capturedAt)", style: .note))
            if dataset.wasTruncated {
                let detail = dataset.truncationReasons.isEmpty ? "extraction limits were reached" : dataset.truncationReasons.joined(separator: ", ")
                lines.append(.init(text: "Truncation notice: Some page data was omitted because \(detail).", style: .note))
            }

            switch dataset.kind {
            case .links:
                if dataset.links.isEmpty {
                    lines.append(.init(text: "No links were returned.", style: .note))
                }
                for (linkIndex, link) in dataset.links.enumerated() {
                    lines.append(.init(text: "Link \(linkIndex + 1): \(link.text.isEmpty ? "(no visible link text)" : link.text)", style: .label))
                    if !link.title.isEmpty { lines.append(.init(text: "Link title: \(link.title)", style: .body)) }
                    lines.append(.init(text: "URL: \(link.url)", style: .body))
                }
            case .htmlTable:
                for table in dataset.tables {
                    let label = table.title.isEmpty ? "HTML table \(table.index + 1)" : "HTML table: \(table.title)"
                    lines.append(.init(text: label, style: .label))
                    if let layoutNote = table.layoutNote {
                        lines.append(.init(text: "Table layout note: \(layoutNote)", style: .note))
                    }
                    for (rowIndex, row) in table.rows.enumerated() {
                        lines.append(.init(text: "Row \(rowIndex + 1):", style: .label))
                        for (columnIndex, value) in row.enumerated() {
                            let name = table.headers.indices.contains(columnIndex) && !table.headers[columnIndex].isEmpty
                                ? table.headers[columnIndex]
                                : "Column \(columnIndex + 1)"
                            lines.append(.init(text: "\(name): \(value)", style: .body))
                        }
                    }
                    if table.wasTruncated {
                        lines.append(.init(text: "Truncation notice: The table exceeded the extraction bounds; only the retained rows and values are shown.", style: .note))
                    }
                }
            case .fetchedPage:
                lines.append(.init(text: "Fetched page text (bounded, read-only source):", style: .label))
                let text = dataset.fetchedText ?? ""
                if text.isEmpty {
                    lines.append(.init(text: "No readable text was captured.", style: .note))
                } else {
                    for paragraph in text.components(separatedBy: .newlines) where !paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
                        lines.append(.init(text: paragraph, style: .body))
                    }
                }
            }
            lines.append(.init(text: "", style: .spacer))
        }
        return lines
    }

    private static func renderReport(_ content: [ReportLine]) throws -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let margin: CGFloat = 42
        let bottom = page.height - margin
        let width = page.width - margin * 2
        var pageNumber = 0
        var cursorY: CGFloat = 0
        let data = renderer.pdfData { context in
            @MainActor func beginPage() {
                context.beginPage()
                UIColor.white.setFill()
                context.cgContext.fill(page)
                pageNumber += 1
                cursorY = margin
                if pageNumber > 1 {
                    draw("Browser Agent Comparison • page \(pageNumber)", at: CGPoint(x: margin, y: 20), font: UIFont.systemFont(ofSize: 8), color: .darkGray)
                }
            }
            beginPage()
            for line in content {
                let font: UIFont
                let color: UIColor
                let gap: CGFloat
                switch line.style {
                case .title: font = .systemFont(ofSize: 19, weight: .bold); color = .black; gap = 6
                case .section: font = .systemFont(ofSize: 12, weight: .bold); color = .black; gap = 5
                case .label: font = .systemFont(ofSize: 9.5, weight: .semibold); color = .black; gap = 0
                case .body: font = .systemFont(ofSize: 9.5); color = .darkGray; gap = 0
                case .note: font = .italicSystemFont(ofSize: 9); color = .darkGray; gap = 4
                case .spacer: cursorY += 7; continue
                }
                for wrappedLine in wrapped(line.text, font: font, width: width) {
                    let lineHeight = ceil(font.lineHeight + 2)
                    if cursorY + lineHeight > bottom { beginPage() }
                    draw(wrappedLine, at: CGPoint(x: margin, y: cursorY), font: font, color: color)
                    cursorY += lineHeight
                }
                cursorY += gap
            }
        }
        guard isPDF(data) else { throw ExportError.invalidDataset }
        return data
    }

    private static func addingCover(to pageData: Data, title: String, sourceURL: String) throws -> Data {
        let coverRenderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let coverData = coverRenderer.pdfData { context in
            let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
            context.beginPage()
            UIColor.white.setFill()
            context.cgContext.fill(bounds)
            draw("Webpage PDF", at: CGPoint(x: 48, y: 62), font: .systemFont(ofSize: 22, weight: .bold), color: .black)
            let titleFont = UIFont.systemFont(ofSize: 12, weight: .semibold)
            let sourceFont = UIFont.systemFont(ofSize: 9)
            var cursorY: CGFloat = 108
            for line in wrapped(title.isEmpty ? "Untitled page" : title, font: titleFont, width: bounds.width - 96) {
                draw(line, at: CGPoint(x: 48, y: cursorY), font: titleFont, color: .black)
                cursorY += titleFont.lineHeight + 2
            }
            cursorY += 8
            for line in wrapped(sourceURL, font: sourceFont, width: bounds.width - 96) {
                draw(line, at: CGPoint(x: 48, y: cursorY), font: sourceFont, color: .darkGray)
                cursorY += sourceFont.lineHeight + 2
            }
            cursorY += 10
            draw(
                "The following page contains the full page rendering.",
                at: CGPoint(x: 48, y: cursorY),
                font: sourceFont,
                color: .darkGray
            )
        }
        guard let cover = PDFDocument(data: coverData), let page = PDFDocument(data: pageData) else { throw ExportError.invalidDataset }
        let combined = PDFDocument()
        for index in 0..<cover.pageCount {
            if let pdfPage = cover.page(at: index) { combined.insert(pdfPage, at: combined.pageCount) }
        }
        for index in 0..<page.pageCount {
            if let pdfPage = page.page(at: index) { combined.insert(pdfPage, at: combined.pageCount) }
        }
        guard let data = combined.dataRepresentation() else { throw ExportError.invalidDataset }
        return data
    }

    private static func padded(_ row: [String], to width: Int) -> [String] {
        guard row.count < width else { return Array(row.prefix(width)) }
        return row + Array(repeating: "", count: width - row.count)
    }

    private static func csvField(_ rawValue: String) -> String {
        var value = rawValue
        let dangerous = value.unicodeScalars.drop {
            CharacterSet.whitespacesAndNewlines.contains($0)
                || CharacterSet.controlCharacters.contains($0)
                || $0.properties.generalCategory == .format
        }.first
        if let dangerous, "=+-@".unicodeScalars.contains(dangerous) {
            value = "'" + value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func wrapped(_ text: String, font: UIFont, width: CGFloat) -> [String] {
        let paragraphs = text.components(separatedBy: .newlines)
        var result: [String] = []
        for paragraph in paragraphs {
            if paragraph.isEmpty {
                result.append("")
                continue
            }
            var remaining = Array(paragraph)
            while !remaining.isEmpty {
                let fit = largestFittingPrefix(in: remaining, font: font, width: width)
                if fit >= remaining.count {
                    result.append(String(remaining))
                    break
                }
                var breakLength = fit
                let lastSpace = (0..<fit).last { remaining[$0].isWhitespace }
                if let lastSpace, lastSpace > 0 { breakLength = lastSpace }
                breakLength = max(1, breakLength)
                let line = String(remaining.prefix(breakLength)).trimmingCharacters(in: .whitespaces)
                result.append(line)
                var next = breakLength
                while next < remaining.count, remaining[next].isWhitespace {
                    next += 1
                }
                if next == 0 { next = 1 }
                remaining.removeFirst(next)
            }
        }
        return result
    }

    private static func largestFittingPrefix(in characters: [Character], font: UIFont, width: CGFloat) -> Int {
        var low = 1
        var high = characters.count
        var best = 0
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        while low <= high {
            let middle = low + (high - low) / 2
            let candidate = String(characters.prefix(middle)) as NSString
            if candidate.size(withAttributes: attributes).width <= width {
                best = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return max(1, best)
    }

    private static func draw(_ string: String, at point: CGPoint, font: UIFont, color: UIColor) {
        (string as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }
}
