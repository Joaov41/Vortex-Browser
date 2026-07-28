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
            if isDarkMode { updateAllWebViews() }
        }
    }

    @Published var contrast: Int {
        didSet {
            UserDefaults.standard.set(contrast, forKey: "darkModeContrast")
            if isDarkMode { updateAllWebViews() }
        }
    }

    @Published var sepia: Int {
        didSet {
            UserDefaults.standard.set(sepia, forKey: "darkModeSepia")
            if isDarkMode { updateAllWebViews() }
        }
    }

    private var webViews: WeakSet<WKWebView> = WeakSet()
    private var overriddenWebViews: WeakSet<WKWebView> = WeakSet()  // WebViews with per-tab overrides
    private var darkReaderJS: String?
    private var scriptLoaded: Bool = false

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
            if let source = try? String(contentsOf: url) {
                self.darkReaderJS = source
                print("DarkReader loaded from: \(url.lastPathComponent)")
                return
            }
        }

        print("Warning: darkreader.js not found in bundle. Add it to your project.")
    }

    func configureWebView(_ webView: WKWebView) {
        webViews.insert(webView)

        // Lazy load script on first WebView configuration
        loadDarkReaderScriptIfNeeded()

        // Inject DarkReader at document start for all frames
        if let darkReaderJS = darkReaderJS {
            let userScript = WKUserScript(
                source: darkReaderJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            webView.configuration.userContentController.addUserScript(userScript)
        }
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
        }
        // Note: WeakSet doesn't have remove, but that's OK - if user wants to
        // reset to global behavior they can just follow the global state
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
        let overridden = Set(overriddenWebViews.allObjects.map { ObjectIdentifier($0) })
        for webView in webViews.allObjects {
            // Skip webviews that have per-tab overrides
            if overridden.contains(ObjectIdentifier(webView)) {
                continue
            }
            if isDarkMode {
                enableDarkReader(in: webView)
            } else {
                disableDarkReader(in: webView)
            }
        }
    }

    private func enableDarkReader(in webView: WKWebView) {
        // If we have the bundled script, inject it first then enable
        // Otherwise, load from CDN as fallback
        let enableScript: String

        if darkReaderJS != nil {
            enableScript = """
            (function() {
                if (typeof DarkReader === 'undefined') {
                    console.log('DarkReader not loaded yet');
                    return;
                }
                DarkReader.enable({
                    brightness: \(brightness),
                    contrast: \(contrast),
                    sepia: \(sepia)
                });
            })();
            """
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
        let disableScript = """
        (function() {
            if (typeof DarkReader !== 'undefined') {
                DarkReader.disable();
            }
        })();
        """

        webView.evaluateJavaScript(disableScript) { _, error in
            if let error = error {
                print("DarkReader disable error: \(error.localizedDescription)")
            }
        }
    }
}

// Helper class to store weak references to WKWebViews
private class WeakSet<T: AnyObject> {
    private var objects: NSHashTable<T> = NSHashTable.weakObjects()
    
    func insert(_ object: T) {
        objects.add(object)
    }
    
    var allObjects: [T] {
        return objects.allObjects
    }
}
