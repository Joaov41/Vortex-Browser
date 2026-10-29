import XCTest
@testable import Browser

/// Locks the agent tool catalog. The literal lists below were copied from
/// BrowserAgentController+ToolCatalog.swift during the Phase 1 file split, so a
/// later phase cannot change a tool name or bundle membership by accident.
@MainActor
final class AgentControllerSplitTests: XCTestCase {
    private let expectedBrowserToolNames: Set<String> = [
        "list_tabs", "switch_tab", "list_tab_groups",
        "create_tab_group", "rename_tab_group", "move_tab_to_group",
        "list_bookmarks", "create_bookmark_folder", "add_bookmark",
        "move_bookmark_to_folder", "remove_bookmark", "extract_links",
        "extract_html_tables", "export_dataset_csv", "export_dataset_pdf",
        "export_page_pdf", "compose_comparison", "export_comparison_csv",
        "export_comparison_pdf", "list_downloads", "download_url",
        "download_link", "cancel_download", "set_reader_mode",
        "translate_page", "page_translation_status", "show_original_page",
        "find_page_text", "clear_page_highlights", "request_file_upload",
        "file_upload_status", "hover_element", "set_slider_value",
        "scroll_element_into_view", "list_extended_page_controls", "scroll_container",
        "synthetic_drag_drop", "close_tab", "search_history",
        "set_desktop_mode", "open_in_split", "hide_element",
        "web_search", "fill_form"
    ]

    private let expectedCoreToolNames: Set<String> = [
        "click", "type_text", "select_option",
        "scroll", "navigate", "open_tab",
        "go_back", "read_page", "wait",
        "go_forward", "reload", "press_key",
        "set_checked", "inspect", "dismiss_overlays",
        "copy_to_clipboard", "ask_user", "finish"
    ]

    private let expectedDataToolNames: Set<String> = [
        "extract_links", "extract_html_tables", "export_dataset_csv",
        "export_dataset_pdf", "export_page_pdf", "compose_comparison",
        "export_comparison_csv", "export_comparison_pdf"
    ]

    private let expectedResearchToolNames: Set<String> = [
        "fetch_page", "open_sources_in_group"
    ]

    private let expectedHandoffToolNames: Set<String> = [
        "prepare_calendar_event", "prepare_reminder", "prepare_email"
    ]

    private let expectedBrowserBundleToolNames: Set<String> = [
        "list_tabs", "switch_tab", "list_tab_groups",
        "create_tab_group", "rename_tab_group", "move_tab_to_group",
        "list_bookmarks", "create_bookmark_folder", "add_bookmark",
        "move_bookmark_to_folder", "remove_bookmark", "list_downloads",
        "download_url", "download_link", "cancel_download",
        "set_reader_mode", "translate_page", "page_translation_status",
        "show_original_page", "find_page_text", "clear_page_highlights",
        "request_file_upload", "file_upload_status", "hover_element",
        "set_slider_value", "scroll_element_into_view", "list_extended_page_controls",
        "scroll_container", "synthetic_drag_drop", "close_tab",
        "search_history", "set_desktop_mode", "open_in_split",
        "hide_element", "web_search", "fill_form"
    ]

    private let expectedCatalogNames: Set<String> = [
        "list_tabs", "switch_tab", "list_tab_groups",
        "create_tab_group", "rename_tab_group", "move_tab_to_group",
        "list_bookmarks", "create_bookmark_folder", "add_bookmark",
        "move_bookmark_to_folder", "remove_bookmark", "extract_links",
        "extract_html_tables", "export_dataset_csv", "export_dataset_pdf",
        "export_page_pdf", "compose_comparison", "export_comparison_csv",
        "export_comparison_pdf", "list_downloads", "download_url",
        "download_link", "cancel_download", "set_reader_mode",
        "translate_page", "page_translation_status", "show_original_page",
        "find_page_text", "clear_page_highlights", "request_file_upload",
        "file_upload_status", "hover_element", "set_slider_value",
        "scroll_element_into_view", "list_extended_page_controls", "scroll_container",
        "synthetic_drag_drop", "close_tab", "search_history",
        "set_desktop_mode", "open_in_split", "hide_element",
        "web_search", "fill_form", "click",
        "type_text", "select_option", "scroll",
        "navigate", "open_tab", "go_back",
        "read_page", "wait", "go_forward",
        "reload", "press_key", "set_checked",
        "inspect", "dismiss_overlays", "copy_to_clipboard",
        "ask_user", "finish", "fetch_page", "open_sources_in_group",
        "prepare_calendar_event", "prepare_reminder", "prepare_email"
    ]

