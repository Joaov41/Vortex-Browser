//
//  BrowserAgentController+ResearchTabs.swift
//  Vortex
//
//  open_sources_in_group: puts the research preset's chosen sources into a normal-browsing tab group
//  as background tabs. Pages are opened, never read or interacted with, and no approval is needed.

import Foundation

extension BrowserAgentController {
    static let sourceGroupTitleLimit = 60
    static let sourceTabLimit = 8

    /// Validated arguments for open_sources_in_group. Parsing is pure so the bounds can be tested without a browser.
    struct SourceGroupRequest: Equatable {
        let groupTitle: String
        let urls: [URL]

        static func parse(_ arguments: [String: Any]) throws -> SourceGroupRequest {
            let title = (arguments["groupTitle"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty,
                  title.count <= sourceGroupTitleLimit,
                  title.rangeOfCharacter(from: .controlCharacters) == nil else {
                throw BrowserToolFailure.invalidArgument("Provide groupTitle as 1 to 60 characters on one line.")
            }
            guard let rawURLs = arguments["urls"] as? [Any],
                  (1...sourceTabLimit).contains(rawURLs.count) else {
                throw BrowserToolFailure.invalidArgument("Provide urls as a list of 1 to 8 HTTP or HTTPS addresses.")
            }
            var urls: [URL] = []
            for raw in rawURLs {
                guard let text = raw as? String,
                      let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                      AgentTaskURLParser.isAllowedStartURL(url) else {
                    throw BrowserToolFailure.invalidArgument(
                        "Every url must be an HTTP or HTTPS address without a username or password. No tabs were opened."
                    )
                }
                if !urls.contains(url) { urls.append(url) }
            }
            return SourceGroupRequest(groupTitle: title, urls: urls)
        }
    }

    func openSourcesInGroup(arguments: [String: Any], token: UUID) throws -> ToolResult {
        guard !runIsPrivate else {
            throw BrowserToolFailure.invalidArgument(
                "Opening sources in a tab group is unavailable in private browsing, because tab groups persist "
                    + "outside the private session. No tabs were opened."
            )
        }
        let request = try SourceGroupRequest.parse(arguments)
        guard let adapter = browserAdapter else { throw BrowserToolFailure.unavailable }
        guard isCurrentRun(token) else { throw CancellationError() }
        let group = try adapter.sourceGroup(title: request.groupTitle)
        var opened = 0
        for url in request.urls {
            guard isCurrentRun(token) else { throw CancellationError() }
            try adapter.openBackgroundTab(url: url, groupID: group.id)
            opened += 1
        }
        let noun = opened == 1 ? "tab" : "tabs"
        append(.action, "Open \(opened) source \(noun) in tab group \(group.title)")
        return .plain(
            "Opened \(opened) source \(noun) in the tab group \"\(group.title)\" in the background. "
                + "You are still working in your current tab. The pages have not been read; use fetch_page for their text."
        )
    }
}
