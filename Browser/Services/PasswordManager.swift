import Security
import SwiftUI
import WebKit
import LocalAuthentication
import Combine

enum PasswordBridgePolicy {
    static func normalizedCredentialHost(_ host: String?) -> String? {
        guard let host else { return nil }
        let normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized.isEmpty ? nil : normalized
    }

    static func shouldOfferSave(
        existingUsername: String?,
        existingPassword: String?,
        submittedUsername: String,
        submittedPassword: String
    ) -> Bool {
        existingUsername != submittedUsername || existingPassword != submittedPassword
    }

    static func allowsMessage(
        securityOriginScheme: String?,
        securityOriginHost: String?,
        webViewURL: URL?,
        isMainFrame: Bool
    ) -> Bool {
        guard isMainFrame,
              securityOriginScheme?.lowercased() == "https",
              webViewURL?.scheme?.lowercased() == "https",
              let originHost = normalizedCredentialHost(securityOriginHost),
              let pageHost = normalizedCredentialHost(webViewURL?.host) else {
            return false
        }
        return originHost == pageHost
    }
}

@MainActor
class PasswordManager: NSObject, ObservableObject {
    static let shared = PasswordManager()
    
    @Published var isAutofillEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAutofillEnabled, forKey: "autofillEnabled")
        }
    }
    
    @Published var showPasswordPrompt: Bool = false
    @Published var currentLoginForm: LoginForm? = nil
    
    struct LoginForm {
        let website: String
        let username: String
        let password: String
    }
    
    struct SavedCredential {
        let website: String
        let username: String
        let password: String
    }
    
    override init() {
        let savedValue = UserDefaults.standard.object(forKey: "autofillEnabled") as? Bool
        self.isAutofillEnabled = savedValue ?? true
        super.init()
        if savedValue == nil {
            UserDefaults.standard.set(true, forKey: "autofillEnabled")
        }
    }
    
    // MARK: - WebView Configuration
    func configureWebView(_ webView: WKWebView) {
        guard isAutofillEnabled else { return }
        
        // Add JavaScript to detect login forms
        let detectLoginScript = WKUserScript(
            source: loginDetectionJavaScript(),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        webView.configuration.userContentController.addUserScript(detectLoginScript)
        
        // Add message handler for login detection
        webView.configuration.userContentController.add(self, name: "passwordManager")
    }
    
    // MARK: - Keychain Operations
    func saveCredentials(website: String, username: String, password: String) async -> Bool {
        // Authenticate user first
        guard await authenticateUser() else { return false }
        
        let passwordData = Data(password.utf8)
        
        let matchQuery: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: website,
            kSecAttrAccount as String: username
        ]

        let updateStatus = SecItemUpdate(
            matchQuery as CFDictionary,
            [kSecValueData as String: passwordData] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = matchQuery
        addQuery[kSecValueData as String] = passwordData
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }
    
    func loadCredentials(for website: String) async -> SavedCredential? {
        // Authenticate user first
        guard await authenticateUser() else { return nil }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: website,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let dict = result as? [String: Any],
           let passwordData = dict[kSecValueData as String] as? Data,
           let password = String(data: passwordData, encoding: .utf8),
           let username = dict[kSecAttrAccount as String] as? String {
            return SavedCredential(website: website, username: username, password: password)
        }
        
        return nil
    }
    
    func deleteCredentials(for website: String, username: String) async -> Bool {
        guard await authenticateUser() else { return false }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: website,
            kSecAttrAccount as String: username
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess
    }
    
    // MARK: - Authentication
    private func authenticateUser() async -> Bool {
        let context = LAContext()
        var error: NSError?
        
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        
        do {
            let result: Bool = try await withCheckedThrowingContinuation { continuation in
                context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "Authenticate to access passwords"
                ) { success, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: success)
                    }
                }
            }
            return result
        } catch {
            print("Authentication failed: \(error)")
            return false
        }
    }
    
    // MARK: - JavaScript
    private func loginDetectionJavaScript() -> String {
        return """
        (function() {
            'use strict';

            const configuredForms = new WeakSet();

            window.autofillCredentials = function(username, password) {
                const form = Array.from(document.querySelectorAll('form')).find(candidate =>
                    candidate.querySelector('input[type="password"]') &&
                    candidate.querySelector('input[type="text"], input[type="email"]')
                );
                if (!form) { return; }
                const usernameInput = form.querySelector('input[type="text"], input[type="email"]');
                const passwordInput = form.querySelector('input[type="password"]');
                usernameInput.value = username;
                passwordInput.value = password;
                usernameInput.dispatchEvent(new Event('input', { bubbles: true }));
                passwordInput.dispatchEvent(new Event('input', { bubbles: true }));
            };
            
            function detectLoginForm() {
                const forms = document.querySelectorAll('form');
                
                for (const form of forms) {
                    const passwordInputs = form.querySelectorAll('input[type="password"]');
                    const usernameInputs = form.querySelectorAll('input[type="text"], input[type="email"]');
                    
                    if (passwordInputs.length > 0 && usernameInputs.length > 0) {
                        if (configuredForms.has(form)) { continue; }
                        configuredForms.add(form);
                        
                        // Check for saved credentials and autofill
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.passwordManager) {
                            window.webkit.messageHandlers.passwordManager.postMessage({
                                type: 'checkCredentials'
                            });
                        }
                        
                        // Listen for form submission
                        form.addEventListener('submit', function(e) {
                            const usernameInput = form.querySelector('input[type="text"], input[type="email"]');
                            const passwordInput = form.querySelector('input[type="password"]');
                            if (!usernameInput || !passwordInput) { return; }
                            const username = usernameInput.value;
                            const password = passwordInput.value;
                            
                            if (username && password) {
                                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.passwordManager) {
                                    window.webkit.messageHandlers.passwordManager.postMessage({
                                        type: 'loginDetected',
                                        username: username,
                                        password: password
                                    });
                                }
                            }
                        });
                        
                        break; // Only handle first login form
                    }
                }
            }
            
            // Run detection on page load
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', detectLoginForm);
            } else {
                detectLoginForm();
            }
            
            // Also run on dynamic content changes
            const observer = new MutationObserver(detectLoginForm);
            observer.observe(document.body, { childList: true, subtree: true });
        })();
        """
    }
    
    // MARK: - Handle Save Prompt
    func promptToSaveCredentials(_ loginForm: LoginForm) {
        self.currentLoginForm = loginForm
        self.showPasswordPrompt = true
    }
    
    func saveCurrentCredentials() async {
        guard let form = currentLoginForm else { return }
        
        let success = await saveCredentials(
            website: form.website,
            username: form.username,
            password: form.password
        )
        
        if success {
            print("Credentials saved successfully")
        } else {
            print("Failed to save credentials")
        }
        
        self.showPasswordPrompt = false
        self.currentLoginForm = nil
    }
    
    func dismissPasswordPrompt() {
        self.showPasswordPrompt = false
        self.currentLoginForm = nil
    }
}

