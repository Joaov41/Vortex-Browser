import Foundation
import UIKit
import UniformTypeIdentifiers
import WebKit

@MainActor
extension BrowserIntentExecutor {
    func executeTabCommand(
        _ command: BrowserIntentCommand,
        confirm: BrowserIntentConfirmation
    ) async throws -> BrowserIntentOutput {
        switch command {
        case .newTab:
            viewModel.addTabBlank()
            var result = output("Opened a new tab.")
            result.resultTabID = viewModel.selectedTabID
            return result
        case .newPrivateTab:
            let tab = BrowserTab(title: "New Tab", url: nil, isIncognito: true)
            viewModel.tabs.append(tab)
            viewModel.selectTab(tab)
            return output("Opened a private tab.")
        case .reopenClosedTab:
            return try reopenClosedTab()
        case .closeCurrentTab:
            return try await closeCurrentTab(confirm: confirm)
        case .closeGroup(let groupID):
            return try await closeGroup(groupID, confirm: confirm)
        case .switchGroup(let groupID):
            return try switchGroup(groupID)
        case .switchToTab(let tabID):
            return try switchToTab(tabID)
        case .moveToGroup(let groupID):
            return try moveToGroup(groupID)
        case .openSplit(let first, let second):
            return try openSplit(first: first, second: second)
        case .endSplit:
            return try endSplit()
        default:
            throw BrowserIntentError.unsupported("Unsupported command.")
        }
    }

    func reopenClosedTab() throws -> BrowserIntentOutput {
        guard let record = viewModel.recentlyClosedTabs.first else {
            throw BrowserIntentError.emptyResult("There is no recently closed tab.")
        }
        guard AgentTaskURLParser.isAllowedStartURL(record.url) else {
            throw BrowserIntentError.invalidInput("The recently closed page cannot be reopened by this action.")
        }
        viewModel.reopenRecentlyClosed(record)
        return output("Reopened the last closed tab.")
    }

    struct CloseBinding {
        let tab: BrowserTab
        let webView: WKWebView?
        let url: URL?
        let wasLoading: Bool
        var nonce: String?
    }

    func closeBinding(for tab: BrowserTab) async throws -> CloseBinding {
        var binding = CloseBinding(
            tab: tab,
            webView: tab.liveWebView,
            url: tab.currentURL,
            wasLoading: tab.liveWebView?.isLoading ?? false,
            nonce: nil
        )
        guard !binding.wasLoading else { throw BrowserIntentError.pageStillLoading }
        if let webView = binding.webView,
           let url = binding.url,
           AgentTaskURLParser.isAllowedStartURL(url) {
            binding.nonce = try await documentNonce(of: webView)
        }
        try validateCloseBindingState(binding)
        return binding
    }

    func validateCloseBindingState(_ binding: CloseBinding) throws {
        try Task.checkCancellation()
        guard isCurrent(),
              viewModel.tabs.first(where: { $0.id == binding.tab.id }) === binding.tab,
              !binding.tab.isIncognito,
              binding.tab.webAIProvider == nil,
              binding.tab.liveWebView === binding.webView,
              binding.tab.currentURL == binding.url,
              (binding.webView?.isLoading ?? false) == binding.wasLoading else {
            throw BrowserIntentError.stalePage
        }
    }

    func validateCloseBinding(_ binding: CloseBinding) async throws {
        try validateCloseBindingState(binding)
        if let expected = binding.nonce, let webView = binding.webView {
            let current = try await documentNonce(of: webView)
            guard current == expected else { throw BrowserIntentError.stalePage }
            try validateCloseBindingState(binding)
        }
    }

    func closeCurrentTab(confirm: BrowserIntentConfirmation) async throws -> BrowserIntentOutput {
        guard let selectedID = viewModel.selectedTabID,
              let tab = viewModel.tabs.first(where: { $0.id == selectedID }),
              !tab.isIncognito,
              tab.webAIProvider == nil else {
            throw BrowserIntentError.noEligiblePage
        }
        let survivors = regularTabs().filter { $0.id != tab.id }
        guard !survivors.isEmpty else { throw BrowserIntentError.lastAccessibleTab }
        let binding = try await closeBinding(for: tab)
        try await confirm("Close the current Vortyra tab? Its page state will be lost.")
        try await validateCloseBinding(binding)
        guard viewModel.selectedTabID == selectedID else { throw BrowserIntentError.stalePage }
        guard regularTabs().count > 1 else { throw BrowserIntentError.lastAccessibleTab }
        viewModel.closeTab(tab)
        if let nowSelected = viewModel.tabs.first(where: { $0.id == viewModel.selectedTabID }),
           nowSelected.isIncognito || nowSelected.webAIProvider != nil,
           let repair = regularTabs().first {
            viewModel.selectTab(repair)
        }
        return output("Closed the current tab.")
    }

    func closeGroup(_ groupID: UUID, confirm: BrowserIntentConfirmation) async throws -> BrowserIntentOutput {
        guard let group = viewModel.tabGroups.first(where: { $0.id == groupID }) else {
            throw BrowserIntentError.unknownGroup
        }
        let memberTabs = regularTabs().filter { $0.groupID == groupID }
        let captured = Set(memberTabs.map(\.id))
        guard !captured.isEmpty else {
            throw BrowserIntentError.emptyResult("This group has no regular tabs to close.")
        }
        guard regularTabs().contains(where: { !captured.contains($0.id) }) else {
            throw BrowserIntentError.lastAccessibleTab
        }
        var memberBindings: [CloseBinding] = []
        for member in memberTabs {
            memberBindings.append(try await closeBinding(for: member))
        }
        let title = String(group.title.prefix(80))
        let message = "Close \(captured.count) tab\(captured.count == 1 ? "" : "s")"
            + " in \"\(title)\"? Their page state will be lost."
        try await confirm(message)
        try await revalidateGroupClose(
            groupID: groupID,
            captured: captured,
            memberBindings: memberBindings
        )
        for tabID in captured {
            if let tab = viewModel.tabs.first(where: { $0.id == tabID }) {
                viewModel.closeTab(tab)
            }
        }
        if let selected = viewModel.tabs.first(where: { $0.id == viewModel.selectedTabID }),
           selected.isIncognito || selected.webAIProvider != nil || captured.contains(selected.id),
           let repair = regularTabs().first {
            viewModel.selectTab(repair)
        }
        return output("Closed \(captured.count) tab\(captured.count == 1 ? "" : "s") in the group.")
    }

