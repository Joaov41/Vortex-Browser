import SwiftUI
import UniformTypeIdentifiers

struct BrowserSettingsView: View {
    @ObservedObject var vm: BrowserViewModel
    let isChatGPTSignedIn: Bool
    let isGeminiSignedIn: Bool
    let webAIStatusMessage: String?
    @Binding var isLoadingMLXModel: Bool
    @Binding var mlxDownloadProgress: Progress?
    @Binding var mlxLoadError: String?
    let onSignIn: (WebAIProvider) -> Void
    let onSignOut: (WebAIProvider) -> Void
    let onFontSizeChanged: () -> Void
    /// Model id plus destination folder; a nil folder downloads into app storage.
    let onDownloadMLXModel: (String, URL?) -> Void
    let onCancelMLXDownload: () -> Void
    let onAppear: () -> Void
    let onDone: () -> Void

    @ObservedObject private var blocker = UBlockLiteService.shared
    @ObservedObject private var cookieBlocker = ThirdPartyCookieBlocker.shared
    @ObservedObject private var darkModeService = DarkModeService.shared
    @ObservedObject private var fontSizeService = FontSizeService.shared
    @AppStorage("requestDesktopSite") private var requestDesktopSite = false
    @AppStorage(BrowserSpotlightSettings.bookmarksKey) private var spotlightBookmarks = true
    @AppStorage(BrowserSpotlightSettings.savedTasksKey) private var spotlightSavedTasks = true
    @AppStorage(BrowserSpotlightSettings.historyKey) private var spotlightHistory = false
    @State private var showBookmarkImporter = false
    @State private var bookmarkImportMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    generalSection
                    privacySection
                    spotlightSection
                    appearanceSection
                    aiSection
                    advancedSection
                }
                // Translucent rows so the panel's glass shows through; the Form's
                // default solid backgrounds hid it completely.
                .listRowBackground(Color.primary.opacity(0.06))
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .onAppear(perform: onAppear)
    }

    private var generalSection: some View {
        Section {
            Picker(selection: $vm.defaultSearchEngine) {
                ForEach(BrowserSearchEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            } label: {
                Label("Search Engine", systemImage: "magnifyingglass")
            }
            Picker(selection: $vm.newTabPage) {
                ForEach(NewTabPage.allCases) { page in
                    Text(page.displayName).tag(page)
                }
            } label: {
                Label("New Tabs Open", systemImage: "plus.square.on.square")
            }
            if vm.newTabPage == .custom {
                TextField("Page address, e.g. news.ycombinator.com", text: $vm.customNewTabAddress)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
            }
            Toggle(isOn: $requestDesktopSite) {
                Label("Request Desktop Site", systemImage: "desktopcomputer")
            }
            Button {
                showBookmarkImporter = true
            } label: {
                Label("Import Bookmarks…", systemImage: "square.and.arrow.down")
            }
            .fileImporter(isPresented: $showBookmarkImporter, allowedContentTypes: [.html, .zip]) { result in
                switch result {
                case .success(let url):
                    do {
                        bookmarkImportMessage = try vm.importBookmarks(fromFileAt: url).message
                    } catch {
                        bookmarkImportMessage = error.localizedDescription
                    }
                case .failure(let error):
                    bookmarkImportMessage = error.localizedDescription
                }
            }
            .alert(
                "Import Bookmarks",
                isPresented: Binding(
                    get: { bookmarkImportMessage != nil },
                    set: { if !$0 { bookmarkImportMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(bookmarkImportMessage ?? "")
            }
        } header: {
            Text("General")
        } footer: {
            if vm.newTabPage == .custom && vm.customNewTabURL == nil {
                Text("Enter a web address. Until then, new tabs open \(vm.defaultSearchEngine.displayName).")
            } else {
                Text("The search engine is used for searches typed in the address bar.")
            }
        }
    }

    private var privacySection: some View {
        Section {
            UBlockLiteControls()
            Toggle(isOn: $cookieBlocker.isEnabled) {
                Label("Block Third-Party Cookies", systemImage: "shield.lefthalf.filled")
            }
            .disabled(!cookieBlocker.isSupported)
            // uBlock's own lists live behind "uBlock Origin Lite Settings" above;
            // the built-in blocker's lists open here, inside Settings.
            if blocker.engine == .vortex {
                NavigationLink {
                    FilterListSettingsView()
                } label: {
                    Label("Filter Lists", systemImage: "list.bullet.rectangle")
                }
            }
        } header: {
            Text("Privacy & Blocking")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if blocker.engine == .ublockLite {
                    Text("Use the shield in the toolbar to turn blocking off for a site.")
                }
                if !cookieBlocker.isSupported {
                    Text(cookieBlocker.unavailabilityReason)
                }
            }
        }
    }

    private var spotlightSection: some View {
        Section {
            Toggle("Bookmarks", isOn: $spotlightBookmarks)
                .onChange(of: spotlightBookmarks) { _, _ in
                    BrowserSpotlightIndexer.shared.settingChanged(.bookmarks)
                }
            Toggle("Saved browser tasks", isOn: $spotlightSavedTasks)
                .onChange(of: spotlightSavedTasks) { _, _ in
                    BrowserSpotlightIndexer.shared.settingChanged(.savedTasks)
                }
            Toggle("History", isOn: $spotlightHistory)
                .onChange(of: spotlightHistory) { _, _ in
                    BrowserSpotlightIndexer.shared.settingChanged(.history)
                }
        } header: {
            Text("Spotlight")
        } footer: {
            Text("Private browsing is never shown in Spotlight.")
        }
    }

    private var appearanceSection: some View {
        Section("Appearance") {
            Toggle(isOn: $darkModeService.isDarkMode) {
                Label("Dark Web Pages", systemImage: darkModeService.isDarkMode ? "moon.fill" : "moon")
            }
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent {
                    Text("\(Int(fontSizeService.baseFontSize)) pt")
                } label: {
                    Label("Page Text Size", systemImage: "textformat.size")
                }
                HStack {
                    Image(systemName: "textformat.size.smaller")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Slider(value: $fontSizeService.baseFontSize, in: 10...24, step: 1) { _ in
                        onFontSizeChanged()
                    }
                    .accessibilityLabel("Page text size")
                    .accessibilityValue("\(Int(fontSizeService.baseFontSize)) points")
                    Image(systemName: "textformat.size.larger")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var aiSection: some View {
        Section {
            webAIAccountRow(for: .chatgpt, isSignedIn: isChatGPTSignedIn)
            webAIAccountRow(for: .gemini, isSignedIn: isGeminiSignedIn)
            NavigationLink {
                AgentSitePermissionsView()
            } label: {
                Label("Agent Site Permissions", systemImage: "hand.raised")
            }
            NavigationLink {
                AutofillProfileSettingsView(service: .shared)
            } label: {
                Label("Autofill Profile", systemImage: "person.text.rectangle")
            }
        } header: {
            Text("AI Accounts")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in inside Vortyra so the in-app ChatGPT and Gemini assistants reuse your session.")
                if let webAIStatusMessage, !webAIStatusMessage.isEmpty {
                    Text(webAIStatusMessage)
                }
            }
        }
    }

    private func webAIAccountRow(for provider: WebAIProvider, isSignedIn: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                Label(
                    isSignedIn ? "Signed in" : "Not signed in",
                    systemImage: isSignedIn ? "checkmark.circle.fill" : "circle.dashed"
                )
                .font(.caption)
                .foregroundStyle(isSignedIn ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            }
            Spacer()
            if isSignedIn {
                Button("Sign Out", role: .destructive) {
                    onSignOut(provider)
                }
                .accessibilityLabel("Sign out of \(provider.displayName)")
            } else {
                Button("Sign In") {
                    onSignIn(provider)
                }
                .accessibilityLabel("Sign in to \(provider.displayName)")
            }
        }
        .buttonStyle(.borderless)
    }

    private var advancedSection: some View {
        Section("Advanced") {
            if ChatGPTPlanAvailability.isEnabled {
                NavigationLink {
                    ChatGPTPlanSettingsView()
                } label: {
                    Label("ChatGPT Plan", systemImage: "person.badge.key")
                }
            }
            NavigationLink {
                MLXAdvancedSettingsView(
                    isLoadingModel: $isLoadingMLXModel,
                    downloadProgress: $mlxDownloadProgress,
                    loadError: $mlxLoadError,
                    onDownload: onDownloadMLXModel,
                    onCancelDownload: onCancelMLXDownload
                )
            } label: {
                Label("On-Device Models (MLX)", systemImage: "cpu")
            }
        }
    }
}

private struct MLXAdvancedSettingsView: View {
    @Binding var isLoadingModel: Bool
    @Binding var downloadProgress: Progress?
    @Binding var loadError: String?
    let onDownload: (String, URL?) -> Void
    let onCancelDownload: () -> Void

    /// The active model: a Hugging Face id or an `external:<path>` folder.
    @AppStorage("mlxModelID") private var modelID: String = MLXLocalSettings.defaultModelID
    /// What the user is typing in "Add a Model"; kept apart from the active model so
    /// typing never switches (or downloads) a model and a download never overwrites it.
    @AppStorage("mlxDraftModelID") private var draftModelID: String = ""
    @AppStorage("mlxMaxOutputTokens") private var maxOutputTokens: Int = MLXLocalSettings.defaultMaxOutputTokens
    @AppStorage("mlxMaxContextTokens") private var maxContextTokens: Int = MLXLocalSettings.defaultMaxContextTokens
    @State private var showDownloadLocationPicker = false
    @State private var showModelManager = false
    @State private var isActiveModelDownloaded = false

    private var isAvailable: Bool { MLXLocalService.isAvailable() }

    private var activeModelID: String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? MLXLocalSettings.defaultModelID : trimmed
    }

    private var isActiveModelExternal: Bool {
        MLXModelStorage.isExternal(activeModelID)
    }

    private var activeModelName: String {
        guard isActiveModelExternal else { return activeModelID }
        let path = String(activeModelID.dropFirst("external:".count))
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var activeModelStatus: String {
        if isActiveModelExternal { return "Saved folder" }
        return isActiveModelDownloaded
            ? "Downloaded to Vortyra"
            : "Not downloaded yet. It downloads the first time you use it."
    }

    private var trimmedDraftID: String {
        draftModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canDownloadDraft: Bool {
        isAvailable && !isLoadingModel && !trimmedDraftID.isEmpty && !MLXModelStorage.isExternal(trimmedDraftID)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(activeModelName)
                        .font(.body)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(activeModelStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !isActiveModelExternal && !isActiveModelDownloaded {
                    Button {
                        onDownload(activeModelID, nil)
                    } label: {
                        Label("Download Now", systemImage: "arrow.down.circle")
                    }
                    .disabled(isLoadingModel || !isAvailable)
                }

                Button {
                    showModelManager = true
                } label: {
                    Label("Manage Models", systemImage: "folder")
                }
                .disabled(isLoadingModel || !isAvailable)

                Button {
                    loadError = nil
                    let id = activeModelID
                    Task {
                        await MLXLocalService.shared.unloadModel(modelID: id)
                    }
                } label: {
                    Label("Unload from Memory", systemImage: "memorychip")
                }
                .disabled(isLoadingModel || !isAvailable)
            } header: {
                Text("Active Model")
            } footer: {
                if !isAvailable {
                    Text("Requires the MLX packages and an Apple silicon device.")
                }
            }

            Section {
                TextField("Model ID", text: $draftModelID, prompt: Text(MLXLocalSettings.defaultModelID))
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .disabled(isLoadingModel)

                if isLoadingModel {
                    HStack(spacing: 12) {
                        if let downloadProgress {
                            ProgressView(downloadProgress)
                        } else {
                            ProgressView()
                            Text("Preparing download…")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        Button("Cancel", role: .cancel) {
                            onCancelDownload()
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Button {
                        onDownload(trimmedDraftID, nil)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .disabled(!canDownloadDraft)

                    Button {
                        showDownloadLocationPicker = true
                    } label: {
                        Label("Download to Folder…", systemImage: "folder.badge.plus")
                    }
                    .disabled(!canDownloadDraft)
                }
            } header: {
                Text("Add a Model")
            } footer: {
                Text("Paste an MLX model ID from Hugging Face. Download saves it in Vortyra so it works offline. Download to Folder saves it somewhere you choose, like iCloud Drive. The new model becomes the active model.")
            }

            Section("Generation") {
                Stepper(value: $maxOutputTokens, in: 64...512, step: 64) {
                    LabeledContent("Max Output Tokens", value: "\(maxOutputTokens)")
                }
                Stepper(value: $maxContextTokens, in: 0...8192, step: 512) {
                    LabeledContent("Context Tokens", value: maxContextTokens == 0 ? "Auto" : "\(maxContextTokens)")
                }
            }

            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(BrowserDesign.Tint.error)
                }
            }
        }
        .navigationTitle("On-Device Models")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refreshDownloadState)
        .onChange(of: modelID) { _, newValue in
            refreshDownloadState()
            // A finished download switches the active model; clear the field so
            // the next model starts from an empty entry.
            let draft = trimmedDraftID
            if !draft.isEmpty, newValue == draft || newValue.hasSuffix("/models/\(draft)") {
                draftModelID = ""
            }
        }
        .onChange(of: isLoadingModel) { _, _ in
            refreshDownloadState()
        }
        .sheet(isPresented: $showModelManager) {
            ManageMLXModelsView(selectedModelID: $modelID)
        }
        .fileImporter(
            isPresented: $showDownloadLocationPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    onDownload(trimmedDraftID, url)
                }
            case .failure(let error):
                loadError = error.localizedDescription
            }
        }
    }

    private func refreshDownloadState() {
        isActiveModelDownloaded = MLXModelStorage.isDownloaded(modelID: activeModelID)
    }
}
