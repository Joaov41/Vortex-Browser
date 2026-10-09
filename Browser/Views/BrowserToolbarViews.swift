import SwiftUI
import WebKit

/// Back or forward: tap to go one page, touch and hold to pick from the tab's
/// history in that direction.
struct ToolbarHistoryNavigationButton: View {
    enum Direction { case back, forward }

    @ObservedObject var tab: BrowserTab
    let direction: Direction
    /// iPhone hides forward when there's nothing ahead, freeing room for the domain.
    var hidesWhenUnavailable = false

    private static let menuLimit = 15

    private var isEnabled: Bool {
        direction == .back ? tab.canGoBack : tab.canGoForward
    }

    /// Nearest page first, so the menu reads outward from the current page.
    private var items: [WKBackForwardListItem] {
        guard let list = tab.liveWebView?.backForwardList else { return [] }
        let pages = direction == .back ? Array(list.backList.reversed()) : list.forwardList
        return Array(pages.prefix(Self.menuLimit))
    }

    var body: some View {
        if hidesWhenUnavailable && !isEnabled {
            EmptyView()
        } else {
            menu
        }
    }

    private var menu: some View {
        Menu {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Button {
                    tab.liveWebView?.go(to: item)
                } label: {
                    Text(Self.label(for: item))
                }
            }
        } label: {
            Image(systemName: direction == .back ? "chevron.left" : "chevron.right")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        } primaryAction: {
            if direction == .back {
                tab.navigateBack()
            } else {
                tab.navigateForward()
            }
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .disabled(direction == .back && !isEnabled)
        .accessibilityLabel(direction == .back ? "Back" : "Forward")
        .accessibilityHint("Touch and hold to see earlier pages")
    }

    private static func label(for item: WKBackForwardListItem) -> String {
        if let title = item.title, !title.isEmpty { return title }
        return item.url.host ?? item.url.absoluteString
    }
}

/// History and favorites matching what's typed in the address bar.
struct AddressSuggestionsView: View {
    @ObservedObject var tab: BrowserTab
    @ObservedObject private var history = HistoryStore.shared
    let isEditing: Bool
    let favorites: [Favorite]
    let onSelect: (URL) -> Void

    private struct Suggestion: Identifiable {
        let url: URL
        let title: String
        let isFavorite: Bool
        var id: URL { url }
    }

    private var query: String {
        tab.address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var suggestions: [Suggestion] {
        // Nothing to suggest until the user types something other than the page's own URL.
        guard isEditing, !query.isEmpty, query != tab.currentURL?.absoluteString else { return [] }
        let needle = query.lowercased()
        let favoriteMatches = favorites
            .filter { $0.title.lowercased().contains(needle) || $0.url.absoluteString.lowercased().contains(needle) }
            .prefix(2)
            .map { Suggestion(url: $0.url, title: $0.title, isFavorite: true) }
        let favoriteURLs = Set(favoriteMatches.map(\.url))
        let historyMatches = history.suggestions(for: query, limit: 6)
            .filter { !favoriteURLs.contains($0.url) }
            .map { Suggestion(url: $0.url, title: $0.title, isFavorite: false) }
        return Array((favoriteMatches + historyMatches).prefix(5))
    }

    var body: some View {
        let items = suggestions
        if !items.isEmpty {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    Button {
                        onSelect(item.url)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.isFavorite ? "star.fill" : "clock")
                                .font(.subheadline)
                                .foregroundStyle(item.isFavorite ? AnyShapeStyle(BrowserDesign.Tint.favorite) : AnyShapeStyle(.secondary))
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(Self.displayURL(item.url))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if item.id != items.last?.id {
                        Divider().padding(.leading, 50)
                    }
                }
            }
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: BrowserDesign.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: BrowserDesign.Radius.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.6)
            )
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    /// Host and path without the scheme or "www.", which is how people recognise a page.
    private static func displayURL(_ url: URL) -> String {
        var host = url.host ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = url.path == "/" ? "" : url.path
        return host + path
    }
}