    private let expectedToolDefinitionNames: [String] = [
        "click", "type_text", "select_option",
        "scroll", "navigate", "open_tab",
        "go_back", "read_page", "wait",
        "list_tabs", "switch_tab", "list_tab_groups",
        "create_tab_group", "rename_tab_group", "move_tab_to_group",
        "list_bookmarks", "create_bookmark_folder", "add_bookmark",
        "move_bookmark_to_folder", "remove_bookmark", "extract_links",
        "extract_html_tables", "export_dataset_csv", "export_dataset_pdf",
        "export_page_pdf", "compose_comparison", "export_comparison_csv",
        "export_comparison_pdf", "list_downloads", "download_url",
        "download_link", "cancel_download", "set_reader_mode",
        "translate_page", "page_translation_status", "show_original_page",
        "find_page_text", "clear_page_highlights", "request_file_upload",
        "file_upload_status", "hover_element", "set_slider_value",
        "scroll_element_into_view", "list_extended_page_controls", "scroll_container",
        "synthetic_drag_drop", "go_forward", "reload",
        "press_key", "set_checked", "inspect",
        "dismiss_overlays", "close_tab", "search_history",
        "set_desktop_mode", "open_in_split", "hide_element",
        "copy_to_clipboard", "web_search", "fill_form",
        "ask_user", "fetch_page", "open_sources_in_group",
        "prepare_calendar_event", "prepare_reminder", "prepare_email", "screenshot",
        "finish"
    ]

    func testCurrentDateLineStatesTodayInPlainWords() {
        let utc = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_792_065_600) // 2026-10-15 12:00 UTC
        XCTAssertEqual(
            BrowserAgentController.currentDateLine(now: now, timeZone: utc),
            "Today's date is Thursday, 15 October 2026. Sources dated on or before today are current, not future-dated.\n"
        )
    }

    func testBrowserToolNamesMatchLiteralCatalog() {
        XCTAssertEqual(BrowserAgentController.browserToolNames, expectedBrowserToolNames)
    }

    func testCoreToolNamesMatchLiteralCatalog() {
        XCTAssertEqual(BrowserAgentController.coreToolNames, expectedCoreToolNames)
    }

    func testDataToolNamesMatchLiteralCatalog() {
        XCTAssertEqual(BrowserAgentController.dataToolNames, expectedDataToolNames)
    }

    func testResearchToolNamesMatchLiteralCatalog() {
        XCTAssertEqual(BrowserAgentController.researchToolNames, expectedResearchToolNames)
    }

    func testBrowserBundleExcludesDataAndResearchTools() {
        XCTAssertEqual(BrowserAgentController.browserBundleToolNames, expectedBrowserBundleToolNames)
    }

    func testHandoffToolNamesMatchLiteralCatalog() {
        XCTAssertEqual(BrowserAgentController.handoffToolNames, expectedHandoffToolNames)
    }

    func testEveryNameInEverySetIsInTheLiteralCatalog() {
        let names = BrowserAgentController.browserToolNames
            .union(BrowserAgentController.coreToolNames)
            .union(BrowserAgentController.dataToolNames)
            .union(BrowserAgentController.researchToolNames)
            .union(BrowserAgentController.handoffToolNames)
        XCTAssertEqual(names, expectedCatalogNames)
        XCTAssertEqual(names.count, 67)
    }

    func testToolDefinitionNamesMatchLiteralList() {
        let definitionNames = BrowserAgentController.tools.compactMap { $0["name"] as? String }
        XCTAssertEqual(definitionNames, expectedToolDefinitionNames)
        XCTAssertEqual(Set(definitionNames).count, definitionNames.count, "tool names must be unique")
        XCTAssertEqual(Set(definitionNames), expectedCatalogNames.union(["screenshot"]))
    }
}
