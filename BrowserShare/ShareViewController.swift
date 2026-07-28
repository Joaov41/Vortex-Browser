import UIKit
import Social
import UniformTypeIdentifiers

final class ShareViewController: SLComposeServiceViewController {

    static let appGroupID = "group.com.browser.app"
    static let notificationName = "com.browser.sharedURL"
    private var didStart = false
    private var hasCompleted = false
    private var completionTimer: DispatchSourceTimer?
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
            provider.loadObject(ofClass: URL.self) { [weak self] object, _ in
                if let url = object as? URL {
                    self?.handleSharedContent(url.absoluteString)
                }
                self?.complete()
            }
            return
        }

        if provider.canLoadObject(ofClass: String.self) {
            provider.loadObject(ofClass: String.self) { [weak self] object, _ in
                if let text = object as? String {
                    self?.handleSharedContent(text)
                }
                self?.complete()
            }
            return
        }

        provider.loadItem(forTypeIdentifier: typeID, options: nil) { [weak self] data, _ in
            guard let self else { return }
            var content: String?
            if let url = data as? URL {
                content = url.absoluteString
            } else if let str = data as? String {
                content = str
            } else if let attributed = data as? NSAttributedString {
                content = attributed.string
            } else if let data = data as? Data, let str = String(data: data, encoding: .utf8) {
                content = str
            }

            if let content {
                self.handleSharedContent(content)
            }
            self.complete()
        }
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
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 2.0)
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
        let urlToOpen = pendingOpenURL
        extensionContext?.completeRequest(returningItems: nil) { [weak self] _ in
            guard let self, let url = urlToOpen else { return }
            DispatchQueue.main.async {
                self.openURL(url)
            }
        }
    }

    private func openURL(_ url: URL) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias OpenURLType = @convention(c) (AnyObject, Selector, URL, [UIApplication.OpenExternalURLOptionsKey: Any], ((Bool) -> Void)?) -> Void
                let openURL = unsafeBitCast(application.method(for: selector), to: OpenURLType.self)
                openURL(application, selector, url, [:], nil)
                return
            }
            responder = current.next
        }
    }
}
