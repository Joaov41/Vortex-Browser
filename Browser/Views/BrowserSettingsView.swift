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
    let onDownloadMLXModel: (URL) -> Void
    let onAppear: () -> Void
    let onDone: () -> Void

    @ObservedObject private var blocker = UBlockLiteService.shared
    @ObservedObject private var cookieBlocker = ThirdPartyCookieBlocker.shared
    @ObservedObject private var darkModeService = DarkModeService.shared
    @ObservedObject private var fontSizeService = FontSizeService.shared
    @AppStorage("requestDesktopSite") private var requestDesktopSite = false
    @State private var showBookmarkImporter = false
    @State private var bookmarkImportMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    generalSection
                    privacySection
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
        } header: {
            Text("AI Accounts")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in inside Vortex so the in-app ChatGPT and Gemini assistants reuse your session.")
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
                    onDownload: onDownloadMLXModel
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
    let onDownload: (URL) -> Void

    @AppStorage("mlxModelID") private var modelID: String = MLXLocalSettings.defaultModelID
    @AppStorage("mlxMaxOutputTokens") private var maxOutputTokens: Int = MLXLocalSettings.defaultMaxOutputTokens
    @AppStorage("mlxMaxContextTokens") private var maxContextTokens: Int = MLXLocalSettings.defaultMaxContextTokens
    @State private var showDownloadLocationPicker = false
    @State private var showModelManager = false

    private var isAvailable: Bool { MLXLocalService.isAvailable() }

    private var trimmedModelID: String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section {
                TextField("Model ID", text: $modelID, prompt: Text(MLXLocalSettings.defaultModelID))
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
            } header: {
                Text("Hugging Face Model")
            } footer: {
                Text("Paste any MLX model ID from Hugging Face.")
            }

            Section("Generation") {
                Stepper(value: $maxOutputTokens, in: 64...512, step: 64) {
                    LabeledContent("Max Output Tokens", value: "\(maxOutputTokens)")
                }
                Stepper(value: $maxContextTokens, in: 0...8192, step: 512) {
                    LabeledContent("Context Tokens", value: maxContextTokens == 0 ? "Auto" : "\(maxContextTokens)")
                }
            }

            Section {
                Button {
                    showDownloadLocationPicker = true
                } label: {
                    HStack {
                        Label("Download Model", systemImage: "arrow.down.circle")
                        if isLoadingModel {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isLoadingModel || !isAvailable || trimmedModelID.isEmpty)

                if let downloadProgress {
                    ProgressView(downloadProgress)
                }

                Button {
                    loadError = nil
                    downloadProgress = nil
                    let id = trimmedModelID
                    guard !id.isEmpty else { return }
                    Task {
                        await MLXLocalService.shared.unloadModel(modelID: id)
                    }
                } label: {
                    Label("Unload from Memory", systemImage: "memorychip")
                }
                .disabled(isLoadingModel || !isAvailable)

                Button {
                    showModelManager = true
                } label: {
                    Label("Manage Downloaded Models", systemImage: "folder")
                }
                .disabled(isLoadingModel || !isAvailable)
            } header: {
                Text("Model")
            } footer: {
                if !isAvailable {
                    Text("Requires the MLX packages and an Apple silicon device.")
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
                    onDownload(url)
                }
            case .failure(let error):
                loadError = error.localizedDescription
            }
        }
    }
}
