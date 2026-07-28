import Foundation
import WebKit
import SwiftUI
import Combine

@MainActor
final class FontSizeService: ObservableObject {
    static let shared = FontSizeService()
    
    @AppStorage("baseFontSize") var baseFontSize: Double = 14.0 {
        didSet {
            objectWillChange.send()
        }
    }
    
    let objectWillChange = PassthroughSubject<Void, Never>()
    
    private init() {}
    
    func applyFontSize(to webView: WKWebView) {
        let fontScale = baseFontSize / 14.0
        
        let cssString = """
        (function() {
            const style = document.createElement('style');
            style.textContent = `
                html {
                    font-size: \(fontScale * 100)% !important;
                }
                
                body, p, div, span, a, li, td, th {
                    font-size: inherit !important;
                }
                
                h1 { font-size: \(fontScale * 2.0)em !important; }
                h2 { font-size: \(fontScale * 1.5)em !important; }
                h3 { font-size: \(fontScale * 1.3)em !important; }
                h4 { font-size: \(fontScale * 1.1)em !important; }
                h5 { font-size: \(fontScale * 1.0)em !important; }
                h6 { font-size: \(fontScale * 0.9)em !important; }
                
                /* Reddit specific selectors */
                [data-testid="post-title"],
                [data-click-id="title"],
                a[slot="title"] {
                    font-size: \(fontScale * 100)% !important;
                }
                
                [data-testid="comment"],
                div[slot="comment"] p,
                [style*="--commentText"] {
                    font-size: \(fontScale * 100)% !important;
                    line-height: \(fontScale * 1.5) !important;
                }
                
                [data-testid="post-author-link"],
                time, .score {
                    font-size: \(fontScale * 90)% !important;
                }
            `;
            style.id = 'browser-font-size-style';
            
            // Remove existing style if present
            const existing = document.getElementById('browser-font-size-style');
            if (existing) {
                existing.remove();
            }
            
            document.head.appendChild(style);
        })();
        """
        
        webView.evaluateJavaScript(cssString) { _, error in
            if let error = error {
                print("Failed to apply font size: \(error)")
            }
        }
    }
    
    func configureWebView(_ webView: WKWebView) {
        // Apply font size when pages load
        let script = WKUserScript(
            source: getFontSizeScript(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        webView.configuration.userContentController.addUserScript(script)
    }
    
    private func getFontSizeScript() -> String {
        let fontScale = baseFontSize / 14.0
        
        return """
        (function() {
            const style = document.createElement('style');
            style.textContent = `
                html {
                    font-size: \(fontScale * 100)% !important;
                }
            `;
            style.id = 'browser-font-size-initial';
            document.head.appendChild(style);
        })();
        """
    }
}