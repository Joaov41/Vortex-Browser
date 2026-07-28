import WebKit
import SwiftUI
import Combine

@MainActor
class IncognitoMode: ObservableObject {
    static let shared = IncognitoMode()
    
    @Published var isActive: Bool = false
    
    private var incognitoDataStore: WKWebsiteDataStore?
    private var incognitoConfiguration: WKWebViewConfiguration?
    
    init() {
        setupIncognitoConfiguration()
    }
    
    private func setupIncognitoConfiguration() {
        // Create non-persistent data store for incognito mode
        incognitoDataStore = WKWebsiteDataStore.nonPersistent()
        
        let config = WKWebViewConfiguration()
        config.websiteDataStore = incognitoDataStore!
        
        // Enhanced privacy settings
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.allowsAirPlayForMediaPlayback = false
        
        // Add privacy-enhancing JavaScript
        let privacyScript = WKUserScript(
            source: privacyEnhancementJavaScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(privacyScript)
        
        incognitoConfiguration = config
    }
    
    func getIncognitoWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        
        // Enhanced privacy settings
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.allowsAirPlayForMediaPlayback = false
        
        // Add privacy-enhancing JavaScript
        let privacyScript = WKUserScript(
            source: privacyEnhancementJavaScript(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(privacyScript)
        
        // Apply ad blocking if enabled
        if AdBlockService.shared.isEnabled {
            AdBlockService.shared.configureWebView(WKWebView(frame: .zero, configuration: config))
        }
        
        return WKWebView(frame: .zero, configuration: config)
    }
    
    func clearIncognitoData() {
        // Clear all data when exiting incognito mode
        incognitoDataStore?.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date.distantPast
        ) { }
    }
    
    func getPrivacyScript() -> String {
        return privacyEnhancementJavaScript()
    }
    
    private func privacyEnhancementJavaScript() -> String {
        return """
        (function() {
            'use strict';
            
            console.log('🕵️ Incognito Mode - Blocking external app launches');
            
            // Aggressive blocking of ALL external navigation attempts
            
            // 1. Override window.open to prevent new windows/tabs that trigger apps
            const originalOpen = window.open;
            window.open = function(url, target, features) {
                console.log('Blocked window.open in incognito:', url);
                // If it's a relative URL or same domain, allow it in same window
                if (url && (url.startsWith('/') || url.startsWith(window.location.origin))) {
                    window.location.href = url;
                }
                return window; // Return current window instead of opening new
            };
            
            // 2. Override location setters to prevent redirects to app schemes
            const originalLocationSetter = Object.getOwnPropertyDescriptor(window, 'location');
            Object.defineProperty(window, 'location', {
                get: function() { return originalLocationSetter.get.call(window); },
                set: function(url) {
                    if (typeof url === 'string') {
                        // Block non-http(s) schemes
                        if (!url.startsWith('http://') && !url.startsWith('https://') && !url.startsWith('/')) {
                            console.log('Blocked location change to:', url);
                            return;
                        }
                    }
                    originalLocationSetter.set.call(window, url);
                }
            });
            
            // 3. Intercept all link clicks
            document.addEventListener('click', function(e) {
                let target = e.target;
                while (target && target.tagName !== 'A') {
                    target = target.parentElement;
                }
                
                if (target && target.href) {
                    const href = target.href;
                    // Block non-http(s) links
                    if (!href.startsWith('http://') && !href.startsWith('https://')) {
                        console.log('Blocked link click to:', href);
                        e.preventDefault();
                        e.stopPropagation();
                        return false;
                    }
                    
                    // Force links to open in same frame
                    if (target.target === '_blank' || target.target === '_new') {
                        e.preventDefault();
                        e.stopPropagation();
                        window.location.href = href;
                        return false;
                    }
                }
            }, true); // Use capture phase to intercept before other handlers
            
            // 4. Override form submissions to prevent external redirects
            const originalSubmit = HTMLFormElement.prototype.submit;
            HTMLFormElement.prototype.submit = function() {
                const action = this.action;
                if (action && !action.startsWith('http://') && !action.startsWith('https://')) {
                    console.log('Blocked form submission to:', action);
                    return;
                }
                originalSubmit.call(this);
            };
            
            // 5. Specifically handle Google consent forms
            if (window.location.hostname.includes('google.com') || window.location.hostname.includes('consent.google')) {
                console.log('Google domain detected - Extra protection active');
                
                // Override any Google-specific navigation
                if (window.google && window.google.navigate) {
                    window.google.navigate = function(url) {
                        console.log('Blocked google.navigate to:', url);
                        if (url && url.startsWith('http')) {
                            window.location.href = url;
                        }
                    };
                }
            }
            
            // 6. Block geolocation (privacy)
            if (navigator.geolocation) {
                navigator.geolocation.getCurrentPosition = function(s, error) {
                    if (error) error({ code: 1, message: "Denied in incognito" });
                };
                navigator.geolocation.watchPosition = function(s, error) {
                    if (error) error({ code: 1, message: "Denied in incognito" });
                    return -1;
                };
            }
            
            // 7. Disable battery API
            if (navigator.getBattery) {
                navigator.getBattery = undefined;
            }
            
            console.log('%c🕵️ Incognito Mode Active - External apps blocked', 'color: #9b59b6; font-size: 12px; font-weight: bold;');
        })();
        """
    }
}