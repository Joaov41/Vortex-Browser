import SwiftUI
import WebKit

/// Per-site ad blocking and cookie controls for the current page, opened from the
/// page menu's "Site Protection…".
struct SitePrivacyPanel: View {
    let url: URL?
    let webView: WKWebView
    let onOpenAdBlockSettings: () -> Void

    @ObservedObject private var privacyStore = SitePrivacyStore.shared
    @ObservedObject private var adBlockService = AdBlockService.shared
    @ObservedObject private var cookieBlocker = ThirdPartyCookieBlocker.shared
    @ObservedObject private var lite = UBlockLiteService.shared

    private var isAdBlockingPaused: Bool {
        privacyStore.isAdBlockingPaused(for: url)
    }

    var body: some View {
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
                    Text(lite.engine == .ublockLite ? "uBlock Origin Lite" : (lite.engine == .off ? "Ad blocking is off" : (isAdBlockingPaused ? "Site protection is paused" : "Site protection is active")))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            if lite.engine == .ublockLite {
                Button {
                    lite.showPopup(for: webView)
                } label: {
                    Label("uBlock Origin Lite Controls", systemImage: "shield.lefthalf.filled")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
            } else {
                Toggle("Block ads and trackers", isOn: adBlockingBinding)
                    .disabled(!adBlockService.isEnabled || url?.host == nil)
            }

            Toggle("Block third-party cookies", isOn: cookieBlockingBinding)
                .disabled(!cookieBlocker.isSupported || !cookieBlocker.isEnabled || url?.host == nil)

            if !cookieBlocker.isSupported {
                Text(cookieBlocker.unavailabilityReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !cookieBlocker.isEnabled {
                Text("Turn on Block Third-Party Cookies in the main settings menu first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if lite.engine == .vortex {
                LabeledContent("Blocked this session", value: "\(adBlockService.blockedCount)")
                    .font(.subheadline)
            }

            Button {
                onOpenAdBlockSettings()
            } label: {
                Label("Ad Blocker Settings", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .frame(maxWidth: 420)
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
            get: {
                cookieBlocker.isSupported && cookieBlocker.isEnabled && !privacyStore.isCookieBlockingAllowed(for: url)
            },
            set: { enabled in
                privacyStore.setCookieBlockingAllowed(!enabled, for: url, webView: webView)
            }
        )
    }

    private var shieldSymbol: String {
        if lite.engine == .ublockLite { return "shield.lefthalf.filled" }
        if !adBlockService.isEnabled || isAdBlockingPaused { return "shield.slash" }
        return "shield.checkered"
    }

    private var shieldColor: Color {
        lite.engine == .ublockLite ? .blue : (!adBlockService.isEnabled || isAdBlockingPaused ? .orange : .green)
    }
}
