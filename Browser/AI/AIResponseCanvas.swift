import SwiftUI
import UIKit

struct AIResponseCanvasPresentation: Identifiable {
    let id: UUID
    let text: String
    let document: AIResponseDocument

    init(message: ChatMessage) {
        id = message.id
        text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        document = AIResponseDocumentParser.parse(message.text)
    }

    var isRedditReply: Bool {
        text.hasPrefix("Reddit summary coverage:")
            || text.hasPrefix("Reddit query coverage:")
    }

    var shouldAutoPresent: Bool {
        guard !isRedditReply else { return false }
        return document.containsRichContent
            || text.count >= 1_200
            || text.components(separatedBy: .newlines).count >= 18
    }

    var sidebarSummary: String {
        let tableCount = document.blocks.reduce(into: 0) { count, block in
            if case .table = block { count += 1 }
        }
        let codeCount = document.blocks.reduce(into: 0) { count, block in
            if case .code = block { count += 1 }
        }

        if tableCount > 0 {
            return tableCount == 1 ? "Table reply" : "Reply with \(tableCount) tables"
        }
        if codeCount > 0 {
            return codeCount == 1 ? "Reply with code" : "Reply with \(codeCount) code blocks"
        }
        return "Long formatted reply"
    }
}

struct AIResponseCanvas: View {
    let presentation: AIResponseCanvasPresentation

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        NavigationStack {
            ZStack {
                canvasBackground
                ScrollView {
                    AIResponseDocumentView(document: presentation.document, isDark: isDark)
                        .frame(maxWidth: 920, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Full Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = presentation.text
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .accessibilityHint("Copies the complete model reply")

                    ShareLink(item: presentation.text) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }

                    Button("Done", action: dismiss.callAsFunction)
                }
            }
            .modifier(AIResponseCanvasToolbarStyle())
        }
    }

    private var canvasBackground: some View {
        LinearGradient(
            colors: isDark
                ? [Color(red: 0.035, green: 0.055, blue: 0.09), Color(red: 0.09, green: 0.055, blue: 0.13)]
                : [Color(red: 0.91, green: 0.96, blue: 1), Color(red: 0.97, green: 0.93, blue: 1)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

private struct AIResponseCanvasToolbarStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    @ViewBuilder
    func browserResponseCanvasButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

struct AIResponseDocument {
    let blocks: [AIResponseBlock]

    var containsRichContent: Bool {
        blocks.contains { block in
            switch block {
            case .table, .code, .image:
                return true
            case .heading, .paragraph, .bullets, .numbered:
                return false
            }
        }
    }
}

enum AIResponseBlock: Identifiable {
    case heading(id: UUID, level: Int, text: String)
    case paragraph(id: UUID, text: String)
    case bullets(id: UUID, items: [String])
    case numbered(id: UUID, items: [String])
    case code(id: UUID, language: String?, text: String)
    case table(id: UUID, table: AIResponseTable)
    case image(id: UUID, alt: String, url: URL)

    var id: UUID {
        switch self {
        case .heading(let id, _, _),
             .paragraph(let id, _),
             .bullets(let id, _),
             .numbered(let id, _),
             .code(let id, _, _),
             .table(let id, _),
             .image(let id, _, _):
            return id
        }
    }
}

enum AIResponseTableAlignment {
    case leading
    case center
    case trailing
}

struct AIResponseTable {
    let title: String?
    let headers: [String]
    let rows: [[String]]
    let alignments: [AIResponseTableAlignment]
}

enum AIResponseDocumentParser {
    static func parse(_ text: String) -> AIResponseDocument {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [AIResponseBlock] = []
        var index = 0
        var paragraphLines: [String] = []

        func flushParagraph() {
            let content = paragraphLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty {
                if let image = parseImage(content) {
                    blocks.append(.image(id: UUID(), alt: image.alt, url: image.url))
                } else {
                    blocks.append(.paragraph(id: UUID(), text: content))
                }
            }
            paragraphLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(
                    .code(
                        id: UUID(),
                        language: language.isEmpty ? nil : language,
                        text: codeLines.joined(separator: "\n")
                    )
                )
                index += 1
                continue
            }

            if index + 1 < lines.count,
               line.contains("|"),
               let alignments = tableSeparatorAlignments(in: lines[index + 1]) {
                let headers = tableCells(in: line)
                if headers.count == alignments.count, headers.count >= 2 {
                    flushParagraph()
                    var rows: [[String]] = []
                    var rowIndex = index + 2
                    while rowIndex < lines.count {
                        let rowLine = lines[rowIndex]
                        let trimmedRow = rowLine.trimmingCharacters(in: .whitespaces)
                        guard !trimmedRow.isEmpty, rowLine.contains("|") else { break }
                        let cells = tableCells(in: rowLine)
                        guard cells.count >= 2 else { break }
                        rows.append(normalized(cells, columnCount: headers.count))
                        rowIndex += 1
                    }
                    blocks.append(
                        .table(
                            id: UUID(),
                            table: AIResponseTable(
                                title: tableTitle(before: index, in: lines),
                                headers: headers,
                                rows: rows,
                                alignments: alignments
                            )
                        )
                    )
                    index = max(rowIndex, index + 2)
                    continue
                }
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                blocks.append(.heading(id: UUID(), level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isBullet(trimmed) {
                flushParagraph()
                var items: [String] = []
                while index < lines.count {
                    let item = lines[index].trimmingCharacters(in: .whitespaces)
                    guard isBullet(item) else { break }
                    items.append(String(item.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                blocks.append(.bullets(id: UUID(), items: items))
                continue
            }

            if numberedContent(from: trimmed) != nil {
                flushParagraph()
                var items: [String] = []
                while index < lines.count {
                    let item = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let content = numberedContent(from: item) else { break }
                    items.append(content)
                    index += 1
                }
                blocks.append(.numbered(id: UUID(), items: items))
                continue
            }

            paragraphLines.append(trimmed)
            index += 1
        }

        flushParagraph()
        if blocks.isEmpty {
            blocks = [.paragraph(id: UUID(), text: text)]
        }
        return AIResponseDocument(blocks: blocks)
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let prefixCount = line.prefix { $0 == "#" }.count
        guard (1...6).contains(prefixCount), line.dropFirst(prefixCount).first == " " else { return nil }
        return (prefixCount, String(line.dropFirst(prefixCount + 1)))
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ")
    }

    private static func numberedContent(from line: String) -> String? {
        guard let range = line.range(of: #"^\d+[\.\)]\s+"#, options: .regularExpression) else { return nil }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    private static func parseImage(_ line: String) -> (alt: String, url: URL)? {
        guard let match = line.range(of: #"^!\[([^\]]*)\]\((https?://[^\s\)]+)\)$"#, options: .regularExpression) else {
            return nil
        }
        let value = String(line[match])
        guard let altEnd = value.range(of: "]("), value.hasPrefix("![") else { return nil }
        let alt = String(value[value.index(value.startIndex, offsetBy: 2)..<altEnd.lowerBound])
        let urlStart = altEnd.upperBound
        let urlString = String(value[urlStart..<value.index(before: value.endIndex)])
        guard let url = URL(string: urlString) else { return nil }
        return (alt, url)
    }

    private static func tableSeparatorAlignments(in line: String) -> [AIResponseTableAlignment]? {
        guard line.contains("|") else { return nil }
        let cells = tableCells(in: line)
        guard cells.count >= 2 else { return nil }
        var alignments: [AIResponseTableAlignment] = []
        for rawCell in cells {
            var marker = rawCell.trimmingCharacters(in: .whitespaces)
            let leading = marker.hasPrefix(":")
            let trailing = marker.hasSuffix(":")
            if leading { marker.removeFirst() }
            if trailing, !marker.isEmpty { marker.removeLast() }
            guard marker.count >= 3, marker.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(leading && trailing ? .center : (trailing ? .trailing : .leading))
        }
        return alignments
    }

    private static func tableCells(in line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaping = false
        for character in line {
            if escaping {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaping { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|"), cells.first?.isEmpty == true { cells.removeFirst() }
        if trimmed.hasSuffix("|"), cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    private static func normalized(_ cells: [String], columnCount: Int) -> [String] {
        if cells.count < columnCount {
            return cells + Array(repeating: "", count: columnCount - cells.count)
        }
        return Array(cells.prefix(columnCount))
    }

    private static func tableTitle(before index: Int, in lines: [String]) -> String? {
        guard index > 0 else { return nil }
        var title = lines[index - 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !title.contains("|") else { return nil }
        while title.hasPrefix("#") { title.removeFirst() }
        title = title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty || title.count > 100 ? nil : title
    }
}

enum AIResponseMarkdown {
    static func inline(_ value: String) -> AttributedString {
        (try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(value)
    }
}

struct AIResponseSidebarMarkdownView: View {
    let text: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let color: Color

    private var document: AIResponseDocument {
        AIResponseDocumentParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(document.blocks) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: AIResponseBlock) -> some View {
        switch block {
        case .heading(_, let level, let value):
            Text(AIResponseMarkdown.inline(value))
                .font(.system(size: headingSize(level), weight: .bold))
                .foregroundStyle(color)
        case .paragraph(_, let value):
            Text(AIResponseMarkdown.inline(value))
                .font(.system(size: fontSize))
                .lineSpacing(lineSpacing)
                .foregroundStyle(color)
        case .bullets(_, let items):
            list(items, numbered: false)
        case .numbered(_, let items):
            list(items, numbered: true)
        case .code(_, _, let value):
            Text(verbatim: value)
                .font(.system(size: fontSize, design: .monospaced))
                .foregroundStyle(color)
        case .table, .image:
            EmptyView()
        }
    }

    private func list(_ items: [String], numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(numbered ? "\(index + 1)." : "•")
                        .font(.system(size: fontSize, weight: .semibold))
                        .frame(minWidth: 16, alignment: .trailing)
                    Text(AIResponseMarkdown.inline(item))
                        .font(.system(size: fontSize))
                        .lineSpacing(lineSpacing)
                }
                .foregroundStyle(color)
            }
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return fontSize + 5
        case 2: return fontSize + 3
        default: return fontSize + 1
        }
    }
}

private struct AIResponseDocumentView: View {
    let document: AIResponseDocument
    let isDark: Bool

    private var primaryText: Color { isDark ? .white : .black }
    private var secondaryText: Color { isDark ? .white.opacity(0.74) : .black.opacity(0.68) }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(document.blocks) { block in
                blockView(block)
            }
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(isDark ? 0.16 : 0.6), lineWidth: 0.7)
        )
    }

    @ViewBuilder
    private func blockView(_ block: AIResponseBlock) -> some View {
        switch block {
        case .heading(_, let level, let text):
            Text(AIResponseMarkdown.inline(text))
                .font(headingFont(level))
                .foregroundStyle(primaryText)
                .textSelection(.enabled)
        case .paragraph(_, let text):
            Text(AIResponseMarkdown.inline(text))
                .font(.body)
                .lineSpacing(5)
                .foregroundStyle(primaryText)
                .textSelection(.enabled)
        case .bullets(_, let items):
            list(items: items, numbered: false)
        case .numbered(_, let items):
            list(items: items, numbered: true)
        case .code(_, let language, let text):
            AIResponseCodeBlock(language: language, text: text, isDark: isDark)
        case .table(_, let table):
            AIResponseTableView(table: table, isDark: isDark)
        case .image(_, let alt, let url):
            AIResponseImage(alt: alt, url: url, isDark: isDark)
        }
    }

    private func list(items: [String], numbered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(numbered ? "\(index + 1)." : "•")
                        .fontWeight(.semibold)
                        .foregroundStyle(secondaryText)
                        .frame(minWidth: 20, alignment: .trailing)
                    Text(AIResponseMarkdown.inline(item))
                        .foregroundStyle(primaryText)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .largeTitle.bold()
        case 2: return .title.bold()
        case 3: return .title2.bold()
        default: return .headline
        }
    }
}

private struct AIResponseCodeBlock: View {
    let language: String?
    let text: String
    let isDark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.uppercased() ?? "CODE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView(.horizontal) {
                Text(verbatim: text)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(isDark ? Color.white : Color.black)
                    .textSelection(.enabled)
                    .padding(14)
            }
        }
        .background(Color.black.opacity(isDark ? 0.24 : 0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
    }
}

private struct AIResponseImage: View {
    let alt: String
    let url: URL
    let isDark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ProgressView().frame(maxWidth: .infinity, minHeight: 180)
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    Label("Image unavailable", systemImage: "photo.badge.exclamationmark")
                        .frame(maxWidth: .infinity, minHeight: 180)
                @unknown default:
                    EmptyView()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            Text(alt.isEmpty ? url.absoluteString : alt)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct AIResponseTableView: View {
    let table: AIResponseTable
    let isDark: Bool

    private var primaryText: Color { isDark ? .white : .black }
    private var secondaryText: Color { isDark ? .white.opacity(0.76) : .black.opacity(0.68) }
    private var ruleColor: Color { Color.primary.opacity(0.14) }

    private var columnWidths: [CGFloat] {
        table.headers.indices.map { column in
            let values = [table.headers[column]] + table.rows.compactMap { row in
                row.indices.contains(column) ? row[column] : nil
            }
            let length = values.map(\.count).max() ?? 0
            return min(max(CGFloat(length) * 7.2 + 32, 132), 300)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = table.title {
                Text(title).font(.headline).foregroundStyle(primaryText)
            }
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    row(table.headers, header: true, index: 0)
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { index, values in
                        Divider().overlay(ruleColor)
                        row(values, header: false, index: index)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(ruleColor, lineWidth: 0.7))
            }
            .accessibilityLabel("Scrollable table with \(table.headers.count) columns and \(table.rows.count) rows")
        }
    }

    private func row(_ values: [String], header: Bool, index: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(table.headers.indices, id: \.self) { column in
                Text(AIResponseMarkdown.inline(values.indices.contains(column) ? values[column] : ""))
                    .font(.system(size: header ? 16 : 15, weight: header ? .semibold : .regular))
                    .foregroundStyle(header ? primaryText : secondaryText)
                    .multilineTextAlignment(textAlignment(table.alignments[column]))
                    .frame(width: columnWidths[column], alignment: frameAlignment(table.alignments[column]))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .textSelection(.enabled)
                if column < table.headers.count - 1 {
                    Divider().overlay(ruleColor)
                }
            }
        }
        .background(header ? Color.accentColor.opacity(0.14) : Color.primary.opacity(index.isMultiple(of: 2) ? 0.035 : 0))
    }

    private func frameAlignment(_ alignment: AIResponseTableAlignment) -> Alignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func textAlignment(_ alignment: AIResponseTableAlignment) -> TextAlignment {
        switch alignment {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
