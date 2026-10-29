import Foundation

struct BrowserAgentDataset: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case links
        case htmlTable
        case fetchedPage
    }

    struct Link: Codable, Equatable {
        let text: String
        let url: String
        let title: String
    }

    struct HTMLTable: Codable, Equatable {
        let index: Int
        let title: String
        let layoutNote: String?
        let headers: [String]
        let rows: [[String]]
        let sourceRowCount: Int
        let wasTruncated: Bool
    }

    let id: UUID
    let kind: Kind
    let title: String
    let pageTitle: String
    let sourceURL: String
    /// Nil only for a background-fetched source, which is not a live browser tab.
    let sourceTabID: UUID?
    let capturedAt: String
    let wasTruncated: Bool
    let truncationReasons: [String]
    let links: [Link]
    let tables: [HTMLTable]
    let fetchedText: String?

    init(
        id: UUID,
        kind: Kind,
        title: String,
        pageTitle: String,
        sourceURL: String,
        sourceTabID: UUID?,
        capturedAt: String,
        wasTruncated: Bool,
        truncationReasons: [String],
        links: [Link],
        tables: [HTMLTable],
        fetchedText: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.pageTitle = pageTitle
        self.sourceURL = sourceURL
        self.sourceTabID = sourceTabID
        self.capturedAt = capturedAt
        self.wasTruncated = wasTruncated
        self.truncationReasons = truncationReasons
        self.links = links
        self.tables = tables
        self.fetchedText = fetchedText
    }

    static func fetchedPage(_ page: BrowserAgentBackgroundLoader.Page) -> BrowserAgentDataset? {
        guard let source = BrowserAgentExtractionParser.safeSourceURL(page.url) else { return nil }
        let title = String(page.title.prefix(300))
        let text = String(page.text.prefix(BrowserAgentBackgroundLoader.maximumTextCharacters))
        let wasTruncated = page.truncated || text.count < page.text.count || title.count < page.title.count
        let reasons = wasTruncated ? ["fetched_text_limit"] : []
        return BrowserAgentDataset(
            id: UUID(),
            kind: .fetchedPage,
            title: title.isEmpty ? "Fetched page from \(source.host ?? "website")" : title,
            pageTitle: title,
            sourceURL: source.absoluteString,
            sourceTabID: nil,
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            wasTruncated: wasTruncated,
            truncationReasons: reasons,
            links: [],
            tables: [],
            fetchedText: text
        )
    }

    var characterCount: Int {
        title.count + sourceURL.count
            + pageTitle.count
            + links.reduce(0) { $0 + $1.text.count + $1.title.count + $1.url.count }
            + tables.reduce(0) { total, table in
                total + table.title.count + table.headers.reduce(0) { $0 + $1.count }
                    + table.rows.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
            }
            + (fetchedText?.count ?? 0)
    }

    func jsonForModel() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }
}

struct BrowserAgentExtractionResult: Equatable {
    let pageTitle: String
    let sourceURL: String
    let datasets: [BrowserAgentDataset]
    let truncated: Bool
    let truncationReasons: [String]
}

enum BrowserAgentExtractionParser {
    static let maximumLinks = 80
    static let maximumTables = 8
    static let maximumRowsPerTable = 100
    static let maximumColumnsPerTable = 16
    static let maximumCellCharacters = 400
    static let maximumLinkTextCharacters = 240
    static let maximumURLCharacters = 2_000
    static let maximumLinkDatasetCharacters = 42_000
    static let maximumTableDatasetCharacters = 72_000

