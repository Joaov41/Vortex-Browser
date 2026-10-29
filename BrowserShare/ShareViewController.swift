import UIKit
import Social
import UniformTypeIdentifiers

final class ShareViewController: SLComposeServiceViewController {

    static let appGroupID = "group.com.browser.app"
    static let notificationName = "com.browser.sharedURL"
    private var didStart = false
    private let deliveryGate = BrowserShareDeliveryGate()
    private var completionTimer: DispatchSourceTimer?
    private var openFallbackTimer: DispatchSourceTimer?
    private var pendingOpenURL: URL?
    private var sharedProviders: [NSItemProvider] = []

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
        sharedProviders = providers
        let descriptors = providers.enumerated().map { index, provider in
            BrowserShareProviderPicker.Descriptor(
                index: index,
                typeIdentifiers: providerTypeIdentifiers(of: provider)
            )
        }
        switch BrowserShareProviderPicker.select(descriptors) {
        case .textProvider(let index):
            loadTextItem(providers[index])
        case .urlProvider(let index):
            loadURLItem(providers[index])
        case .legacy(let index, let typeID):
            loadLegacyItem(providers[index], typeID: typeID)
        case .none:
            if let attributed = items.lazy
                .compactMap({ $0.attributedContentText?.string })
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                handleSharedText(attributed)
                return
            }
            complete()
        }
    }

    private func handleSharedText(_ content: String?) {
        guard deliveryGate.acceptsCallbacks else { return }
        let trimmed = (content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fallbackToURLProvider()
            return
        }
        guard trimmed.utf8.count <= BrowserIntentShareParser.maximumTextUTF8Bytes else {
            showTextAlert(
                title: "Text Too Long",
                message: "The shared text is longer than 4096 bytes, so it was not sent to Vortyra."
            )
            return
        }

        completionTimer?.cancel()
        completionTimer = nil

        let alert = UIAlertController(title: "Vortyra", message: nil, preferredStyle: .actionSheet)
        if BrowserSharePayload.actions(for: trimmed).contains(.openLink) {
            alert.addAction(UIAlertAction(title: "Open Link", style: .default) { [weak self] _ in
                self?.finishWithURLPayload(trimmed)
            })
        }
        alert.addAction(UIAlertAction(title: "Search with Vortyra", style: .default) { [weak self] _ in
            self?.finishWithSearchPayload(trimmed)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            self?.complete()
        })
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(alert, animated: true)
    }

    private func showTextAlert(title: String, message: String) {
        guard deliveryGate.acceptsCallbacks else { return }
        completionTimer?.cancel()
        completionTimer = nil
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.complete()
        })
        present(alert, animated: true)
    }

    private func finishWithSearchPayload(_ text: String) {
        guard deliveryGate.acceptsCallbacks else { return }
        if let defaults = UserDefaults(suiteName: Self.appGroupID) {
            do {
                _ = try BrowserSharePayload.writeSearchTextIfAllowed(
                    text,
                    to: defaults,
                    gate: deliveryGate
                )
            } catch {
                showTextAlert(
                    title: "Text Too Long",
                    message: "The shared text is empty or too long, so it was not sent to Vortyra."
                )
                return
            }
        }
        postShareNotification()
        pendingOpenURL = makeOpenURL()
        complete()
    }

    private func finishWithURLPayload(_ content: String) {
        guard deliveryGate.acceptsCallbacks else { return }
        if let defaults = UserDefaults(suiteName: Self.appGroupID) {
            BrowserSharePayload.writeSharedURL(content, to: defaults)
        }
        postShareNotification()
        pendingOpenURL = makeOpenURL()
        complete()
    }

    private func handleSharedContent(_ content: String) {
        guard deliveryGate.acceptsCallbacks else { return }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let defaults = UserDefaults(suiteName: Self.appGroupID) {
            BrowserSharePayload.writeSharedURL(trimmed, to: defaults)
        }

        postShareNotification()

        pendingOpenURL = makeOpenURL()
    }

    private func postShareNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.notificationName as CFString),
            nil, nil, true
        )
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
        guard !deliveryGate.hasCompleted else { return }
        deliveryGate.markCompleted()
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
        guard !deliveryGate.hasFinishedRequest else { return }
        deliveryGate.markRequestFinished()
        openFallbackTimer?.cancel()
        openFallbackTimer = nil
        extensionContext?.completeRequest(returningItems: nil)
    }
}

private extension ShareViewController {
    private func providerTypeIdentifiers(of provider: NSItemProvider) -> Set<String> {
        var identifiers = Set(provider.registeredTypeIdentifiers)
        for typeID in [UTType.url.identifier, UTType.plainText.identifier, UTType.text.identifier]
        where provider.hasItemConformingToTypeIdentifier(typeID) {
            identifiers.insert(typeID)
        }
        return identifiers
    }

    private func loadTextItem(_ provider: NSItemProvider) {
        let typeID = provider.registeredTypeIdentifiers.first(where: {
            $0 == UTType.plainText.identifier || $0 == UTType.text.identifier
        }) ?? UTType.plainText.identifier
        provider.loadItem(forTypeIdentifier: typeID, options: nil) { [weak self] data, _ in
            let content = Self.contentString(from: data)
            DispatchQueue.main.async {
                guard let self, self.deliveryGate.acceptsCallbacks else { return }
                if let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.handleSharedText(content)
                } else {
                    self.fallbackToURLProvider()
                }
            }
        }
    }

    private func fallbackToURLProvider() {
        if let provider = sharedProviders.first(where: {
            providerTypeIdentifiers(of: $0).contains(UTType.url.identifier)
        }) {
            loadURLItem(provider)
        } else {
            showTextAlert(title: "Nothing to Search", message: "The shared text is empty.")
        }
    }

    private func loadURLItem(_ provider: NSItemProvider) {
        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] data, _ in
            let content = Self.contentString(from: data)
            DispatchQueue.main.async {
                guard let self, self.deliveryGate.acceptsCallbacks else { return }
                if let content {
                    self.handleSharedContent(content)
                }
                self.complete()
            }
        }
    }

    private func loadLegacyItem(_ provider: NSItemProvider, typeID: String) {
        provider.loadItem(forTypeIdentifier: typeID, options: nil) { [weak self] data, _ in
            let content = Self.contentString(from: data)
            DispatchQueue.main.async {
                guard let self, self.deliveryGate.acceptsCallbacks else { return }
                guard let content else {
                    self.complete()
                    return
                }
                if typeID == UTType.url.identifier {
                    self.handleSharedContent(content)
                    self.complete()
                } else {
                    self.handleSharedText(content)
                }
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
}