/// Domain and connection-security indicator shown in the collapsed toolbar pill.
struct ToolbarAddressButton: View {
    @ObservedObject var tab: BrowserTab
    let maxWidth: CGFloat
    /// Wider limit used while the forward button is hidden (nothing to go forward to).
    var maxWidthWithoutForward: CGFloat? = nil
    /// iPad: size to the site name instead of always taking the full width, so the bar
    /// has no empty space around a short address.
    var hugsContent = false
    let action: () -> Void

    private var effectiveMaxWidth: CGFloat {
        (!tab.canGoForward ? maxWidthWithoutForward : nil) ?? maxWidth
    }

    private var host: String? {
        guard let host = tab.currentURL?.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var isSecure: Bool {
        tab.currentURL?.scheme?.lowercased() == "https"
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                // Private tabs always show the private icon in the address pill.
                if tab.isIncognito {
                    Image(systemName: "eye.slash")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                if let host {
                    Image(systemName: isSecure ? "lock.fill" : "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isSecure ? AnyShapeStyle(.secondary) : AnyShapeStyle(BrowserDesign.Tint.warning))
                    if hugsContent {
                        Text(Self.shortened(host, maxCharacters: 30))
                            .lineLimit(1)
                            .fixedSize()
                    } else {
                        Text(host)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    Image(systemName: "magnifyingglass")
                }
            }
            .frame(minWidth: BrowserDesign.Size.hitTarget, maxWidth: hugsContent ? nil : effectiveMaxWidth, minHeight: BrowserDesign.Size.hitTarget)
            .padding(.horizontal, hugsContent ? 6 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Edit the address or search")
    }

    /// Keeps the start and end of a long host, e.g. "very-long-subdo…example.com".
    private static func shortened(_ host: String, maxCharacters: Int) -> String {
        guard host.count > maxCharacters else { return host }
        let tail = maxCharacters / 2
        let head = maxCharacters - tail - 1
        return String(host.prefix(head)) + "…" + String(host.suffix(tail))
    }

    private var accessibilityLabel: String {
        let prefix = tab.isIncognito ? "Private tab, " : ""
        guard let host else { return prefix + "Search or enter address" }
        return prefix + (isSecure ? "\(host), secure connection" : "\(host), not secure")
    }
}

/// Thin page-load progress line drawn along the bottom edge of the toolbar pill.
struct ToolbarLoadingProgressBar: View {
    @ObservedObject var tab: BrowserTab

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color.accentColor)
                .frame(width: proxy.size.width * max(0.05, min(1, tab.estimatedProgress)))
                .animation(.easeOut(duration: 0.2), value: tab.estimatedProgress)
        }
        .frame(height: BrowserDesign.Size.progressBarHeight)
        .opacity(tab.isLoading ? 1 : 0)
        .animation(.easeOut(duration: 0.25), value: tab.isLoading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Text for the minimized address strip: the search terms on a search results page,
/// like Safari, otherwise the site name.
struct MinimizedAddressLabel: View {
    @ObservedObject var tab: BrowserTab

    private var searchTerms: String? {
        guard let url = tab.currentURL,
              url.path.lowercased().contains("search"),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let query = items.first(where: { ["q", "p", "query"].contains($0.name) })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty
        else { return nil }
        return query
    }

    private var host: String? {
        guard let host = tab.currentURL?.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var body: some View {
        HStack(spacing: 5) {
            if tab.isIncognito {
                Image(systemName: "eye.slash")
                    .font(.caption2.weight(.semibold))
            }
            if let searchTerms {
                Image(systemName: "magnifyingglass")
                    .font(.caption2.weight(.semibold))
                Text(searchTerms)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if let host {
                if tab.currentURL?.scheme?.lowercased() != "https" {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(BrowserDesign.Tint.warning)
                }
                Text(host)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.caption2.weight(.semibold))
            }
        }
        .accessibilityHidden(true)
    }
}
