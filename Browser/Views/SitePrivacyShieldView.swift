import SwiftUI
import WebKit

struct SitePrivacyShieldButton: View {
    let url: URL?
    let webView: WKWebView
    let onOpenAdBlockSettings: () -> Void

    @ObservedObject private var privacyStore = SitePrivacyStore.shared
    @ObservedObject private var adBlockService = AdBlockService.shared
    @ObservedObject private var cookieBlocker = ThirdPartyCookieBlocker.shared
    @State private var showingPanel = false

    private var isAdBlockingPaused: Bool {
        privacyStore.isAdBlockingPaused(for: url)
    }

    var body: some View {
        Button {
            showingPanel.toggle()
        } label: {
            Image(systemName: shieldSymbol)
                .foregroundStyle(shieldColor)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .popover(isPresented: $showingPanel, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            panel
                .presentationCompactAdaptation(.popover)
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: shieldSymbol)
                    .font(.title2)
                    .foregroundStyle(shieldColor)
                    .frame(width: 44, height: 44)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(privacyStore.host(for: url) ?? "This Page")
                        .font(.headline)
                        .lineLimit(1)
                    Text(isAdBlockingPaused ? "Site protection is paused" : "Site protection is active")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Toggle("Block ads and trackers", isOn: adBlockingBinding)
                .disabled(!adBlockService.isEnabled || url?.host == nil)

            Toggle("Block third-party cookies", isOn: cookieBlockingBinding)
                .disabled(!cookieBlocker.isEnabled || url?.host == nil)

            LabeledContent("Blocked this session", value: "\(adBlockService.blockedCount)")
                .font(.subheadline)

            Button {
                showingPanel = false
                onOpenAdBlockSettings()
            } label: {
                Label("Ad Blocker Settings", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(width: 340)
    }

    private var adBlockingBinding: Binding<Bool> {
        Binding(
            get: { !privacyStore.isAdBlockingPaused(for: url) },
            set: { enabled in
                privacyStore.setAdBlockingPaused(!enabled, for: url, webView: webView)
            }
        )
    }

    private var cookieBlockingBinding: Binding<Bool> {
        Binding(
            get: { !privacyStore.isCookieBlockingAllowed(for: url) },
            set: { enabled in
                privacyStore.setCookieBlockingAllowed(!enabled, for: url, webView: webView)
            }
        )
    }

    private var shieldSymbol: String {
        if !adBlockService.isEnabled || isAdBlockingPaused { return "shield.slash" }
        return "shield.checkered"
    }

    private var shieldColor: Color {
        !adBlockService.isEnabled || isAdBlockingPaused ? .orange : .green
    }

    private var accessibilityLabel: String {
        let host = privacyStore.host(for: url) ?? "this page"
        return isAdBlockingPaused ? "Privacy shield paused for \(host)" : "Privacy shield active for \(host)"
    }
}
