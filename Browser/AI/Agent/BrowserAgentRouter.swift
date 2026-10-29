//
//  BrowserAgentRouter.swift
//  Vortex
//
//  Decides, in agent mode, whether a message asks for something to be done on
//  the page (agent) or is a question about it (normal chat). Requests that
//  start with an action verb go to the agent; everything else goes to chat,
//  which keeps questions on the user's chosen model and costs nothing extra.
//  "/do …" and "/ask …" force a route.
//

import Foundation

enum BrowserAgentRouter {
    enum Route: Equatable {
        case agent(String)
        case research(String)
        case chat(String)
    }

    /// Words that can come before the action itself ("can you", "please", "help me"…).
    private static let lead = #"(?:(?:can|could|would|will) you |please |pls |kindly |go ahead and |"#
        + #"try to |help me |i want to |i'd like to |i would like to |i need to |let's |lets |just |"#
        + #"now |then |and |ok,? |okay,? )*"#

    /// Imperatives that mean "do something on the page".
    private static let actionVerbs = [
        "click", "tap", "press", "hit", "open", "go to", "go back", "go forward", "navigate", "visit", "reload", "refresh",
        "search", "look up", "find", "fetch", "type", "enter", "fill", "add", "remove", "delete", "select",
        "choose", "pick", "check", "uncheck", "tick", "untick", "toggle", "scroll", "sign up",
        "register", "subscribe", "unsubscribe", "book", "buy", "order", "purchase", "reserve",
        "apply", "download", "play", "pause", "follow", "unfollow", "like", "reply", "post",
        "send", "share", "sort", "filter", "expand", "collapse", "dismiss", "accept", "reject",
        "decline", "log in", "login", "sign in", "log out", "sign out", "show me", "take me",
        "bring me", "switch", "set", "change", "turn on", "turn off", "enable", "disable",
        "close", "submit", "copy", "hide", "inspect", "load more", "next page", "previous page"
    ]

