import Foundation
import WebKit

/// "Hide Distracting Items": people tap parts of a page to hide them, and the site keeps
/// them hidden on later visits. Hidden items are stored as CSS selectors per site and
/// applied as a stylesheet from the app's own content world, so pages can't see or undo it.
@MainActor
enum DistractionHider {
    private static let defaultsKey = "hiddenDistractionSelectorsByHost"
    /// Incognito choices last only for the session.
    private static var privateSelectors: [String: [String]] = [:]

    static func selectors(for url: URL?, isIncognito: Bool) -> [String] {
        guard let host = siteKey(for: url) else { return [] }
        if isIncognito, let selectors = privateSelectors[host] {
            return selectors
        }
        return (UserDefaults.standard.dictionary(forKey: defaultsKey)?[host] as? [String]) ?? []
    }

    static func hasHiddenItems(for url: URL?, isIncognito: Bool) -> Bool {
        !selectors(for: url, isIncognito: isIncognito).isEmpty
    }

    /// Applies the site's hidden items to a freshly committed document.
    static func apply(to webView: WKWebView, isIncognito: Bool) {
        let selectors = selectors(for: webView.url, isIncognito: isIncognito)
        guard !selectors.isEmpty else { return }
        setHiddenSelectors(selectors, in: webView)
    }

    static func startPicking(in webView: WKWebView) {
        webView.callAsyncJavaScript(pickerScript, arguments: [:], in: nil, in: .defaultClient, completionHandler: nil)
    }

    static func undoLastPick(in webView: WKWebView) {
        webView.callAsyncJavaScript(
            "const P = window.__vortexPicker; if (P && P.active) P.undo();",
            arguments: [:],
            in: nil,
            in: .defaultClient,
            completionHandler: nil
        )
    }

    /// Ends picking and saves what was hidden. When `save` is false the picks are discarded.
    static func finishPicking(in webView: WKWebView, isIncognito: Bool, save: Bool) async {
        let script = """
        const P = window.__vortexPicker;
        if (!P || !P.active) return [];
        return P.finish();
        """
        let result = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
        let picked = (result as? [String]) ?? []
        guard let url = webView.url else { return }
        if save, !picked.isEmpty {
            var selectors = selectors(for: url, isIncognito: isIncognito)
            for selector in picked where !selectors.contains(selector) {
                selectors.append(selector)
            }
            store(selectors, for: url, isIncognito: isIncognito)
        }
        setHiddenSelectors(selectors(for: url, isIncognito: isIncognito), in: webView)
    }

    /// Brings back everything hidden on the current site.
    static func showHiddenItems(in webView: WKWebView, isIncognito: Bool) {
        guard let url = webView.url else { return }
        store([], for: url, isIncognito: isIncognito)
        setHiddenSelectors([], in: webView)
    }

