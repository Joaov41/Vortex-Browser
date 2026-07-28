import SwiftUI
import Foundation
import UniformTypeIdentifiers

struct ManageMLXModelsView: View {
    @Binding var selectedModelID: String
    @Environment(\.dismiss) private var dismiss

    @State private var errorMessage: String? = nil
    @State private var showFolderPicker = false
    @State private var externalModels: [ModelItem] = []
    @State private var cachedModels: [ModelItem] = []

    private struct ModelItem: Identifiable {
        let id: String
        let name: String
        let path: String
        let source: String
        let isSelected: Bool
    }

    private var selectedPath: String? {
        let prefix = "external:"
        if selectedModelID.lowercased().hasPrefix(prefix) {
            return String(selectedModelID.dropFirst(prefix.count))
        }
        if selectedModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return MLXExternalModelStore.selectedPath()
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let modelPath = selectedPath, !modelPath.isEmpty {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(URL(fileURLWithPath: modelPath).lastPathComponent)
                                    .font(.body)
                                Text("Selected")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button(role: .destructive) {
                                clearSelection()
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        Text("No model selected")
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        showFolderPicker = true
                    } label: {
                        Label("Select Model from Files", systemImage: "folder.badge.plus")
                    }
                } header: {
                    Text("Selected Model")
                } footer: {
                    Text("Select a model folder from iCloud Drive, local storage, or external drives. Use \"Download Model\" in Settings to download new models to your preferred location.")
                }

                if !externalModels.isEmpty {
                    Section {
                        ForEach(externalModels) { model in
                            modelRow(model)
                        }
                        .onDelete { indices in
                            for index in indices {
                                let model = externalModels[index]
                                MLXExternalModelStore.removeEntry(path: model.path)
                            }
                            reloadModels()
                        }
                    } header: {
                        Text("Saved Models")
                    } footer: {
                        Text("Models you added or downloaded to custom locations. Swipe to remove from the list (files are not deleted).")
                    }
                }

                if !cachedModels.isEmpty {
                    Section {
                        ForEach(cachedModels) { model in
                            modelRow(model)
                        }
                    } header: {
                        Text("Downloaded Models")
                    } footer: {
                        Text("Models found in the app's Hugging Face cache.")
                    }
                }
            }
            .navigationTitle("Manage MLX Models")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                reloadModels()
            }
            .onChange(of: selectedModelID) { _ in
                reloadModels()
            }
            .fileImporter(
                isPresented: $showFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                handleFolderSelection(result)
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "Unknown error.")
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ model: ModelItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(.body)
                Text(model.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.isSelected {
                Text("Selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Use") {
                    selectModel(model)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func reloadModels() {
        let external = loadExternalModels()
        let externalPaths = Set(external.map(\.path))
        externalModels = external
        cachedModels = loadCachedModels(excluding: externalPaths)
    }

    private func loadExternalModels() -> [ModelItem] {
        let selected = selectedPath
        return MLXExternalModelStore.loadEntries().map { entry in
            ModelItem(
                id: "external:\(entry.path)",
                name: entry.name,
                path: entry.path,
                source: "Saved",
                isSelected: entry.path == selected
            )
        }
    }

    private func loadCachedModels(excluding externalPaths: Set<String>) -> [ModelItem] {
        let selected = selectedPath
        return discoverCachedModels()
            .filter { !externalPaths.contains($0.path) }
            .map { model in
            ModelItem(
                id: "external:\(model.path)",
                name: model.name,
                path: model.path,
                source: "Downloaded",
                isSelected: model.path == selected
            )
        }
    }

    private func selectModel(_ model: ModelItem) {
        let prefix = "external:"
        selectedModelID = "\(prefix)\(model.path)"
        let bookmark = MLXExternalModelStore.bookmark(for: model.path)
        MLXExternalModelStore.addEntry(path: model.path, bookmark: bookmark)
        MLXExternalModelStore.setSelected(path: model.path, bookmark: bookmark)
        reloadModels()
    }

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Cannot access the selected folder"
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let configPath = url.appending(path: "config.json")
            guard FileManager.default.fileExists(atPath: configPath.path) else {
                errorMessage = "Invalid model folder: missing config.json. Please select the folder containing the model files."
                return
            }

            do {
                #if os(iOS)
                let bookmarkData = try url.bookmarkData(options: .minimalBookmark)
                #else
                let bookmarkData = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess])
                #endif
                MLXExternalModelStore.addEntry(path: url.path, bookmark: bookmarkData)
                MLXExternalModelStore.setSelected(path: url.path, bookmark: bookmarkData)
                selectedModelID = "external:\(url.path)"
                reloadModels()
            } catch {
                errorMessage = "Failed to save folder bookmark: \(error.localizedDescription)"
            }

        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func clearSelection() {
        MLXExternalModelStore.clearSelection()
        selectedModelID = ""
        reloadModels()
    }

    private func discoverCachedModels() -> [ModelItem] {
        guard let baseURL = cachedModelsBaseURL(),
              FileManager.default.fileExists(atPath: baseURL.path) else {
            return []
        }

        let baseDepth = baseURL.pathComponents.count
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: baseURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }

        var models: [String: (url: URL, modified: Date?)] = [:]

        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - baseDepth
            if depth > 7 {
                enumerator.skipDescendants()
                continue
            }

            guard url.lastPathComponent == "config.json" else { continue }
            let modelDir = url.deletingLastPathComponent()
            let modelID = cachedModelID(from: modelDir)
            let modified = (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate)
            if let existing = models[modelID], let existingDate = existing.modified, let modified {
                if modified <= existingDate { continue }
            }
            models[modelID] = (modelDir, modified)
        }

        let selected = selectedPath
        return models.map { key, value in
            ModelItem(
                id: "external:\(value.url.path)",
                name: key,
                path: value.url.path,
                source: "Downloaded",
                isSelected: value.url.path == selected
            )
        }
        .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private func cachedModelsBaseURL() -> URL? {
        #if os(macOS)
        return URL.homeDirectory.appendingPathComponent(".cache/huggingface/hub")
        #else
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("huggingface")
        #endif
    }

    private func cachedModelID(from url: URL) -> String {
        let components = url.pathComponents
        if let idx = components.firstIndex(where: { $0.hasPrefix("models--") }) {
            let raw = components[idx].replacingOccurrences(of: "models--", with: "")
            return raw.replacingOccurrences(of: "--", with: "/")
        }
        return url.lastPathComponent
    }
}
