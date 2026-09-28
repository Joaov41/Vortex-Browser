import SwiftUI

/// Domain and connection-security indicator shown in the collapsed toolbar pill.
struct ToolbarAddressButton: View {
    @ObservedObject var tab: BrowserTab
    let maxWidth: CGFloat
    let action: () -> Void

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
                if let host {
                    Image(systemName: isSecure ? "lock.fill" : "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isSecure ? AnyShapeStyle(.secondary) : AnyShapeStyle(BrowserDesign.Tint.warning))
                    Text(host)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Image(systemName: "magnifyingglass")
                }
            }
            .frame(minWidth: BrowserDesign.Size.hitTarget, maxWidth: maxWidth, minHeight: BrowserDesign.Size.hitTarget)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Edit the address or search")
    }

    private var accessibilityLabel: String {
        guard let host else { return "Search or enter address" }
        return isSecure ? "\(host), secure connection" : "\(host), not secure"
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