    static func links(
        from json: String,
        sourceTabID: UUID,
        fallbackURL: URL?
    ) -> BrowserAgentExtractionResult? {
        guard let object = jsonObject(json),
              let sourceURL = sourceURL(in: object, fallback: fallbackURL) else { return nil }

        let rawPageTitle = object["title"] as? String ?? ""
        let pageTitle = boundedText(rawPageTitle, limit: 300)
        let rawLinks = object["links"] as? [[String: Any]] ?? []
        var links: [BrowserAgentDataset.Link] = []
        var usedCharacters = pageTitle.count + sourceURL.count
        var reasons = object["truncationReasons"] as? [String] ?? []
        var truncated = object["truncated"] as? Bool == true
        if pageTitle.count < rawPageTitle.count {
            truncated = true
            reasons.append("page_title_limit")
        }
        if int(object["totalLinks"]) > rawLinks.count { truncated = true }
        if rawLinks.count > maximumLinks {
            reasons.append("link_count_limit")
            truncated = true
        }

        for raw in rawLinks.prefix(maximumLinks) {
            guard let rawURL = raw["url"] as? String,
                  let url = safeSourceURL(rawURL),
                  url.absoluteString.count <= maximumURLCharacters else {
                truncated = true
                reasons.append("unsupported_or_long_link_url")
                continue
            }
            let rawTitle = raw["title"] as? String ?? ""
            let rawText = raw["text"] as? String ?? ""
            let title = boundedText(rawTitle, limit: maximumLinkTextCharacters)
            let text = boundedText(rawText, limit: maximumLinkTextCharacters)
            if title.count < rawTitle.count || text.count < rawText.count {
                truncated = true
                reasons.append("link_text_limit")
            }
            let nextCount = usedCharacters + title.count + text.count + url.absoluteString.count
            guard nextCount <= maximumLinkDatasetCharacters else {
                truncated = true
                reasons.append("dataset_character_limit")
                break
            }
            links.append(.init(text: text, url: url.absoluteString, title: title))
            usedCharacters = nextCount
        }

        let dataset = BrowserAgentDataset(
            id: UUID(),
            kind: .links,
            title: pageTitle.isEmpty ? "Links from page" : "Links from \(pageTitle)",
            pageTitle: pageTitle,
            sourceURL: sourceURL,
            sourceTabID: sourceTabID,
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            wasTruncated: truncated,
            truncationReasons: unique(reasons),
            links: links,
            tables: []
        )
        return BrowserAgentExtractionResult(
            pageTitle: pageTitle,
            sourceURL: sourceURL,
            datasets: [dataset],
            truncated: dataset.wasTruncated,
            truncationReasons: dataset.truncationReasons
        )
    }

    static func tables(
        from json: String,
        sourceTabID: UUID,
        fallbackURL: URL?
    ) -> BrowserAgentExtractionResult? {
        guard let object = jsonObject(json),
              let sourceURL = sourceURL(in: object, fallback: fallbackURL) else { return nil }

        let rawPageTitle = object["title"] as? String ?? ""
        let pageTitle = boundedText(rawPageTitle, limit: 300)
        let rawTables = object["tables"] as? [[String: Any]] ?? []
        var datasets: [BrowserAgentDataset] = []
        var reasons = object["truncationReasons"] as? [String] ?? []
        var wasTruncated = object["truncated"] as? Bool == true
        if pageTitle.count < rawPageTitle.count {
            wasTruncated = true
            reasons.append("page_title_limit")
        }
        if int(object["totalTables"]) > rawTables.count {
            wasTruncated = true
            reasons.append("table_count_limit")
        }
        if rawTables.count > maximumTables {
            reasons.append("table_count_limit")
            wasTruncated = true
        }

        let pageReasons = reasons
        var totalCharacters = pageTitle.count + sourceURL.count
        for raw in rawTables.prefix(maximumTables) {
            let rawHeaders = raw["headers"] as? [String] ?? []
            let rawRows = raw["rows"] as? [[String]] ?? []
            let rawIndex = int(raw["index"])
            let rawTableTitle = raw["title"] as? String ?? ""
            let tableTitle = boundedText(rawTableTitle, limit: 240)
            var tableReasons: [String] = pageReasons
            var tableTruncated = raw["truncated"] as? Bool == true
            tableReasons.append(contentsOf: raw["truncationReasons"] as? [String] ?? [])
            let layoutNote = raw["layoutNote"] as? String
            if tableTitle.count < rawTableTitle.count {
                tableTruncated = true
                tableReasons.append("table_title_limit")
            }
            if int(raw["totalRows"]) > rawRows.count { tableTruncated = true }
            if rawHeaders.count > maximumColumnsPerTable {
                tableTruncated = true
                tableReasons.append("column_limit")
            }
            if int(raw["totalColumns"]) > maximumColumnsPerTable {
                tableTruncated = true
                tableReasons.append("column_limit")
            }
            if layoutNote != nil {
                tableTruncated = true
                tableReasons.append("table_spans_unaligned")
            }
            if rawRows.count > maximumRowsPerTable {
                tableTruncated = true
                tableReasons.append("row_limit")
            }

            let available = max(0, maximumTableDatasetCharacters - totalCharacters)
            let retainedTableTitle = String(tableTitle.prefix(available))
            var tableCharacters = retainedTableTitle.count
            var headers: [String] = []
            var hitCharacterLimit = retainedTableTitle.count < tableTitle.count
            if hitCharacterLimit {
                tableTruncated = true
                tableReasons.append("dataset_character_limit")
            }
            for value in rawHeaders.prefix(maximumColumnsPerTable) where !hitCharacterLimit {
                let bounded = boundedText(value, limit: maximumCellCharacters)
                if bounded.count < value.count {
                    tableTruncated = true
                    tableReasons.append("header_text_limit")
                }
                guard tableCharacters + bounded.count <= available else {
                    tableTruncated = true
                    hitCharacterLimit = true
                    break
                }
                headers.append(bounded)
                tableCharacters += bounded.count
            }
            var rows: [[String]] = []
            for rawRow in rawRows.prefix(maximumRowsPerTable) where !hitCharacterLimit {
                var row: [String] = []
                var rowCharacters = 0
                for rawValue in rawRow.prefix(maximumColumnsPerTable) {
                    let bounded = boundedText(rawValue, limit: maximumCellCharacters)
                    if bounded.count < rawValue.count {
                        tableTruncated = true
                        tableReasons.append("cell_text_limit")
                    }
                    guard tableCharacters + rowCharacters + bounded.count <= available else {
                        tableTruncated = true
                        hitCharacterLimit = true
                        break
                    }
                    row.append(bounded)
                    rowCharacters += bounded.count
                }
                if rawRow.count > maximumColumnsPerTable {
                    tableTruncated = true
                    tableReasons.append("column_limit")
                }
                if hitCharacterLimit { break }
                if !row.isEmpty {
                    rows.append(row)
                    tableCharacters += rowCharacters
                }
            }

            if hitCharacterLimit {
                tableReasons.append("dataset_character_limit")
            }

            totalCharacters += tableCharacters
            let table = BrowserAgentDataset.HTMLTable(
                index: rawIndex,
                title: retainedTableTitle,
                layoutNote: layoutNote,
                headers: headers,
                rows: rows,
                sourceRowCount: max(int(raw["totalRows"]), rawRows.count),
                wasTruncated: tableTruncated
            )
            if tableTruncated && tableReasons.isEmpty { tableReasons.append("table_extraction_limit") }
            datasets.append(makeTableDataset(
                pageTitle: pageTitle,
                sourceURL: sourceURL,
                sourceTabID: sourceTabID,
                table: table,
                reasons: tableReasons
            ))
            reasons.append(contentsOf: tableReasons)
            if hitCharacterLimit {
                wasTruncated = true
                break
            }
        }

        return BrowserAgentExtractionResult(
            pageTitle: pageTitle,
            sourceURL: sourceURL,
            datasets: datasets,
            truncated: wasTruncated || datasets.contains(where: \.wasTruncated),
            truncationReasons: unique(reasons)
        )
    }