// MARK: - WKScriptMessageHandler
extension PasswordManager: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              PasswordBridgePolicy.allowsMessage(
                securityOriginScheme: message.frameInfo.securityOrigin.protocol,
                securityOriginHost: message.frameInfo.securityOrigin.host,
                webViewURL: message.webView?.url,
                isMainFrame: message.frameInfo.isMainFrame
              ),
              let website = PasswordBridgePolicy.normalizedCredentialHost(message.frameInfo.securityOrigin.host) else {
            return
        }
        
        let bodyCapture = body
        let webViewCapture = message.webView
        let frameInfoCapture = message.frameInfo
        
        Task { @MainActor in
            switch type {
            case "loginDetected":
                if let username = bodyCapture["username"] as? String,
                   let password = bodyCapture["password"] as? String {
                    
                    // Check if credentials already exist
                    let existing = await self.loadCredentials(for: website)
                    if PasswordBridgePolicy.shouldOfferSave(
                        existingUsername: existing?.username,
                        existingPassword: existing?.password,
                        submittedUsername: username,
                        submittedPassword: password
                    ) {
                        // New credentials or different username, prompt to save
                        let loginForm = LoginForm(website: website, username: username, password: password)
                        self.promptToSaveCredentials(loginForm)
                    }
                }
                
            case "checkCredentials":
                if let webView = webViewCapture {
                    // Try to load and autofill credentials
                    if let creds = await self.loadCredentials(for: website) {
                        let script = """
                        if (window.autofillCredentials) {
                            window.autofillCredentials(username, password);
                            return true;
                        }
                        return false;
                        """
                        _ = try? await webView.callAsyncJavaScript(
                            script,
                            arguments: [
                                "username": creds.username,
                                "password": creds.password
                            ],
                            in: frameInfoCapture,
                            contentWorld: .page
                        )
                    }
                }
                
            default:
                break
            }
        }
    }
}