    /// Persists and applies one selector produced by the shared stable-selector algorithm.
    /// The selector must still identify exactly one element in the same document.
    @discardableResult
    static func hide(selector: String, in webView: WKWebView, isIncognito: Bool) async -> Bool {
        guard selector.count <= 512, let url = webView.url else { return false }
        let script = #"""
        try {
          const matches = document.querySelectorAll(selector);
          return matches.length === 1;
        } catch (_) { return false; }
        """#
        let result = try? await webView.callAsyncJavaScript(
            script,
            arguments: ["selector": selector],
            in: nil,
            contentWorld: .defaultClient
        )
        guard result as? Bool == true, webView.url == url else { return false }
        var current = selectors(for: url, isIncognito: isIncognito)
        if !current.contains(selector) {
            current.append(selector)
            store(current, for: url, isIncognito: isIncognito)
        }
        setHiddenSelectors(current, in: webView)
        return true
    }

    private static func store(_ selectors: [String], for url: URL, isIncognito: Bool) {
        guard let host = siteKey(for: url) else { return }
        if isIncognito {
            privateSelectors[host] = selectors
            return
        }
        var stored = UserDefaults.standard.dictionary(forKey: defaultsKey) ?? [:]
        if selectors.isEmpty {
            stored.removeValue(forKey: host)
        } else {
            stored[host] = selectors
        }
        UserDefaults.standard.set(stored, forKey: defaultsKey)
    }

    private static func setHiddenSelectors(_ selectors: [String], in webView: WKWebView) {
        let script = """
        const marker = "__vortexHiddenItems";
        const sheets = (document.adoptedStyleSheets || []).filter(sheet => !sheet[marker]);
        if (selectors.length) {
            const sheet = new CSSStyleSheet();
            for (const selector of selectors) {
                try { sheet.insertRule(`${selector} { display: none !important; }`, sheet.cssRules.length); } catch (e) {}
            }
            sheet[marker] = true;
            sheets.push(sheet);
        }
        document.adoptedStyleSheets = sheets;
        """
        webView.callAsyncJavaScript(
            script,
            arguments: ["selectors": selectors],
            in: nil,
            in: .defaultClient,
            completionHandler: nil
        )
    }

    private static func siteKey(for url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Highlights the element under the finger and hides it on tap. Taps never reach the
    /// page while picking, so links and buttons don't fire.
    private static let pickerScript = """
    if (window.__vortexPicker && window.__vortexPicker.active) return;
    const P = window.__vortexPicker = { active: true, picks: [] };
    const marker = "__vortexPickerSheet";

    const box = document.createElement("div");
    box.style.cssText = "position:fixed;z-index:2147483647;pointer-events:none;display:none;" +
        "border:2px solid #ff3b30;background:rgba(255,59,48,0.16);border-radius:6px;box-sizing:border-box;";
    document.documentElement.appendChild(box);

    function pick(x, y) {
        let el = document.elementFromPoint(x, y);
        if (!el || el === box) return null;
        // Single words and icons are rarely the distraction; grow to a meaningful block.
        while (el && el !== document.body && el !== document.documentElement) {
            const r = el.getBoundingClientRect();
            if (r.width >= 48 && r.height >= 24) break;
            el = el.parentElement;
        }
        if (!el || el === document.body || el === document.documentElement) return null;
        return el;
    }

    function outline(el) {
        if (!el) { box.style.display = "none"; return; }
        const r = el.getBoundingClientRect();
        Object.assign(box.style, {
            display: "block", left: r.left + "px", top: r.top + "px",
            width: r.width + "px", height: r.height + "px"
        });
    }

    \(BrowserStableSelectorScript.helpers)

    function refreshSheet() {
        const sheets = (document.adoptedStyleSheets || []).filter(sheet => !sheet[marker]);
        if (P.picks.length) {
            const sheet = new CSSStyleSheet();
            for (const selector of P.picks) {
                try { sheet.insertRule(`${selector} { display: none !important; }`, sheet.cssRules.length); } catch (e) {}
            }
            sheet[marker] = true;
            sheets.push(sheet);
        }
        document.adoptedStyleSheets = sheets;
    }

    function onTouch(event) {
        const t = event.touches ? event.touches[0] : event;
        outline(pick(t.clientX, t.clientY));
    }

    function onClick(event) {
        event.preventDefault();
        event.stopPropagation();
        event.stopImmediatePropagation();
        const el = pick(event.clientX, event.clientY);
        outline(null);
        if (!el) return;
        const selector = selectorFor(el);
        if (!selector || P.picks.includes(selector)) return;
        P.picks.push(selector);
        refreshSheet();
    }

    function block(event) {
        event.preventDefault();
        event.stopPropagation();
        event.stopImmediatePropagation();
    }

    document.addEventListener("touchstart", onTouch, { capture: true, passive: true });
    document.addEventListener("mousemove", onTouch, true);
    document.addEventListener("click", onClick, true);
    document.addEventListener("submit", block, true);
    document.addEventListener("auxclick", block, true);

    P.undo = () => {
        P.picks.pop();
        refreshSheet();
    };

    P.finish = () => {
        P.active = false;
        document.removeEventListener("touchstart", onTouch, { capture: true });
        document.removeEventListener("mousemove", onTouch, true);
        document.removeEventListener("click", onClick, true);
        document.removeEventListener("submit", block, true);
        document.removeEventListener("auxclick", block, true);
        box.remove();
        const picks = P.picks.slice();
        P.picks = [];
        refreshSheet();
        return picks;
    };
    """
}
