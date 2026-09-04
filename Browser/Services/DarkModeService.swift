import WebKit
import SwiftUI
import Combine

@MainActor
class DarkModeService: ObservableObject {
    static let shared = DarkModeService()

    @Published var isDarkMode: Bool {
        didSet {
            UserDefaults.standard.set(isDarkMode, forKey: "darkModeEnabled")
            if isDarkMode != oldValue {
                updateAllWebViews()
            }
        }
    }

    // DarkReader settings
    @Published var brightness: Int {
        didSet {
            UserDefaults.standard.set(brightness, forKey: "darkModeBrightness")
            updateAllWebViews()
        }
    }

    @Published var contrast: Int {
        didSet {
            UserDefaults.standard.set(contrast, forKey: "darkModeContrast")
            updateAllWebViews()
        }
    }

    @Published var sepia: Int {
        didSet {
            UserDefaults.standard.set(sepia, forKey: "darkModeSepia")
            updateAllWebViews()
        }
    }

    private var webViews: WeakSet<WKWebView> = WeakSet()
    private var overriddenWebViews: WeakSet<WKWebView> = WeakSet()  // WebViews with per-tab overrides
    private var darkReaderJS: String?
    private var scriptLoaded: Bool = false
    private var effectiveStates = NSMapTable<WKWebView, NSNumber>.weakToStrongObjects()
    private var documentScripts: [String: String] = [:]

    init() {
        self.isDarkMode = UserDefaults.standard.bool(forKey: "darkModeEnabled")
        self.brightness = UserDefaults.standard.object(forKey: "darkModeBrightness") as? Int ?? 100
        self.contrast = UserDefaults.standard.object(forKey: "darkModeContrast") as? Int ?? 90
        self.sepia = UserDefaults.standard.object(forKey: "darkModeSepia") as? Int ?? 10
        // Script loading deferred until first use to improve startup time
    }