    private func revalidateGroupClose(
        groupID: UUID,
        captured: Set<UUID>,
        memberBindings: [CloseBinding]
    ) async throws {
        guard viewModel.tabGroups.contains(where: { $0.id == groupID }) else {
            throw BrowserIntentError.stalePage
        }
        for memberBinding in memberBindings {
            try await validateCloseBinding(memberBinding)
            guard memberBinding.tab.groupID == groupID else { throw BrowserIntentError.stalePage }
        }
        let currentMembers = Set(regularTabs().filter { $0.groupID == groupID }.map(\.id))
        guard currentMembers == captured else { throw BrowserIntentError.stalePage }
        guard regularTabs().contains(where: { !captured.contains($0.id) }) else {
            throw BrowserIntentError.lastAccessibleTab
        }
        guard viewModel.tabGroups.contains(where: { $0.id == groupID }) else {
            throw BrowserIntentError.stalePage
        }
        for memberBinding in memberBindings {
            try validateCloseBindingState(memberBinding)
            guard memberBinding.tab.groupID == groupID else { throw BrowserIntentError.stalePage }
        }
    }

    func switchGroup(_ groupID: UUID) throws -> BrowserIntentOutput {
        guard viewModel.tabGroups.contains(where: { $0.id == groupID }) else {
            throw BrowserIntentError.unknownGroup
        }
        guard let first = regularTabs().first(where: { $0.groupID == groupID }) else {
            return output("This group has no regular tabs.")
        }
        viewModel.selectTab(first)
        callbacks.onTabSelected(first.id)
        return output("Switched to the tab group.")
    }

    /// Selects one regular tab. Private tabs and web AI pages are never switch targets.
    func switchToTab(_ tabID: UUID) throws -> BrowserIntentOutput {
        guard let tab = regularTabs().first(where: { $0.id == tabID }) else {
            throw BrowserIntentError.emptyResult("That tab is no longer open in Vortyra.")
        }
        viewModel.selectTab(tab)
        callbacks.onTabSelected(tab.id)
        return output("Switched to the tab.")
    }

    func moveToGroup(_ groupID: UUID) throws -> BrowserIntentOutput {
        guard viewModel.tabGroups.contains(where: { $0.id == groupID }) else {
            throw BrowserIntentError.unknownGroup
        }
        guard let selectedID = viewModel.selectedTabID,
              let tab = viewModel.tabs.first(where: { $0.id == selectedID }),
              !tab.isIncognito, tab.webAIProvider == nil else {
            throw BrowserIntentError.noEligiblePage
        }
        viewModel.move(tab, to: groupID)
        return output("Moved the current tab to the group.")
    }

    func openSplit(first: URL, second: URL) throws -> BrowserIntentOutput {
        guard AgentTaskURLParser.isAllowedStartURL(first),
              AgentTaskURLParser.isAllowedStartURL(second) else {
            throw BrowserIntentError.invalidInput("Provide valid http or https addresses for both pages.")
        }
        let firstTab = BrowserTab(title: first.host ?? "New Tab", url: first, isIncognito: false)
        let secondTab = BrowserTab(title: second.host ?? "New Tab", url: second, isIncognito: false)
        viewModel.tabs.append(firstTab)
        viewModel.tabs.append(secondTab)
        viewModel.setSplitPair(primaryID: firstTab.id, secondaryID: secondTab.id, isHorizontal: false)
        callbacks.openSplit(firstTab.id, secondTab.id)
        viewModel.navigate(to: first, in: firstTab)
        viewModel.navigate(to: second, in: secondTab)
        viewModel.selectTab(firstTab)
        callbacks.onTabSelected(firstTab.id)
        return output("Opened both websites side by side.")
    }

    func endSplit() throws -> BrowserIntentOutput {
        guard let selectedID = viewModel.selectedTabID,
              let tab = viewModel.tabs.first(where: { $0.id == selectedID }),
              !tab.isIncognito, tab.webAIProvider == nil else {
            throw BrowserIntentError.noEligiblePage
        }
        guard let pair = viewModel.splitPair(containing: tab.id) else {
            throw BrowserIntentError.emptyResult("The current tab is not in a split view.")
        }
        let partnerID = pair.primaryID == tab.id ? pair.secondaryID : pair.primaryID
        guard let partner = viewModel.tabs.first(where: { $0.id == partnerID }),
              !partner.isIncognito, partner.webAIProvider == nil else {
            throw BrowserIntentError.stalePage
        }
        viewModel.removeSplitPair(containing: tab.id)
        callbacks.endSplit()
        return output("Ended split view; both tabs stay open.")
    }

    func rejectPrivateContext() throws {
        guard let selectedID = viewModel.selectedTabID,
              let tab = viewModel.tabs.first(where: { $0.id == selectedID }),
              !tab.isIncognito, tab.webAIProvider == nil else {
            throw BrowserIntentError.noEligiblePage
        }
    }
}