    private static let actionPattern: NSRegularExpression = {
        let verbs = actionVerbs
            .sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: "^" + lead + "(?:" + verbs + ")\\b")
    }()

    /// Narrow phrases for the browser-specific tools. Keep ordinary translation, comparison, and
    /// explanation questions on the user's selected chat model.
    private static let extensionActionPattern: NSRegularExpression = {
        let patterns = [
            "^(?:\(lead))(?:list|show|check) (?:my )?(?:browser )?(?:tabs|bookmarks|favorites|tab groups|folders|downloads)\\b",
            "^(?:\(lead))(?:create|make) (?:a |an |new )?(?:favorites? )?(?:tab )?(?:group|folder)\\b",
            "^(?:\(lead))(?:rename|move) (?:this |the )?(?:tab group|group|tab|bookmark|favorite)\\b",
            "^(?:\(lead))(?:put|move) .+ (?:into|in) .+ (?:group|folder)\\b",
            "^(?:\(lead))switch to (?:the )?tab\\b",
            "^(?:\(lead))(?:save|add|bookmark) .*(?:favorites|bookmark|folder)\\b",
            "^(?:\(lead))save .+ in .+ folder\\b",
            "^(?:\(lead))bookmark (?:this|the current) page\\b",
            "^(?:\(lead))cancel (?:this |the )?download\\b",
            "^(?:\(lead))(?:extract|export|save) (?:the |these |this )?.*\\b(?:links|tables|csv|pdf|comparison)\\b",
            "^(?:\(lead))collect .*(?:names|prices|links|table|data)\\b.*\\bfrom\\b",
            // Pulling data off the page and making files need the agent's data and export tools;
            // chat cannot create files ("extract the dates", then "now create the PDF").
            "^(?:\(lead))(?:extract|scrape|pull out|grab|gather|collect)\\b",
            "^(?:\(lead))(?:create|make|generate|produce|build|export|save|turn (?:it|this|that|them) into|put (?:it|this|that|them) (?:in|into))\\b.{0,60}\\b(?:pdfs?|csvs?|spreadsheets?|excel|reports?|files?)\\b",
            // "Compare the price of these laptops and make a PDF report": the file request comes later.
            "^(?!(?:what|how|why|when|where|who|which|is|are|does|do|did|should|could)\\b).*\\b(?:and|then) (?:make|create|generate|produce|export|save) (?:me )?(?:a |an |the |it as |them as )?.{0,30}\\b(?:pdfs?|csvs?|spreadsheets?|reports?)\\b",
            "^(?:\(lead))compare .*(?:tables|datasets|pages|sources|prices)\\b",
            "^(?:\(lead))translate (?:this )?page\\b",
            "^(?:\(lead))(?:turn on|turn off|enable|disable) (?:the )?reader mode\\b",
            "^(?:\(lead))show original page\\b",
            "^(?:\(lead))(?:highlight|find) .*(?:page text|this phrase|the phrase)\\b",
            "^(?:\(lead))(?:upload|select) (?:a |the )?(?:file|document)\\b",
            "^(?:\(lead))attach (?:the )?(?:document|file) .+ (?:to|on) (?:this |the )?form\\b",
            "^(?:\(lead))(?:hover over|move over) .+",
            "^(?:\(lead))set (?:the )?slider\\b",
            "^(?:\(lead))scroll (?:this |the )?(?:element|panel|container)\\b",
            "^(?:\(lead))drag .+ to .+",
            "^(?:\(lead))check page translation status\\b",
            "^(?:\(lead))(?:take|capture|show) (?:a |the )?(?:(?:current |this |the )?page )?screenshot(?: of (?:this|the )?(?:current )?page)?\\b",
            "^(?:\(lead))(?:use|switch to|request) (?:the )?desktop (?:site|version)\\b",
            "^(?:\(lead))(?:open|show) .+ (?:in|as) (?:a )?split(?: view)?\\b",
            "^(?:\(lead))split (?:this |the current )?page (?:with|beside) .+",
            "^(?:\(lead))copy .+ to (?:the )?clipboard\\b",
            "^(?:\(lead))search (?:my )?(?:browser )?history for\\b"
        ]
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: patterns.joined(separator: "|"))
    }()

    /// Explicit requests to gather online evidence get the research preset.
    /// Comparisons of currently open pages, tables, and datasets keep their
    /// existing browser-action route.
    private static let researchActionPattern: NSRegularExpression = {
        let patterns = [
            "^(?:\(lead))(?:research|web research)\\b",
            "^(?:\(lead))(?:find|search for) .{0,100}\\b(?:multiple|several|three|four|five|3|4|5) sources?\\b",
            "^(?:\(lead))(?:find sources online|find sources on the web)\\b",
            "^(?:\(lead))compare .{0,180}\\b(?:across|between|from) (?:multiple |several |different )?(?:websites|sites|sources)\\b",
            "^(?:\(lead))compare .{0,180}\\b(?:sources|websites)\\b.{0,40}\\b(?:online|on the web|on the internet)\\b"
        ]
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: patterns.joined(separator: "|"))
    }()

    static func route(_ text: String) -> Route {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let forced = stripping(prefix: "/do", from: trimmed) {
            return .agent(forced)
        }
        if let forced = stripping(prefix: "/ask", from: trimmed) {
            return .chat(forced)
        }
        // Local and Cloud handle /search as a quick lookup before this router runs. Other models reach
        // here; chat cannot search, so the agent searches the web and answers with its sources.
        if let query = stripping(prefix: "/search", from: trimmed) {
            return .agent("Search the web for: \(query)\nAnswer briefly and name the sources you used.")
        }
        let normalized = trimmed
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
        let range = NSRange(normalized.startIndex..., in: normalized)
        if researchActionPattern.firstMatch(in: normalized, range: range) != nil,
           !isOpenPageComparison(normalized) {
            return .research(trimmed)
        }
        if actionPattern.firstMatch(in: normalized, range: range) != nil
            || extensionActionPattern.firstMatch(in: normalized, range: range) != nil {
            return .agent(trimmed)
        }
        return .chat(trimmed)
    }

    static func isResearchIntent(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
        let task = stripping(prefix: "/do", from: normalized) ?? normalized
        let range = NSRange(task.startIndex..., in: task)
        return researchActionPattern.firstMatch(in: task, range: range) != nil
            && !isOpenPageComparison(task)
    }

    private static func isOpenPageComparison(_ normalized: String) -> Bool {
        guard normalized.range(of: #"^\s*(?:can you |could you |please )*compare\b"#, options: .regularExpression) != nil else { return false }
        let currentPageCues = [
            "these pages", "these two pages", "the two pages", "both pages", "open pages", "current pages", "these tables",
            "the tables", "these datasets", "the datasets", "these results", "this page", "current tab"
        ]
        return currentPageCues.contains(where: normalized.contains)
    }

    private static func stripping(prefix: String, from text: String) -> String? {
        guard text.lowercased().hasPrefix(prefix) else { return nil }
        let rest = text.dropFirst(prefix.count)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        let stripped = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }
}
