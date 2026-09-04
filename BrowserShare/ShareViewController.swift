import UIKit
import Social
import UniformTypeIdentifiers

final class ShareViewController: SLComposeServiceViewController {

    static let appGroupID = "group.com.browser.app"
    static let notificationName = "com.browser.sharedURL"
    private var didStart = false
    private var hasCompleted = false
    private var hasFinishedExtensionRequest = false
    private var completionTimer: DispatchSourceTimer?
    private var openFallbackTimer: DispatchSourceTimer?
    private var pendingOpenURL: URL?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startIfNeeded()
    }

    override func didSelectPost() {
        startIfNeeded()
    }

    override func isContentValid() -> Bool {
        true
    }

    override func configurationItems() -> [Any]! {
        []
    }

    private func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        scheduleCompletionTimeout()
        processContent()
    }

    private func processContent() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            complete()
            return
        }

        let providers = items.flatMap { $0.attachments ?? [] }
        guard let (provider, typeID) = selectProvider(from: providers) else {
            complete()
            return
        }

        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] object, _ in
                let content = object?.absoluteString
                DispatchQueue.main.async {
                    if let content {
                        self?.handleSharedContent(content)
                    }
                    self?.complete()
                }
            }
            return
        }

        if provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { [weak self] object, _ in
                let content = object
                DispatchQueue.main.async {
                    if let content {
                        self?.handleSharedContent(content)
                    }
                    self?.complete()
                }
            }
            return
        }

        provider.loadItem(forTypeIdentifier: typeID, options: nil) { [weak self] data, _ in
            let content = Self.contentString(from: data)
            DispatchQueue.main.async {
                guard let self else { return }
                if let content {
                    self.handleSharedContent(content)
                }
                self.complete()
            }
        }
    }

    nonisolated private static func contentString(from item: NSSecureCoding?) -> String? {
        if let url = item as? URL {
            return url.absoluteString
        }
        if let string = item as? String {
            return string
        }
        if let attributed = item as? NSAttributedString {
            return attributed.string
        }
        if let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    private func selectProvider(from providers: [NSItemProvider]) -> (NSItemProvider, String)? {
        if let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) {
            return (provider, UTType.url.identifier)
        }

        if let provider = providers.first(where: { $0.canLoadObject(ofClass: String.self) }) {
            return (provider, UTType.plainText.identifier)
        }

        let typeIDs = [UTType.url.identifier, UTType.plainText.identifier, UTType.text.identifier]
        for typeID in typeIDs {
            if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(typeID) }) {
                return (provider, typeID)
            }
        }

        return nil
    }

    private func handleSharedContent(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let defaults = UserDefaults(suiteName: Self.appGroupID) {
            defaults.set(trimmed, forKey: "sharedURL")
            defaults.synchronize()
        }

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.notificationName as CFString),
            nil, nil, true
        )

        pendingOpenURL = makeOpenURL()
    }

    private func makeOpenURL() -> URL? {
        var components = URLComponents()
        components.scheme = "webmebrowser"
        components.host = "share"
        return components.url
    }

    private func scheduleCompletionTimeout() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 12.0)
        timer.setEventHandler { [weak self] in
            self?.complete()
        }
        completionTimer = timer
        timer.resume()
    }

    private func complete() {
        guard !hasCompleted else { return }
        hasCompleted = true
        completionTimer?.cancel()
        completionTimer = nil
        guard let context = extensionContext else { return }
        guard let urlToOpen = pendingOpenURL else {
            finishExtensionRequest()
            return
        }

        // Ask the extension host to open the app before ending the request. The
        // shared payload remains in the app group if the host declines, so the
        // app can consume it on its next ordinary launch.
        scheduleOpenFallback()
        context.open(urlToOpen) { [weak self] _ in
            DispatchQueue.main.async {
                self?.finishExtensionRequest()
            }
        }
    }

    private func scheduleOpenFallback() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2.0)
        timer.setEventHandler { [weak self] in
            self?.finishExtensionRequest()
        }
        openFallbackTimer = timer
        timer.resume()
    }

    private func finishExtensionRequest() {
        guard !hasFinishedExtensionRequest else { return }
        hasFinishedExtensionRequest = true
        openFallbackTimer?.cancel()
        openFallbackTimer = nil
        extensionContext?.completeRequest(returningItems: nil)
    }
}