    private func loadDarkReaderScriptIfNeeded() {
        guard !scriptLoaded else { return }
        scriptLoaded = true

        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: "darkreader", withExtension: "js"),
            bundle.url(forResource: "DarkReader", withExtension: "js"),
            bundle.bundleURL.appendingPathComponent("darkreader.js"),
            bundle.bundleURL.appendingPathComponent("DarkReader.js")
        ]

        for url in candidates {
            guard let url else { continue }
            if let source = try? String(contentsOf: url, encoding: .utf8) {
                self.darkReaderJS = source
                print("DarkReader loaded from: \(url.lastPathComponent)")
                return
            }
        }

        print("Warning: darkreader.js not found in bundle. Add it to your project.")
    }

    func configureWebView(_ webView: WKWebView, enabled: Bool? = nil, hasOverride: Bool = false) {
        webViews.insert(webView)
        setOverride(for: webView, hasOverride: hasOverride)
        loadDarkReaderScriptIfNeeded()
        updateDocumentScript(in: webView, enabled: enabled ?? isDarkMode)
    }

    func applyDarkMode(to webView: WKWebView) {
        if isDarkMode {
            enableDarkReader(in: webView)
        } else {
            disableDarkReader(in: webView)
        }
    }

    /// Mark a webview as having a per-tab dark mode override (won't be affected by global toggle)
    func setOverride(for webView: WKWebView, hasOverride: Bool) {
        if hasOverride {
            overriddenWebViews.insert(webView)
        } else {
            overriddenWebViews.remove(webView)
        }
    }

    /// Enable dark mode for a specific webview (used for per-tab control)
    func enableDarkMode(for webView: WKWebView) {
        enableDarkReader(in: webView)
    }

    /// Disable dark mode for a specific webview (used for per-tab control)
    func disableDarkMode(for webView: WKWebView) {
        disableDarkReader(in: webView)
    }

    private func updateAllWebViews() {
        documentScripts.removeAll()
        let overridden = Set(overriddenWebViews.allObjects.map { ObjectIdentifier($0) })
        for webView in webViews.allObjects {
            let enabled = overridden.contains(ObjectIdentifier(webView))
                ? effectiveStates.object(forKey: webView)?.boolValue ?? isDarkMode
                : isDarkMode
            if enabled {
                enableDarkReader(in: webView)
            } else {
                disableDarkReader(in: webView)
            }
        }
    }

    private func enableDarkReader(in webView: WKWebView) {
        updateDocumentScript(in: webView, enabled: true)
        // If we have the bundled script, inject it first then enable
        // Otherwise, load from CDN as fallback
        let enableScript: String

        if darkReaderJS != nil {
            enableScript = activationScript(enabled: true)
        } else {
            // Fallback: load DarkReader from CDN
            enableScript = """
            (function() {
                if (typeof DarkReader !== 'undefined') {
                    DarkReader.enable({
                        brightness: \(brightness),
                        contrast: \(contrast),
                        sepia: \(sepia)
                    });
                    return;
                }

                var script = document.createElement('script');
                script.src = 'https://cdn.jsdelivr.net/npm/darkreader@4.9.92/darkreader.min.js';
                script.onload = function() {
                    DarkReader.enable({
                        brightness: \(brightness),
                        contrast: \(contrast),
                        sepia: \(sepia)
                    });
                };
                document.head.appendChild(script);
            })();
            """
        }

        webView.evaluateJavaScript(enableScript) { _, error in
            if let error = error {
                print("DarkReader enable error: \(error.localizedDescription)")
            }
        }
    }

    private func disableDarkReader(in webView: WKWebView) {
        updateDocumentScript(in: webView, enabled: false)
        let disableScript = activationScript(enabled: false)

        webView.evaluateJavaScript(disableScript) { _, error in
            if let error = error {
                print("DarkReader disable error: \(error.localizedDescription)")
            }
        }
    }

    private func updateDocumentScript(in webView: WKWebView, enabled: Bool) {
        loadDarkReaderScriptIfNeeded()
        effectiveStates.setObject(NSNumber(value: enabled), forKey: webView)
        // DarkReader owns page theming; asking WebKit for native dark styling too
        // can double-theme sites. Only the empty/loading surface changes here.
        webView.overrideUserInterfaceStyle = .light
        let background: UIColor = enabled
            ? UIColor(red: 24 / 255, green: 26 / 255, blue: 27 / 255, alpha: 1)
            : .white
        webView.backgroundColor = background
        webView.scrollView.backgroundColor = background
        webView.underPageBackgroundColor = background

        guard let darkReaderJS else { return }
        let activation = activationScript(enabled: enabled)
        let source: String
        if let cached = documentScripts[activation] {
            source = cached
        } else {
            source = darkReaderJS + "\n;\n" + activation
            documentScripts[activation] = source
        }
        ManagedUserScript.install(
            source: source, identifier: "dark-mode", in: webView.configuration.userContentController
        )
    }

    /// Both document-start activation and didFinish recovery use the same
    /// idempotent operation, avoiding a second expensive DarkReader.enable().
    func activationScript(enabled: Bool) -> String {
        """
        (function() {
            if (typeof DarkReader === 'undefined') { return; }
            const enabled = \(enabled ? "true" : "false");
            const key = '\(enabled)-\(brightness)-\(contrast)-\(sepia)';
            if (window.__vortexDarkModeKey === key && DarkReader.isEnabled() === enabled) { return; }
            if (enabled) {
                DarkReader.enable({brightness: \(brightness), contrast: \(contrast), sepia: \(sepia)});
            } else if (DarkReader.isEnabled()) {
                DarkReader.disable();
            }
            window.__vortexDarkModeKey = key;
        })();
        """
    }
}

// Helper class to store weak references to WKWebViews
private class WeakSet<T: AnyObject> {
    private var objects: NSHashTable<T> = NSHashTable.weakObjects()
    
    func insert(_ object: T) {
        objects.add(object)
    }

    func remove(_ object: T) {
        objects.remove(object)
    }
    
    var allObjects: [T] {
        return objects.allObjects
    }
}
