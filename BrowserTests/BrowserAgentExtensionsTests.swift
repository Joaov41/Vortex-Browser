import Foundation
import PDFKit
import WebKit
import XCTest
@testable import Browser

@MainActor
final class BrowserAgentExtensionsTests: XCTestCase {
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    @available(iOS 18.4, *)
    private final class FilePickerFixture: NSObject, WKUIDelegate {
        var openPanelCount = 0
        var selectedURLs: [URL]?

        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
        ) {
            openPanelCount += 1
            completionHandler(selectedURLs)
        }
    }

    func testNewRoutingExamplesStayNarrowAndGenericTranslationRemainsChat() {
        let actions = [
            "Put all travel pages into a Lisbon trip group",
            "Collect product names, prices, and links from these results",
            "Attach the document I choose to this form",
            "Bookmark this page",
            "Save these articles in a Research folder",
            "Translate this page into Portuguese",
            "Check page translation status"
        ]
        for text in actions {
            if case .agent = BrowserAgentRouter.route(text) { continue }
            XCTFail("Expected browser action routing for: \(text)")
        }

        XCTAssertEqual(BrowserAgentRouter.route("translate this to Portuguese"), .chat("translate this to Portuguese"))
        XCTAssertEqual(BrowserAgentRouter.route("summarize this page"), .chat("summarize this page"))
        XCTAssertEqual(BrowserAgentRouter.route("/do collect the prices"), .agent("collect the prices"))
    }

    func testToolSchemasHaveUniqueNamesAndRequireEveryDeclaredProperty() throws {
        let tools = BrowserAgentController.tools
        let names = try tools.map { tool -> String in
            try XCTUnwrap(tool["name"] as? String)
        }
        XCTAssertEqual(Set(names).count, names.count, "Tool names must remain unique.")
        XCTAssertTrue(BrowserAgentController.browserToolNames.isSubset(of: Set(names)))

        let phaseATools: Set<String> = [
            "go_forward", "reload", "press_key", "set_checked", "inspect", "dismiss_overlays",
            "close_tab", "search_history", "set_desktop_mode", "open_in_split", "hide_element",
            "copy_to_clipboard", "web_search"
        ]
        XCTAssertTrue(phaseATools.isSubset(of: Set(names)))
        XCTAssertFalse(BrowserAgentController.browserToolNames.contains("copy_to_clipboard"), "Clipboard copy is a core browser action, so it must remain available without the optional adapter.")

        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            let parameters = try XCTUnwrap(tool["parameters"] as? [String: Any], name)
            let properties = try XCTUnwrap(parameters["properties"] as? [String: Any], name)
            let required = try XCTUnwrap(parameters["required"] as? [String], name)
            XCTAssertEqual(Set(properties.keys), Set(required), "Every property in \(name) must be required or explicitly nullable.")
        }

        let comparison = try XCTUnwrap(tools.first { $0["name"] as? String == "compose_comparison" })
        let parameters = try XCTUnwrap(comparison["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        let rows = try XCTUnwrap(properties["rows"] as? [String: Any])
        let item = try XCTUnwrap(rows["items"] as? [String: Any])
        let rowProperties = try XCTUnwrap(item["properties"] as? [String: Any])
        let rowRequired = try XCTUnwrap(item["required"] as? [String])
        XCTAssertEqual(Set(rowProperties.keys), Set(rowRequired))
    }

    func testExtractionParserReportsClippingKeepsWholeRowsAndRedactsSourceCredentials() throws {
        let header = String(repeating: "列", count: 430)
        let rowValue = String(repeating: "價", count: 430)
        let rows = (0..<100).map { _ in Array(repeating: rowValue, count: 16) }
        let fixture: [String: Any] = [
            "title": String(repeating: "頁", count: 360),
            "url": "https://user:password@catalog.example/results?token=private&region=lisbon#section",
            "truncated": false,
            "tables": [[
                "index": 0,
                "title": String(repeating: "名", count: 270),
                "layoutNote": "This table uses colspan; source cell order is retained.",
                "headers": [header] + Array(repeating: "Price", count: 16),
                "rows": rows,
                "totalRows": rows.count,
                "totalColumns": 17,
                "truncated": false,
                "truncationReasons": []
            ]]
        ]
        let data = try JSONSerialization.data(withJSONObject: fixture)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let result = try XCTUnwrap(BrowserAgentExtractionParser.tables(
            from: json,
            sourceTabID: UUID(),
            fallbackURL: nil
        ))
        let dataset = try XCTUnwrap(result.datasets.first)
        let table = try XCTUnwrap(dataset.tables.first)

        XCTAssertTrue(result.truncated)
        XCTAssertTrue(dataset.truncationReasons.contains("page_title_limit"))
        XCTAssertTrue(dataset.truncationReasons.contains("table_title_limit"))
        XCTAssertTrue(dataset.truncationReasons.contains("header_text_limit"))
        XCTAssertTrue(dataset.truncationReasons.contains("cell_text_limit"))
        XCTAssertTrue(dataset.truncationReasons.contains("column_limit"))
        XCTAssertTrue(dataset.truncationReasons.contains("table_spans_unaligned"))
        XCTAssertFalse(dataset.sourceURL.contains("user"))
        XCTAssertFalse(dataset.sourceURL.contains("password"))
        XCTAssertFalse(dataset.sourceURL.contains("private"))
        XCTAssertTrue(dataset.sourceURL.contains("region=lisbon"))
        XCTAssertGreaterThan(table.rows.count, 0)
        XCTAssertLessThan(table.rows.count, table.sourceRowCount)
        XCTAssertTrue(table.rows.allSatisfy { $0.count == 16 }, "Rows must be retained whole rather than exported as partial records.")
    }

    func testExtractionScriptsReturnVisibleLinksAndRealTableCellsWithoutFormValues() async throws {
        let waiter = LoadWaiter()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        webView.navigationDelegate = waiter
        let html = """
        <html><head><title>Catalog results</title></head><body>
          <a href="/item?token=signed-secret&campaign=spring">Widget 42</a>
          <input type="text" value="INPUT_SECRET_SHOULD_NOT_EXPORT">
          <table><caption>Available products</caption><thead><tr><th>Name</th><th>Price</th></tr></thead>
            <tbody><tr><td>Widget 42</td><td>€24.50</td></tr></tbody></table>
          <div hidden><a href="/hidden">Hidden link text</a></div>
        </body></html>
        """
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://catalog.example/search?token=page-secret&sort=price"))
        }
        _ = try await webView.callAsyncJavaScript(
            BrowserAgentPageScript.snapshot,
            arguments: ["maxElements": 150, "maxText": 500],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        )
        let linkValue = try await webView.callAsyncJavaScript(BrowserAgentExtractionScript.links, arguments: [:], in: nil, contentWorld: BrowserAgentPageScript.world)
        let linkJSON = try XCTUnwrap(linkValue as? String)
        let linkObject = try XCTUnwrap(jsonObject(linkJSON))
        XCTAssertFalse(linkJSON.contains("signed-secret"))
        XCTAssertFalse(linkJSON.contains("page-secret"))
        XCTAssertFalse(linkJSON.contains("INPUT_SECRET_SHOULD_NOT_EXPORT"))
        XCTAssertFalse(linkJSON.contains("Hidden link text"))
        XCTAssertTrue(linkJSON.contains("campaign=spring"))

        let links = try XCTUnwrap(BrowserAgentExtractionParser.links(from: linkJSON, sourceTabID: UUID(), fallbackURL: webView.url))
        XCTAssertEqual(links.datasets.first?.links.first?.text, "Widget 42")
        XCTAssertTrue(links.sourceURL.contains("sort=price"))

        let tableValue = try await webView.callAsyncJavaScript(BrowserAgentExtractionScript.tables, arguments: [:], in: nil, contentWorld: BrowserAgentPageScript.world)
        let tableJSON = try XCTUnwrap(tableValue as? String)
        XCTAssertFalse(tableJSON.contains("INPUT_SECRET_SHOULD_NOT_EXPORT"))
        let tables = try XCTUnwrap(BrowserAgentExtractionParser.tables(from: tableJSON, sourceTabID: UUID(), fallbackURL: webView.url))
        let table = try XCTUnwrap(tables.datasets.first?.tables.first)
        XCTAssertEqual(table.headers, ["Name", "Price"])
        XCTAssertEqual(table.rows, [["Widget 42", "€24.50"]])
        XCTAssertEqual(table.title, "Available products")
        XCTAssertNotNil(linkObject["url"] as? String)
    }

    func testFindHighlightsAndExtendedPageControlsReportSyntheticLimits() async throws {
        let waiter = LoadWaiter()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        webView.navigationDelegate = waiter
        let html = """
        <html><body>
          <p>Visible phrase: BLUEBERRY.</p><div contenteditable="true">BLUEBERRY_PRIVATE</div>
          <input type="range" id="range" min="0" max="10" step="2" value="4">
          <input type="range" id="sensitive-range" name="account_number" min="0" max="10" value="2">
          <input type="password" id="password-field" autocomplete="current-password">
          <button id="disabled-button" disabled>Disabled</button>
          <div id="panel" style="height:100px;overflow:auto"><div style="height:500px">Scroll content</div></div>
          <div id="card" draggable="true">Movable card</div>
          <div id="drop" data-dropzone="true">Drop here</div>
        </body></html>
        """
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://controls.example/"))
        }
        _ = try await webView.callAsyncJavaScript(BrowserAgentPageScript.snapshot, arguments: ["maxElements": 150, "maxText": 500], in: nil, contentWorld: BrowserAgentPageScript.world)
        let findValue = try await webView.callAsyncJavaScript(BrowserAgentInteractionScript.find, arguments: ["query": "BLUEBERRY"], in: nil, contentWorld: BrowserAgentPageScript.world)
        let find = try XCTUnwrap((findValue as? String).flatMap(jsonObject))
        XCTAssertEqual(find["found"] as? Bool, true)
        XCTAssertEqual(find["count"] as? Int, 1, "Editable text should be excluded.")
        _ = try await webView.callAsyncJavaScript(BrowserAgentInteractionScript.clearHighlights, arguments: [:], in: nil, contentWorld: BrowserAgentPageScript.world)

        let controlsValue = try await webView.callAsyncJavaScript(BrowserAgentInteractionScript.extendedControls, arguments: [:], in: nil, contentWorld: BrowserAgentPageScript.world)
        let controls = try XCTUnwrap((controlsValue as? String).flatMap(jsonObject)?["controls"] as? [[String: Any]])
        func controlID(_ predicate: ([String: Any]) -> Bool) throws -> Int {
            try XCTUnwrap(controls.first(where: predicate)?["id"] as? Int)
        }
        let panelID = try controlID { $0["scrollable"] as? Bool == true }
        let cardID = try controlID { $0["draggable"] as? Bool == true }
        let dropID = try controlID { $0["dropTarget"] as? Bool == true }
        let scrollValue = try await webView.callAsyncJavaScript(
            BrowserAgentInteractionScript.scrollContainer,
            arguments: ["id": panelID, "pixels": 5000],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        )
        let scroll = try XCTUnwrap((scrollValue as? String).flatMap(jsonObject))
        XCTAssertEqual(scroll["ok"] as? Bool, true)
        XCTAssertLessThanOrEqual(scroll["scrollTop"] as? Int ?? 0, scroll["maxScroll"] as? Int ?? 0)

        let sliderIDValue = try await webView.callAsyncJavaScript(
            "return globalThis.__vxAgent.idFor(document.getElementById('range'));",
            arguments: [:],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        )
        let sliderID = try XCTUnwrap((sliderIDValue as? NSNumber)?.intValue)
        let sliderValue = try await webView.callAsyncJavaScript(BrowserAgentInteractionScript.setSlider, arguments: ["id": sliderID, "value": 9], in: nil, contentWorld: BrowserAgentPageScript.world)
        let slider = try XCTUnwrap((sliderValue as? String).flatMap(jsonObject))
        XCTAssertEqual(slider["value"] as? String, "10")

        let hoverValue = try await webView.callAsyncJavaScript(BrowserAgentInteractionScript.hover, arguments: ["id": cardID], in: nil, contentWorld: BrowserAgentPageScript.world)
        let hover = try XCTUnwrap((hoverValue as? String).flatMap(jsonObject))
        XCTAssertEqual(hover["synthetic"] as? Bool, true)
        let sensitiveIDValue = try await webView.callAsyncJavaScript(
            "return globalThis.__vxAgent.idFor(document.getElementById('sensitive-range'));",
            arguments: [:],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        )
        let sensitiveID = try XCTUnwrap((sensitiveIDValue as? NSNumber)?.intValue)
        let sensitiveSliderValue = try await webView.callAsyncJavaScript(
            BrowserAgentInteractionScript.setSlider,
            arguments: ["id": sensitiveID, "value": 8],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        )
        XCTAssertNotNil((sensitiveSliderValue as? String).flatMap(jsonObject)?["error"] as? String)
        let passwordIDValue = try await webView.callAsyncJavaScript(
            "return globalThis.__vxAgent.idFor(document.getElementById('password-field'));",
            arguments: [:],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        )
        let passwordID = try XCTUnwrap((passwordIDValue as? NSNumber)?.intValue)
        let sensitiveHoverValue = try await webView.callAsyncJavaScript(BrowserAgentInteractionScript.hover, arguments: ["id": passwordID], in: nil, contentWorld: BrowserAgentPageScript.world)
        XCTAssertNotNil((sensitiveHoverValue as? String).flatMap(jsonObject)?["error"] as? String)
        let disabledIDValue = try await webView.callAsyncJavaScript(
            "return globalThis.__vxAgent.idFor(document.getElementById('disabled-button'));",
            arguments: [:],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        )
        let disabledID = try XCTUnwrap((disabledIDValue as? NSNumber)?.intValue)
        let disabledHoverValue = try await webView.callAsyncJavaScript(BrowserAgentInteractionScript.hover, arguments: ["id": disabledID], in: nil, contentWorld: BrowserAgentPageScript.world)
        XCTAssertNotNil((disabledHoverValue as? String).flatMap(jsonObject)?["error"] as? String)
        let dragValue = try await webView.callAsyncJavaScript(
            BrowserAgentInteractionScript.dragDrop,
            arguments: ["sourceID": cardID, "targetID": dropID],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        )
        let drag = try XCTUnwrap((dragValue as? String).flatMap(jsonObject))
        XCTAssertNotNil(drag["dropEventNotCancelled"] as? Bool)
        XCTAssertNil(drag["dropAccepted"], "A non-cancelled DOM event does not establish that a site accepted the drop.")
    }

    func testCSVEscapesQuotesNewlinesAndFormulaPrefixesAndPadsRows() throws {
        let table = BrowserAgentDataset.HTMLTable(
            index: 0,
            title: "Research",
            layoutNote: "Column alignment is limited because the source uses spans.",
            headers: ["Name", "Price", "Notes"],
            rows: [
                ["Apple", "\t=SUM(1,1)", "Line\n\"quoted\", value"],
                ["Banana", "+2"]
            ],
            sourceRowCount: 2,
            wasTruncated: true
        )
        let dataset = BrowserAgentDataset(
            id: UUID(),
            kind: .htmlTable,
            title: "Research data",
            pageTitle: "Products",
            sourceURL: "https://catalog.example/results?region=lisbon",
            sourceTabID: UUID(),
            capturedAt: "2026-10-10T00:00:00Z",
            wasTruncated: true,
            truncationReasons: ["cell_text_limit", "row_limit"],
            links: [],
            tables: [table]
        )
        let csv = try XCTUnwrap(String(data: BrowserAgentExportService.csv(for: dataset), encoding: .utf8))
        let parsed = parseCSV(csv)

        XCTAssertFalse(parsed.isEmpty)
        XCTAssertEqual(Set(parsed.map(\.count)).count, 1, "Jagged source rows must be padded to a stable CSV width.")
        XCTAssertTrue(csv.contains("\"'\t=SUM(1,1)\""))
        XCTAssertTrue(csv.contains("\"'+2\""))
        XCTAssertTrue(csv.contains("\"Line\n\"\"quoted\"\", value\""))
        XCTAssertTrue(csv.contains("cell_text_limit; row_limit"))
        XCTAssertTrue(csv.contains("Column alignment is limited"))
        XCTAssertEqual(parsed.last?.last, "", "The short row should have an empty padded cell.")

        let attachment = XCTAttachment(data: Data(csv.utf8), uniformTypeIdentifier: "public.comma-separated-values-text")
        attachment.name = "browser-agent-safe-table.csv"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testFetchedPageDatasetExportsReadableTextAndComposesWithLiveData() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://fetched.example/research?access_token=private-token&region=porto#section"))
        let fetched = try XCTUnwrap(BrowserAgentDataset.fetchedPage(.init(
            title: "Fetched source",
            url: pageURL,
            text: "FETCHEDSOURCEFACT17\nA second bounded paragraph.",
            truncated: true
        )))
        XCTAssertEqual(fetched.kind, .fetchedPage)
        XCTAssertNil(fetched.sourceTabID, "A background-fetched page must not masquerade as a live tab.")
        XCTAssertTrue(fetched.sourceURL.contains("region=porto"))
        XCTAssertTrue(fetched.sourceURL.contains("access_token=%5Bredacted%5D"))
        XCTAssertFalse(fetched.sourceURL.contains("private-token"))
        XCTAssertEqual(fetched.fetchedText, "FETCHEDSOURCEFACT17\nA second bounded paragraph.")
        XCTAssertTrue(fetched.wasTruncated)

        let fetchedCSV = try XCTUnwrap(String(data: BrowserAgentExportService.csv(for: fetched), encoding: .utf8))
        XCTAssertTrue(fetchedCSV.contains("FETCHEDSOURCEFACT17"))
        XCTAssertTrue(fetchedCSV.contains("https://fetched.example/research"))
        XCTAssertFalse(fetchedCSV.contains("private-token"))
        let report = try BrowserAgentExportService.reportPDF(for: [fetched])
        let reportDocument = try XCTUnwrap(PDFDocument(data: report))
        let reportText = pdfText(reportDocument)
        retain(report, name: "browser-agent-fetched-page-report.pdf", uti: "com.adobe.pdf")
        let reportTextAttachment = XCTAttachment(string: reportText)
        reportTextAttachment.name = "browser-agent-fetched-page-report-extracted.txt"
        reportTextAttachment.lifetime = .keepAlways
        add(reportTextAttachment)
        XCTAssertTrue(
            compactPDFText(reportText).contains("FETCHEDSOURCEFACT17"),
            "PDFKit report extraction did not retain the fetched text sentinel. Extracted text: \(reportText.debugDescription)"
        )
        XCTAssertTrue(reportText.contains("fetched.example/research"))
        XCTAssertFalse(reportText.contains("private-token"))

        let liveDataset = makeTableDataset(
            title: "Live catalog table",
            pageTitle: "Catalog",
            sourceURL: "https://catalog.example/items?region=lisbon",
            rows: [["Widget", "€24.50", "In stock"]],
            wasTruncated: false,
            reasons: []
        )
        let legacySourceTabID = try XCTUnwrap(liveDataset.sourceTabID)
        let legacyEncoded = try JSONEncoder().encode(liveDataset)
        let legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyEncoded) as? [String: Any])
        XCTAssertEqual(
            legacyJSON["sourceTabID"] as? String,
            legacySourceTabID.uuidString,
            "The existing links/table dataset wire format must keep its nonnil source tab ID."
        )
        let oldDatasetRoundTrip = try JSONDecoder().decode(BrowserAgentDataset.self, from: legacyEncoded)
        XCTAssertEqual(oldDatasetRoundTrip, liveDataset, "Existing links/table dataset JSON must preserve its fields and semantics.")
        XCTAssertEqual(oldDatasetRoundTrip.sourceTabID, legacySourceTabID)

        let comparison = BrowserAgentExportService.Comparison(
            title: "Fetched and live evidence",
            summary: "A model-authored finding based on one fetched source and one live table.",
            sources: [fetched, liveDataset],
            rows: [.init(label: "Reported product detail", values: ["FETCHEDSOURCEFACT17", "€24.50"])]
        )
        let comparisonCSV = try XCTUnwrap(String(data: BrowserAgentExportService.csv(for: comparison), encoding: .utf8))
        XCTAssertTrue(comparisonCSV.contains("fetched.example/research"))
        XCTAssertTrue(comparisonCSV.contains("catalog.example/items"))
        XCTAssertTrue(comparisonCSV.contains("FETCHEDSOURCEFACT17"))
        let comparisonPDF = try BrowserAgentExportService.comparisonPDF(for: comparison)
        let comparisonDocument = try XCTUnwrap(PDFDocument(data: comparisonPDF))
        let comparisonText = pdfText(comparisonDocument)
        retain(comparisonPDF, name: "browser-agent-fetched-comparison.pdf", uti: "com.adobe.pdf")
        let comparisonTextAttachment = XCTAttachment(string: comparisonText)
        comparisonTextAttachment.name = "browser-agent-fetched-comparison-extracted.txt"
        comparisonTextAttachment.lifetime = .keepAlways
        add(comparisonTextAttachment)
        XCTAssertTrue(comparisonText.contains("fetched.example/research"))
        XCTAssertTrue(comparisonText.contains("catalog.example/items"))
        XCTAssertTrue(
            compactPDFText(comparisonText).contains("FETCHEDSOURCEFACT17"),
            "PDFKit comparison extraction did not retain the model-authored value. Extracted text: \(comparisonText.debugDescription)"
        )
    }

    func testReadableReportAndModelAuthoredComparisonPdfsAreValidAndMultiPage() throws {
        let sourceURL = "https://research.example/東京/prices?region=lisbon&reference=" + String(repeating: "資料", count: 35)
        let rows = (0..<180).map { index in
            ["品目 \(index)", "€\(index).50", "Long Unicode note 東京 café \(String(repeating: "詳細", count: 12))"]
        }
        let dataset = makeTableDataset(
            title: "Research results — 東京",
            pageTitle: "Product prices",
            sourceURL: sourceURL,
            rows: rows,
            wasTruncated: false,
            reasons: []
        )
        let report = try BrowserAgentExportService.reportPDF(for: [dataset])
        let reportDocument = try XCTUnwrap(PDFDocument(data: report))
        let reportText = pdfText(reportDocument)
        XCTAssertGreaterThan(reportDocument.pageCount, 1)
        XCTAssertTrue(reportText.contains("research.example/東京"))
        XCTAssertTrue(reportText.contains("品目 179"))
        XCTAssertTrue(reportText.contains("€179.50"))
        retain(report, name: "browser-agent-multipage-report.pdf", uti: "com.adobe.pdf")

        let secondDataset = makeTableDataset(
            title: "Second source",
            pageTitle: "A second catalog",
            sourceURL: "https://second.example/catalog?region=porto",
            rows: [["Product", "€99"]],
            wasTruncated: false,
            reasons: []
        )
        let comparison = BrowserAgentExportService.Comparison(
            title: "Model comparison — summer pricing",
            summary: "These values were composed by the model from the captured browser datasets.",
            sources: [dataset, secondDataset],
            rows: [
                .init(label: "Price for widget", values: ["€179.50", "€99"]),
                .init(label: "Availability notes", values: ["In stock 東京", "Check local inventory"])
            ]
        )
        let comparisonPDF = try BrowserAgentExportService.comparisonPDF(for: comparison)
        let comparisonDocument = try XCTUnwrap(PDFDocument(data: comparisonPDF))
        let comparisonText = pdfText(comparisonDocument)
        XCTAssertTrue(comparisonText.contains("Model-Authored Comparison Report"))
        XCTAssertTrue(comparisonText.contains("research.example/東京"))
        XCTAssertTrue(comparisonText.contains("second.example/catalog"))
        XCTAssertTrue(comparisonText.contains("€179.50"))
        retain(comparisonPDF, name: "browser-agent-comparison.pdf", uti: "com.adobe.pdf")
    }

    func testPagePDFIncludesContentBelowTheFoldAndSourceCover() async throws {
        let waiter = LoadWaiter()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        webView.navigationDelegate = waiter
        let html = """
        <html><head><title>Full page export check</title><style>body{margin:0} .spacer{height:3200px}</style></head>
        <body><h1>Top of article</h1><div class="spacer"></div><p>BELOW_FOLD_EXPORT_MARKER_東京</p></body></html>
        """
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "https://page.example/research?token=private-secret&region=tokyo"))
        }

        let data = try await BrowserAgentExportService.pagePDF(from: webView)
        let document = try XCTUnwrap(PDFDocument(data: data))
        let text = pdfText(document)
        XCTAssertTrue(text.contains("Full page export check"))
        XCTAssertTrue(text.contains("https://page.example/research?token=%5Bredacted%5D&region=tokyo"))
        XCTAssertFalse(text.contains("private-secret"))
        XCTAssertTrue(text.contains("BELOW_FOLD_EXPORT_MARKER_東京"))
        retain(data, name: "browser-agent-full-page-below-fold.pdf", uti: "com.adobe.pdf")
    }

    func testAdapterFiltersRunPrivacyModeAndProviderTabsAndRejectsStaleTabs() throws {
        let suite = "BrowserAgentExtensions.privacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let viewModel = BrowserViewModel(userDefaults: defaults, thumbnailDirectory: scratch)
        let normal = BrowserTab(title: "Normal", url: URL(string: "https://normal.example/page?token=private&sort=price")!)
        let restored = BrowserTab(title: "Restored", url: URL(string: "https://restored.example/article")!)
        let privateTab = BrowserTab(title: "Private", url: URL(string: "https://private.example/page"), isIncognito: true)
        let providerTab = BrowserTab(title: "Provider", url: WebAIProvider.chatgpt.url)
        providerTab.webAIProvider = .chatgpt
        viewModel.tabs = [normal, restored, privateTab, providerTab]
        viewModel.selectedTabID = normal.id
        let normalWebView = normal.activateWebView()
        let downloadManager = BrowserDownloadManager(temporaryDirectory: scratch)
        var selectedTab: UUID?
        let adapter = BrowserAgentBrowserAdapter(
            viewModel: viewModel,
            downloadManager: downloadManager,
            onTabSelected: { selectedTab = $0 }
        )

        XCTAssertTrue(adapter.beginRun(in: normalWebView))
        let visibleTabs = try adapter.availableTabs()
        XCTAssertEqual(visibleTabs.map(\.id), [normal.id, restored.id])
        XCTAssertFalse(try XCTUnwrap(visibleTabs.first).url?.contains("private") == true)
        XCTAssertTrue(try XCTUnwrap(visibleTabs.first).url?.contains("sort=price") == true)
        XCTAssertThrowsError(try adapter.switchToTab(id: privateTab.id.uuidString))
        XCTAssertThrowsError(try adapter.switchToTab(id: providerTab.id.uuidString))

        let group = try adapter.createGroup(title: "Research")
        try adapter.moveTab(id: restored.id.uuidString, toGroupID: group.id.uuidString)
        XCTAssertEqual(try adapter.groups().first(where: { $0.id == group.id })?.tabCount, 1)
        try adapter.renameGroup(id: group.id, title: "Travel research")
        XCTAssertEqual(try adapter.groups().first(where: { $0.id == group.id })?.title, "Travel research")

        let firstFolder = try adapter.createBookmarkFolder(title: "Research", parentID: nil)
        let nestedFolder = try adapter.createBookmarkFolder(title: "Travel", parentID: firstFolder.id)
        let favoriteID = try XCTUnwrap(adapter.addBookmark(forTabID: normal.id.uuidString, folderID: firstFolder.id))
        XCTAssertEqual(try adapter.bookmarks().first(where: { $0.id == favoriteID })?.folderID, firstFolder.id)
        try adapter.moveBookmark(id: favoriteID, toFolderID: nestedFolder.id)
        XCTAssertEqual(try adapter.bookmarks().first(where: { $0.id == favoriteID })?.folderID, nestedFolder.id)
        XCTAssertTrue(try adapter.bookmarkFolders().contains(where: { $0.id == nestedFolder.id && $0.parentID == firstFolder.id }))
        XCTAssertThrowsError(try adapter.moveTab(id: privateTab.id.uuidString, toGroupID: group.id.uuidString))

        func queueTestFile(_ name: String, isIncognito: Bool) throws {
            let file = downloadManager.sessionDirectoryURL.appendingPathComponent(name)
            try Data("test".utf8).write(to: file)
            XCTAssertNotNil(downloadManager.enqueueCompletedFile(
                at: file,
                suggestedFilename: name,
                sourceURL: URL(string: "https://download.example/file?token=private&region=lisbon"),
                isIncognito: isIncognito
            ))
        }
        try queueTestFile("normal.csv", isIncognito: false)
        try queueTestFile("private.csv", isIncognito: true)
        XCTAssertEqual(try adapter.downloadItems().map(\.filename), ["normal.csv"])
        let sourceURL = try XCTUnwrap(adapter.downloadItems().first?.sourceURL)
        XCTAssertFalse(sourceURL.contains("private"), "Sensitive values should be redacted while the parameter name remains useful.")
        XCTAssertTrue(sourceURL.contains("region=lisbon"))

        let switched = try adapter.switchToTab(id: restored.id.uuidString)
        XCTAssertEqual(switched.tabID, restored.id)
        XCTAssertTrue(switched.needsRestoreWait)
        XCTAssertEqual(switched.expectedURL, restored.currentURL)
        XCTAssertEqual(selectedTab, restored.id)
        XCTAssertEqual(viewModel.selectedTabID, restored.id)

        let restoredWebView = switched.webView
        viewModel.tabs.removeAll { $0.id == restored.id }
        XCTAssertThrowsError(try adapter.validate(webView: restoredWebView))
        XCTAssertThrowsError(try adapter.validateSource(tabID: restored.id))

        XCTAssertTrue(adapter.beginRun(in: privateTab.activateWebView()))
        XCTAssertEqual(try adapter.availableTabs().map(\.id), [privateTab.id])
        XCTAssertThrowsError(try adapter.groups())
        XCTAssertThrowsError(try adapter.bookmarks())
    }

    func testA1AdapterActionsStayInRunScopeAndProduceBrowserEffects() throws {
        let suite = "BrowserAgentExtensions.a1.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let viewModel = BrowserViewModel(userDefaults: defaults, thumbnailDirectory: scratch.appendingPathComponent("thumbs", isDirectory: true))
        let history = HistoryStore(directory: scratch.appendingPathComponent("history", isDirectory: true))
        let source = BrowserTab(title: "Source", url: URL(string: "https://source.example/article")!)
        let neighbor = BrowserTab(title: "Normal neighbor", url: URL(string: "https://neighbor.example/page")!)
        let privateTab = BrowserTab(title: "Private neighbor", url: URL(string: "https://private.example/"), isIncognito: true)
        let providerTab = BrowserTab(title: "Provider", url: WebAIProvider.chatgpt.url)
        providerTab.webAIProvider = .chatgpt
        viewModel.tabs = [source, providerTab, privateTab, neighbor]
        viewModel.selectedTabID = source.id
        let sourceWebView = source.activateWebView()
        history.record(
            url: URL(string: "https://catalog.example/search?token=secret-value&region=lisbon")!,
            title: "Lisbon catalog"
        )
        var selectedTabID: UUID?
        var splitCallback: (primary: UUID, secondary: UUID, horizontal: Bool)?
        let adapter = BrowserAgentBrowserAdapter(
            viewModel: viewModel,
            downloadManager: BrowserDownloadManager(temporaryDirectory: scratch),
            onTabSelected: { selectedTabID = $0 },
            historyStore: history,
            onSplitPairOpened: { primary, secondary, horizontal in
                splitCallback = (primary, secondary, horizontal)
            }
        )

        XCTAssertTrue(adapter.beginRun(in: sourceWebView))
        let historyMatches = try adapter.historyMatches(query: "catalog")
        XCTAssertEqual(historyMatches.count, 1)
        XCTAssertFalse(historyMatches[0].url.contains("secret-value"))
        XCTAssertTrue(historyMatches[0].url.contains("region=lisbon"))

        let closed = try adapter.closeTab(id: source.id)
        XCTAssertEqual(closed.tabID, neighbor.id, "Closing a normal tab next to a provider/private tab must select a remaining normal tab.")
        XCTAssertEqual(viewModel.selectedTabID, neighbor.id)
        XCTAssertEqual(selectedTabID, neighbor.id)
        XCTAssertFalse(closed.webView === providerTab.liveWebView)
        XCTAssertFalse(closed.webView === privateTab.liveWebView)
        XCTAssertThrowsError(try adapter.validate(webView: sourceWebView))

        viewModel.defaultSearchEngine = .duckDuckGo
        let searchURL = try adapter.searchURL(query: "Lisbon coffee")
        XCTAssertEqual(searchURL.host, "duckduckgo.com")
        XCTAssertEqual(URLComponents(url: searchURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "q" })?.value, "Lisbon coffee")

        let desktop = try adapter.setDesktopMode(tabID: neighbor.id, enabled: true)
        XCTAssertEqual(desktop.tabID, neighbor.id)
        XCTAssertEqual(neighbor.liveWebView?.configuration.defaultWebpagePreferences.preferredContentMode, .desktop)
        XCTAssertEqual(selectedTabID, neighbor.id)

        let split = try adapter.openSplit(url: URL(string: "https://split.example/compare")!, besideTabID: neighbor.id)
        XCTAssertEqual(split.tabID, neighbor.id, "openSplit returns the agent's original working tab.")
        XCTAssertTrue(split.webView === neighbor.liveWebView)
        XCTAssertEqual(viewModel.splitPair(containing: neighbor.id)?.partner(of: neighbor.id), split.secondaryTabID)
        XCTAssertEqual(splitCallback?.primary, neighbor.id)
        XCTAssertEqual(splitCallback?.secondary, split.secondaryTabID)
        XCTAssertEqual(splitCallback?.horizontal, false)
        XCTAssertEqual(
            viewModel.selectedTabID,
            neighbor.id,
            "The browser keeps the agent's original tab selected so both split panes stay visible."
        )
        XCTAssertEqual(selectedTabID, neighbor.id)
        XCTAssertFalse(try XCTUnwrap(viewModel.tabs.first(where: { $0.id == split.secondaryTabID })).isIncognito)

        let closedSplit = try adapter.closeTab(id: split.secondaryTabID)
        XCTAssertEqual(closedSplit.tabID, neighbor.id)
        XCTAssertThrowsError(try adapter.closeTab(id: neighbor.id), "The last normal tab in this run's scope cannot be closed.")

        let privateWebView = privateTab.activateWebView()
        XCTAssertTrue(adapter.beginRun(in: privateWebView))
        XCTAssertThrowsError(try adapter.historyMatches(query: "catalog"))
        XCTAssertThrowsError(try adapter.closeTab(id: privateTab.id), "A private run cannot close its last private tab.")
    }

    func testA1DistractionHidingPersistsOnlyUniquePrivateSiteSelectors() async throws {
        let host = "agent-hide-\(UUID().uuidString.lowercased()).example"
        let url = try XCTUnwrap(URL(string: "https://\(host)/article"))
        let waiter = LoadWaiter()
        let first = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        first.navigationDelegate = waiter
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            first.loadHTMLString("<html><body><div id='target'>Hide me</div></body></html>", baseURL: url)
        }

        let didHide = await DistractionHider.hide(selector: "#target", in: first, isIncognito: true)
        let didRejectMissingSelector = await DistractionHider.hide(selector: "#missing", in: first, isIncognito: true)
        XCTAssertTrue(didHide)
        XCTAssertFalse(didRejectMissingSelector)
        XCTAssertEqual(DistractionHider.selectors(for: url, isIncognito: true), ["#target"])
        XCTAssertFalse(DistractionHider.selectors(for: url, isIncognito: false).contains("#target"))

        let second = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        second.navigationDelegate = waiter
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            second.loadHTMLString("<html><body><div id='target'>Hide me</div></body></html>", baseURL: url)
        }
        DistractionHider.apply(to: second, isIncognito: true)
        let display = try await second.callAsyncJavaScript(
            "return getComputedStyle(document.getElementById('target')).display;",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        ) as? String
        XCTAssertEqual(display, "none")
        DistractionHider.showHiddenItems(in: second, isIncognito: true)
    }

    func testTranslationTargetKeepsManualPreferenceAndAcceptsExplicitLanguage() {
        XCTAssertEqual(PageTranslator.resolvedTargetLanguage(nil), PageTranslator.targetLanguage)
        let portuguese = Locale.Language(identifier: "pt-BR")
        XCTAssertEqual(PageTranslator.resolvedTargetLanguage(portuguese), portuguese)
    }

    func testNativeUploadPickerPathTracksCancellationInsteadOfPreselectedFiles() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Native website file picker is available from iOS 18.4.") }
        let waiter = LoadWaiter()
        let picker = FilePickerFixture()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        webView.navigationDelegate = waiter
        webView.uiDelegate = picker
        let activeScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        let scene = activeScenes.first
        XCTAssertNotNil(scene, "The native picker test requires the XCTest app's existing UIWindowScene.")
        guard let scene else { return }
        let previousKeyWindow = activeScenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let hostWindow = UIWindow(windowScene: scene)
        let hostController = UIViewController()
        hostController.view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        webView.frame = hostController.view.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostController.view.addSubview(webView)
        hostWindow.rootViewController = hostController
        hostWindow.makeKeyAndVisible()
        defer {
            hostWindow.isHidden = true
            previousKeyWindow?.makeKeyAndVisible()
        }
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(
                "<html><body><label for='upload'>Choose file</label>"
                    + "<input id='upload' aria-label='Upload' type='file'></body></html>",
                baseURL: URL(string: "https://upload.example/form")
            )
        }

        let snapshotValue = try await webView.callAsyncJavaScript(
            BrowserAgentPageScript.snapshot,
            arguments: ["maxElements": 150, "maxText": 500],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        )
        _ = snapshotValue
        let inputIDValue = try await webView.callAsyncJavaScript(
            "return globalThis.__vxAgent.idFor(document.getElementById('upload'));",
            arguments: [:],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        )
        let inputID = try XCTUnwrap((inputIDValue as? NSNumber)?.intValue)
        _ = try await webView.callAsyncJavaScript(
            "const input = document.getElementById('upload'); const transfer = new DataTransfer(); "
                + "transfer.items.add(new File(['already selected'], 'existing.pdf', {type:'application/pdf'})); "
                + "input.files = transfer.files; return input.files.length;",
            arguments: [:],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        )
        let request = try await webView.callAsyncJavaScript(
            BrowserAgentInteractionScript.uploadPicker,
            arguments: ["id": inputID],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        )
        XCTAssertEqual((request as? String).flatMap(jsonObject)?["pickerRequested"] as? Bool, true)

        let deadline = Date().addingTimeInterval(5)
        while picker.openPanelCount < 1 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThanOrEqual(picker.openPanelCount, 1, "input.click() should reach WKUIDelegate's native open-panel path.")

        // A nil native completion represents cancel; dispatch the documented DOM cancel event
        // if this WebKit test host does not synthesize it automatically.
        _ = try await webView.callAsyncJavaScript(
            "const input = document.getElementById('upload'); input.dispatchEvent(new Event('cancel')); return true;",
            arguments: [:],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        )
        let statusValue = try await webView.callAsyncJavaScript(
            BrowserAgentInteractionScript.uploadStatus,
            arguments: ["id": inputID],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        )
        let status = try XCTUnwrap((statusValue as? String).flatMap(jsonObject))
        XCTAssertEqual(status["status"] as? String, "cancelled")
        XCTAssertEqual(status["count"] as? Int, 0, "A file from before this picker request must not count as a new selection.")

        let selectedFile = FileManager.default.temporaryDirectory.appendingPathComponent("browser-agent-upload-fixture.pdf")
        try Data("synthetic file selection".utf8).write(to: selectedFile, options: .atomic)
        defer { try? FileManager.default.removeItem(at: selectedFile) }
        picker.selectedURLs = [selectedFile]
        _ = try await webView.callAsyncJavaScript(
            BrowserAgentInteractionScript.uploadPicker,
            arguments: ["id": inputID],
            in: nil,
            contentWorld: BrowserAgentPageScript.world
        )
        let secondDeadline = Date().addingTimeInterval(5)
        while picker.openPanelCount < 2 && Date() < secondDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThanOrEqual(picker.openPanelCount, 2, "The second picker request should also use WKUIDelegate.")
        var selectedStatus: [String: Any] = [:]
        let selectionDeadline = Date().addingTimeInterval(3)
        repeat {
            let value = try await webView.callAsyncJavaScript(
                BrowserAgentInteractionScript.uploadStatus,
                arguments: ["id": inputID],
                in: nil,
                contentWorld: BrowserAgentPageScript.world
            )
            selectedStatus = (value as? String).flatMap(jsonObject) ?? [:]
            if selectedStatus["status"] as? String == "selected" { break }
            try await Task.sleep(for: .milliseconds(50))
        } while Date() < selectionDeadline
        XCTAssertEqual(selectedStatus["status"] as? String, "selected")
        XCTAssertEqual((selectedStatus["files"] as? [[String: Any]])?.first?["name"] as? String, selectedFile.lastPathComponent)
    }

    private func makeTableDataset(
        title: String,
        pageTitle: String,
        sourceURL: String,
        rows: [[String]],
        wasTruncated: Bool,
        reasons: [String]
    ) -> BrowserAgentDataset {
        let table = BrowserAgentDataset.HTMLTable(
            index: 0,
            title: title,
            layoutNote: nil,
            headers: ["Product", "Price", "Notes"],
            rows: rows,
            sourceRowCount: rows.count,
            wasTruncated: wasTruncated
        )
        return BrowserAgentDataset(
            id: UUID(),
            kind: .htmlTable,
            title: title,
            pageTitle: pageTitle,
            sourceURL: sourceURL,
            sourceTabID: UUID(),
            capturedAt: "2026-10-10T00:00:00Z",
            wasTruncated: wasTruncated,
            truncationReasons: reasons,
            links: [],
            tables: [table]
        )
    }

    private func retain(_ data: Data, name: String, uti: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: uti)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func pdfText(_ document: PDFDocument) -> String {
        (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }

    private func compactPDFText(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    private func jsonObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func parseCSV(_ csv: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        let characters = Array(csv.utf8)
        let quote: UInt8 = 34
        let comma: UInt8 = 44
        let carriageReturn: UInt8 = 13
        let lineFeed: UInt8 = 10
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == quote {
                    if index + 1 < characters.count, characters[index + 1] == quote {
                        field.append(quote)
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == quote {
                inQuotes = true
            } else if character == comma {
                row.append(String(decoding: field, as: UTF8.self))
                field = []
            } else if character == carriageReturn || character == lineFeed {
                if character == carriageReturn, index + 1 < characters.count, characters[index + 1] == lineFeed { index += 1 }
                row.append(String(decoding: field, as: UTF8.self))
                field = []
                rows.append(row)
                row = []
            } else {
                field.append(character)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(String(decoding: field, as: UTF8.self))
            rows.append(row)
        }
        return rows
    }
}
