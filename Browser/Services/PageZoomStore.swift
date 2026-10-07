import Foundation
import WebKit

/// Remembers a page zoom level per site, like Safari's per-website zoom.
///
/// Zoom is applied as CSS `zoom` on the root element rather than `WKWebView.pageZoom`:
/// on iOS, `pageZoom` lays out fixed page bars without the web view's obscured insets,
/// which puts cookie banners and cart bars back underneath the bottom toolbar.
@MainActor
enum PageZoomStore {
    static let levels: [CGFloat] = [0.5, 0.75, 0.85, 1.0, 1.15, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    private static let defaultsKey = "pageZoomByHost"
    /// Incognito zoom lives only for the session.
    private static var privateZoom: [String: CGFloat] = [:]

    static func zoom(for url: URL?, isIncognito: Bool) -> CGFloat {
        guard let host = siteKey(for: url) else { return 1.0 }
        if isIncognito, let zoom = privateZoom[host] {
            return zoom
        }
        guard let stored = UserDefaults.standard.dictionary(forKey: defaultsKey)?[host] as? Double else {
            return 1.0
        }
        return CGFloat(stored)
    }

    /// Applies the site's zoom to a freshly committed document.
    static func apply(to webView: WKWebView, isIncognito: Bool) {
        let zoom = zoom(for: webView.url, isIncognito: isIncognito)
        guard abs(zoom - 1.0) > 0.001 else { return }
        setDocumentZoom(zoom, in: webView)
    }

    /// Steps to the next zoom level (`direction` +1 or -1), or back to 100% when 0.
    @discardableResult
    static func step(_ direction: Int, webView: WKWebView, isIncognito: Bool) -> CGFloat {
        let current = zoom(for: webView.url, isIncognito: isIncognito)
        let next: CGFloat
        switch direction {
        case 1...:
            next = levels.first { $0 > current + 0.001 } ?? levels.last ?? current
        case ..<0:
            next = levels.last { $0 < current - 0.001 } ?? levels.first ?? current
        default:
            next = 1.0
        }
        setDocumentZoom(next, in: webView)
        if let host = siteKey(for: webView.url) {
            if isIncognito {
                privateZoom[host] = next
            } else {
                var stored = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
                if abs(next - 1.0) < 0.001 {
                    stored.removeValue(forKey: host)
                } else {
                    stored[host] = Double(next)
                }
                UserDefaults.standard.set(stored, forKey: defaultsKey)
            }
        }
        return next
    }

    static func canZoomIn(_ zoom: CGFloat) -> Bool {
        zoom < (levels.last ?? 3.0) - 0.001
    }

    static func canZoomOut(_ zoom: CGFloat) -> Bool {
        zoom > (levels.first ?? 0.5) + 0.001
    }

    private static func setDocumentZoom(_ zoom: CGFloat, in webView: WKWebView) {
        let script = """
        const marker = "__vortexPageZoom";
        const sheets = (document.adoptedStyleSheets || []).filter(sheet => !sheet[marker]);
        if (Math.abs(zoom - 1) > 0.001) {
            const sheet = new CSSStyleSheet();
            sheet.replaceSync(`html { zoom: ${zoom} !important; }`);
            sheet[marker] = true;
            sheets.push(sheet);
        }
        document.adoptedStyleSheets = sheets;
        """
        webView.callAsyncJavaScript(
            script,
            arguments: ["zoom": Double(zoom)],
            in: nil,
            in: .defaultClient,
            completionHandler: nil
        )
    }

    private static func siteKey(for url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
