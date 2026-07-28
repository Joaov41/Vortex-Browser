import Foundation
import Combine
import UIKit

/// Cloud Apple Intelligence service using Shortcuts app integration
/// EXACT implementation adapted from the example codebase
class CloudModelService: ObservableObject {
    
    // MARK: - Properties
    
    private var currentRequestType: AppleIntelligenceRequestType?
    private var currentRequestCompletion: ((String) -> Void)?
    private var clipboardTimer: Timer?
    private var requestTimeoutTimer: Timer?
    private var clipboardCheckCount = 0
    private let maxClipboardChecks = 24 // 2 minutes at 5-second intervals
    private let requestTimeoutSeconds = 120 // 2 minutes timeout
    private var isRequestInProgress = false // Prevent multiple concurrent requests
    private let requestQueue = DispatchQueue(label: "cloudModelServiceQueue", qos: .userInitiated)
    var shortcutName: String = "RSS Reader Cloud Summary"
    
    // MARK: - Public Interface
    
    /// Launch cloud request via URL scheme to run shortcut without requiring AppleScript authorization
    @MainActor
    func launchCloudRequest(for text: String, type: AppleIntelligenceRequestType, completion: ((String) -> Void)?) {
        // Prevent multiple concurrent requests
        guard !isRequestInProgress else {
            NSLog("⚠️ CloudModelService: Request already in progress, ignoring new request")
            completion?("Cloud AI service is busy processing another request. Please wait.")
            return
        }
        
        isRequestInProgress = true
        
        // Store the request type and completion handler
        self.currentRequestType = type
        self.currentRequestCompletion = { [weak self] response in
            // Reset request in progress flag when completion is called
            self?.isRequestInProgress = false
            completion?(response)
        }
        
        // Use regular 'run-shortcut' URL to avoid custom callback scheme errors
        let encodedText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let trimmedShortcut = shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedShortcut.isEmpty else {
            NSLog("⚠️ CloudModelService: Shortcut name is empty")
            currentRequestCompletion?("Please enter a Shortcut name before sending a request.")
            isRequestInProgress = false
            return
        }
        let encodedShortcut = trimmedShortcut.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "shortcuts://run-shortcut?name=\(encodedShortcut)&input=text&text=\(encodedText)"
        guard let url = URL(string: urlString) else {
            NSLog("⚠️ CloudModelService: Could not create run-shortcut URL")
            currentRequestCompletion?("Cloud AI service temporarily unavailable. Please check Shortcuts app.")
            isRequestInProgress = false
            return
        }
        
        NSLog("📱 CloudModelService: Using run-shortcut on iOS")
        UIApplication.shared.open(url, options: [:]) { success in
            if success {
                NSLog("✅ CloudModelService: Successfully launched shortcut")
                self.startClipboardMonitoring(for: type)
            } else {
                NSLog("⚠️ CloudModelService: run-shortcut launch failed")
                self.currentRequestCompletion?("Could not launch Shortcuts app. Please check if Shortcuts is installed.")
                self.isRequestInProgress = false
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func startClipboardMonitoring(for type: AppleIntelligenceRequestType) {
        // Ensure proper timer cleanup and creation
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        clipboardCheckCount = 0
        
        // Cancel any existing timeout timer
        requestTimeoutTimer?.invalidate()
        requestTimeoutTimer = nil
        
        // Store the original clipboard content
        let originalClipboard = UIPasteboard.general.string ?? ""
        let originalClipboardChangeCount = UIPasteboard.general.changeCount
        
        NSLog("📋 CloudModelService: Starting clipboard monitoring for Apple Intelligence response (\(type))...")
        NSLog("📋 CLIPBOARD DEBUG: Original clipboard content: '\(String(originalClipboard.prefix(100)))...' (length: \(originalClipboard.count), changeCount: \(originalClipboardChangeCount))")
        
        // Start timeout timer
        requestTimeoutTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(requestTimeoutSeconds), repeats: false) { [weak self] _ in
            guard let self = self else { return }
            NSLog("⏱️ CloudModelService: Request timed out after \(self.requestTimeoutSeconds)s")
            self.clipboardTimer?.invalidate()
            self.clipboardTimer = nil
            self.currentRequestCompletion?("Cloud AI service timed out. Please try again.")
            self.isRequestInProgress = false
        }
        
        createClipboardTimer(
            originalClipboard: originalClipboard,
            originalClipboardChangeCount: originalClipboardChangeCount
        )
    }
    
    private func createClipboardTimer(
        originalClipboard: String,
        originalClipboardChangeCount: Int
    ) {
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            self.clipboardCheckCount += 1
            
            let currentClipboard = UIPasteboard.general.string ?? ""
            let currentClipboardChangeCount = UIPasteboard.general.changeCount
            let trimmed = currentClipboard.trimmingCharacters(in: .whitespacesAndNewlines)
            let textChanged = currentClipboard != originalClipboard
            let changeCountChanged = currentClipboardChangeCount != originalClipboardChangeCount
            
            NSLog("📋 CLIPBOARD CHECK #\(self.clipboardCheckCount): length=\(currentClipboard.count), textChanged=\(textChanged), changeCountChanged=\(changeCountChanged), changeCount=\(currentClipboardChangeCount))")
            
            if (textChanged || changeCountChanged), !trimmed.isEmpty {
                NSLog("✅ CloudModelService: Clipboard updated with response")
                timer.invalidate()
                self.clipboardTimer = nil
                self.requestTimeoutTimer?.invalidate()
                self.requestTimeoutTimer = nil
                self.currentRequestCompletion?(currentClipboard)
            } else if self.clipboardCheckCount >= self.maxClipboardChecks {
                NSLog("⚠️ CloudModelService: Max clipboard checks reached")
                timer.invalidate()
                self.clipboardTimer = nil
                self.requestTimeoutTimer?.invalidate()
                self.requestTimeoutTimer = nil
                self.currentRequestCompletion?("No response received from Shortcuts within the expected time.")
            }
        }
        RunLoop.main.add(clipboardTimer!, forMode: .common)
    }
}