    static func safeSourceURL(_ url: URL) -> URL? {
        safeSourceURL(url.absoluteString)
    }

    static func safeSourceURL(_ rawValue: String) -> URL? {
        guard var components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else { return nil }
        components.user = nil
        components.password = nil
        components.fragment = nil
        if let items = components.queryItems {
            components.queryItems = items.map { item in
                if isSensitiveParameter(item.name) {
                    return URLQueryItem(name: item.name, value: "[redacted]")
                }
                return item
            }
        }
        return components.url
    }

    private static func makeTableDataset(
        pageTitle: String,
        sourceURL: String,
        sourceTabID: UUID,
        table: BrowserAgentDataset.HTMLTable,
        reasons: [String]
    ) -> BrowserAgentDataset {
        let truncated = table.wasTruncated || !reasons.isEmpty
        let tableLabel = table.title.isEmpty ? "Table \(table.index + 1)" : table.title
        return BrowserAgentDataset(
            id: UUID(),
            kind: .htmlTable,
            title: pageTitle.isEmpty ? tableLabel : "\(tableLabel) from \(pageTitle)",
            pageTitle: pageTitle,
            sourceURL: sourceURL,
            sourceTabID: sourceTabID,
            capturedAt: ISO8601DateFormatter().string(from: Date()),
            wasTruncated: truncated,
            truncationReasons: unique(reasons),
            links: [],
            tables: [table]
        )
    }

    private static func sourceURL(in object: [String: Any], fallback: URL?) -> String? {
        if let rawURL = object["url"] as? String,
           let safeURL = safeSourceURL(rawURL) {
            return safeURL.absoluteString
        }
        return fallback.flatMap { safeSourceURL($0) }?.absoluteString
    }

    private static func jsonObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static func int(_ value: Any?) -> Int {
        if let intValue = value as? Int { return intValue }
        if let number = value as? NSNumber { return number.intValue }
        return 0
    }

    private static func boundedText(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\u{0000}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(limit))
    }

    private static func unique(_ values: [String]) -> [String] {
        Array(NSOrderedSet(array: values).array.compactMap { $0 as? String })
    }

    private static func isSensitiveParameter(_ rawName: String) -> Bool {
        let name = rawName.lowercased().replacingOccurrences(of: "-", with: "_")
        let exact: Set<String> = [
            "access_token", "id_token", "token", "auth", "authorization", "code", "password",
            "passwd", "secret", "client_secret", "api_key", "apikey", "key", "credential",
            "credentials", "session", "sessionid", "signature", "sig", "jwt"
        ]
        return exact.contains(name)
            || name.hasSuffix("_token")
            || name.hasSuffix("_secret")
            || name.hasSuffix("_password")
            || name.hasSuffix("_credential")
    }
}
