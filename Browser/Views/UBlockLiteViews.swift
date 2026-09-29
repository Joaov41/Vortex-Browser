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

/// Shown inside a List/Form, so each control is its own row. When several
/// controls share one row, a tap anywhere in it fires the first one (the picker).
struct UBlockLiteControls: View {
    @ObservedObject private var blocker = UBlockLiteService.shared
    var body: some View {
        Group {
            Picker("Ad Blocker", selection: Binding(get: { blocker.engine }, set: { blocker.select($0) })) {
                ForEach(UBlockLiteService.Engine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .disabled(blocker.isChanging)
            if blocker.isChanging {
                LabeledContent("Changing blocker…") { ProgressView() }
            }
            if blocker.engine == .ublockLite {
                NavigationLink("Filter Lists & Options") {
                    UBlockLiteFilterListsView()
                }
            }
            if let error = blocker.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
        // Buttons only respond to taps on themselves, not the whole row.
        .buttonStyle(.borderless)
    }
}

/// Every list that feeds the blocker in one place: uBlock's own lists and network
/// rules, plus the HaGeZi Pro list Vortex applies alongside them.
struct UBlockLiteFilterListsView: View {
    @ObservedObject private var blocker = UBlockLiteService.shared

    var body: some View {
        Form {
            Group {
                Section {
                    Button {
                        blocker.showSettings()
                    } label: {
                        LabeledContent {
                            Image(systemName: "arrow.up.forward.square")
                                .foregroundStyle(.secondary)
                        } label: {
                            Text("Choose Filter Lists")
                        }
                    }
                    .tint(.primary)
                    if blocker.loadsFromPackageStore {
                        UBlockLiteRulesUpdateControls(blocker: blocker)
                    }
                } header: {
                    Text("uBlock Origin Lite")
                } footer: {
                    Text("Filter lists and other options open in uBlock Origin Lite \(blocker.version).")
                }
                Section {
                    ExtraBlocklistControls()
                } header: {
                    Text("Extra Blocklist")
                } footer: {
                    Text("HaGeZi Pro adds ad, tracker and malware domains on top of uBlock's lists. It is off on sites where you turn uBlock off.")
                }
            }
            .listRowBackground(Color.primary.opacity(0.06))
        }
        .scrollContentBackground(.hidden)
        .buttonStyle(.borderless)
        .navigationTitle("Filter Lists & Options")
        .navigationBarTitleDisplayMode(.inline)
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
        Group {
            LabeledContent {
                if updater.phase != .idle {
                    ProgressView()
                } else {
                    Text(blocker.rulesVersion)
                }
            } label: {
                Text("Network Rules")
                if let lastCheck = updater.lastCheck {
                    Text("Checked \(lastCheck.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            if let pendingVersion, updater.phase == .idle {
                Button("Install \(pendingVersion) and Reload Tabs") {
                    Task { await blocker.applyRulesUpdate() }
                }
                .disabled(blocker.isChanging)
            } else if let release = updater.availableRelease {
                Button("Download \(release.tag) (\(release.size / 1_048_576) MB)") {
                    Task { await updater.downloadAndStage() }
                }
                .disabled(updater.phase != .idle)
            } else {
                Button("Check for Updates") {
                    Task { await updater.check() }
                }
                .disabled(updater.phase != .idle || blocker.isChanging)
            }
            if let status = updater.statusMessage {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

/// The HaGeZi Pro extra blocklist: on/off, status, and a manual update.
struct ExtraBlocklistControls: View {
    @ObservedObject private var blocklist = ExtraBlocklistService.shared

    var body: some View {
        Group {
            Toggle(isOn: $blocklist.isEnabled) {
                Text("HaGeZi Pro Blocklist")
                if blocklist.version != nil {
                    Text("\(blocklist.blockedDomains.formatted()) extra domains")
                }
            }
            if let available = blocklist.availableVersion, blocklist.phase == .idle {
                Button("Install HaGeZi Pro \(available)") {
                    Task { await blocklist.downloadAndApply() }
                }
            } else {
                Button {
                    Task { await blocklist.check() }
                } label: {
                    LabeledContent("Check for Blocklist Update") {
                        if blocklist.phase != .idle { ProgressView() }
                    }
                }
                .disabled(blocklist.phase != .idle)
            }
            if let status = blocklist.statusMessage {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
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
