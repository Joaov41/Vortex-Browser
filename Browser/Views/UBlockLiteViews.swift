import SwiftUI
import WebKit

struct UBlockLiteRootView: View {
    @ObservedObject private var blocker = UBlockLiteService.shared
    var body: some View {
        Group {
            if blocker.isReady {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ubol-probe") {
                    UBlockLiteProbeView()
                } else {
                    ContentView()
                }
                #else
                ContentView()
                #endif
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Starting Vortex Browser")
                    Text("Loading uBlock Origin Lite…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task { await blocker.prepare() }
    }
}

struct UBlockLiteControls: View {
    @ObservedObject private var blocker = UBlockLiteService.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Ad blocker", selection: Binding(get: { blocker.engine }, set: { blocker.select($0) })) {
                ForEach(UBlockLiteService.Engine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .disabled(blocker.isChanging)
            if blocker.isChanging { ProgressView("Changing blocker…") }
            if blocker.engine == .ublockLite {
                Button("uBlock Origin Lite Settings", systemImage: "slider.horizontal.3") { blocker.showSettings() }
                    .frame(minHeight: 44)
                Text("Use the page’s shield button for uBlock’s site controls. Lite can read and modify webpages to filter ads. Private tabs use a separate temporary extension profile.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = blocker.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if blocker.engine == .ublockLite, blocker.loadsFromPackageStore {
                UBlockLiteRulesUpdateControls(blocker: blocker)
            }
            if blocker.engine == .ublockLite {
                ExtraBlocklistControls()
            }
            Text("Vortex Browser · uBOL \(blocker.version)" + (blocker.rulesVersion == blocker.version ? "" : " · rules \(blocker.rulesVersion)"))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Manual network-rules updates: a daily availability check, then download and apply only on request.
struct UBlockLiteRulesUpdateControls: View {
    @ObservedObject var blocker: UBlockLiteService
    @ObservedObject private var updater: UBOLRulesUpdater

    init(blocker: UBlockLiteService) {
        self.blocker = blocker
        updater = blocker.rulesUpdater
    }

    private var pendingVersion: String? { blocker.packageStore.loadState()?.pendingRulesVersion }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button("Check for network rule updates", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await updater.check() }
                }
                .disabled(updater.phase != .idle || blocker.isChanging)
                if updater.phase != .idle { ProgressView().controlSize(.small) }
            }
            if let release = updater.availableRelease {
                Button("Download network rules \(release.tag) (\(release.size / 1_048_576) MB)", systemImage: "arrow.down.circle") {
                    Task { await updater.downloadAndStage() }
                }
                .disabled(updater.phase != .idle)
            }
            if let pendingVersion, updater.phase == .idle {
                Button("Apply network rules \(pendingVersion) now (reloads open tabs)", systemImage: "checkmark.circle") {
                    Task { await blocker.applyRulesUpdate() }
                }
                .disabled(blocker.isChanging)
            }
            if let status = updater.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let lastCheck = updater.lastCheck {
                Text("Last check: \(lastCheck.formatted(date: .abbreviated, time: .shortened)). Network rules only: cosmetic filters and page scripts stay at uBOL \(blocker.version) until the app is updated.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Checks GitHub for new uBlock Origin Lite releases once a day. Downloads and applying happen only when you tap. Network rules only: cosmetic filters and page scripts stay at uBOL \(blocker.version) until the app is updated.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
    }
}

/// The HaGeZi Pro extra blocklist: on/off, status, and a manual update.
struct ExtraBlocklistControls: View {
    @ObservedObject private var blocklist = ExtraBlocklistService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Extra blocklist: HaGeZi Pro", isOn: $blocklist.isEnabled)
            if let version = blocklist.version {
                Text("\(blocklist.blockedDomains.formatted()) domains · version \(version)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Check for blocklist update", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await blocklist.check() }
                }
                .disabled(blocklist.phase != .idle)
                if blocklist.phase != .idle { ProgressView().controlSize(.small) }
            }
            if let available = blocklist.availableVersion, blocklist.phase == .idle {
                Button("Download and apply HaGeZi Pro \(available)", systemImage: "arrow.down.circle") {
                    Task { await blocklist.downloadAndApply() }
                }
            }
            if let status = blocklist.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text("Blocks ad, tracker and malware domains that uBlock Origin Lite's lists don't cover. Pages you open yourself are never blocked, only what they load. Turned off on sites where you turn off uBlock.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .buttonStyle(.bordered)
    }
}

@MainActor
final class UBlockLitePanelController: UIViewController {
    let webView: WKWebView
    let action: WKWebExtension.Action?
    init(title: String, webView: WKWebView, action: WKWebExtension.Action?) {
        self.webView = webView
        self.action = action
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = UIView()
        view.backgroundColor = .systemBackground
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true || isMovingFromParent {
            action?.closePopup()
            UBlockLiteService.shared.panelDidClose()
        }
    }
}

extension UBlockLiteService {
    var isPresentingPanel: Bool { openPanels > 0 }

    func panelDidClose() {
        openPanels = max(0, openPanels - 1)
        filteringModesMayChange()
    }

    func present(title: String, webView: WKWebView, action: WKWebExtension.Action? = nil) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var presenter = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let next = presenter.presentedViewController { presenter = next }
        let panel = UBlockLitePanelController(title: title, webView: webView, action: action)
        openPanels += 1
        filteringModesMayChange()
        if let navigation = presenter as? UINavigationController, navigation.viewControllers.first is UBlockLitePanelController {
            navigation.pushViewController(panel, animated: true)
        } else {
            let navigation = UINavigationController(rootViewController: panel)
            navigation.modalPresentationStyle = .pageSheet
            navigation.sheetPresentationController?.detents = [.large()]
            presenter.present(navigation, animated: true)
        }
    }
}
