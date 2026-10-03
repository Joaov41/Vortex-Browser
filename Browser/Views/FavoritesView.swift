import SwiftUI
import UniformTypeIdentifiers

/// Favorites organised in folders, with bookmark import. Opened from the
/// sidebar's Favorites section, either at the top level or inside a folder.
struct FavoritesView: View {
    @ObservedObject var viewModel: BrowserViewModel
    let onOpen: (Favorite) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: [UUID]

    init(viewModel: BrowserViewModel, startFolderID: UUID? = nil, onOpen: @escaping (Favorite) -> Void) {
        self.viewModel = viewModel
        self.onOpen = onOpen
        // Push every folder from the top down to the requested one, so Back works.
        var ancestry: [UUID] = []
        var current = viewModel.favoriteFolder(id: startFolderID)
        while let folder = current, !ancestry.contains(folder.id) {
            ancestry.insert(folder.id, at: 0)
            current = viewModel.favoriteFolder(id: folder.parentID)
        }
        _path = State(initialValue: ancestry)
    }

    var body: some View {
        NavigationStack(path: $path) {
            FavoritesFolderList(viewModel: viewModel, folderID: nil, onOpen: open, onDone: { dismiss() })
                .navigationDestination(for: UUID.self) { folderID in
                    FavoritesFolderList(viewModel: viewModel, folderID: folderID, onOpen: open, onDone: { dismiss() })
                }
        }
    }

    private func open(_ favorite: Favorite) {
        onOpen(favorite)
        dismiss()
    }
}

/// Identifies which Favorites screen to present from the sidebar.
struct FavoritesSheetRequest: Identifiable {
    let id = UUID()
    let folderID: UUID?
}

private struct FavoritesFolderList: View {
    @ObservedObject var viewModel: BrowserViewModel
    let folderID: UUID?
    let onOpen: (Favorite) -> Void
    let onDone: () -> Void

    private enum FolderNameTarget: Equatable {
        case new
        case rename(UUID)
        case renameFavorite(UUID)
    }

    @State private var searchText = ""
    @State private var folderNameTarget: FolderNameTarget?
    @State private var folderNameText = ""
    @State private var folderPendingDeletion: FavoriteFolder?
    @State private var showImporter = false
    @State private var importMessage: String?

    private var folder: FavoriteFolder? { viewModel.favoriteFolder(id: folderID) }
    private var subfolders: [FavoriteFolder] { viewModel.favoriteFolders(inFolder: folderID) }
    private var favorites: [Favorite] { viewModel.favorites(inFolder: folderID) }

    private var searchResults: [Favorite] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return viewModel.favorites.filter {
            $0.title.lowercased().contains(needle) || $0.url.absoluteString.lowercased().contains(needle)
        }
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            if isSearching {
                ForEach(searchResults) { favorite in
                    favoriteRow(favorite, showsFolder: true)
                }
            } else {
                if !subfolders.isEmpty {
                    Section {
                        ForEach(subfolders) { subfolder in
                            folderRow(subfolder)
                        }
                    }
                }
                if !favorites.isEmpty {
                    Section {
                        ForEach(favorites) { favorite in
                            favoriteRow(favorite, showsFolder: false)
                        }
                    }
                }
            }
        }
        .overlay { emptyState }
        .searchable(text: $searchText, prompt: "Search Favorites")
        .navigationTitle(folder?.title ?? "Favorites")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: onDone)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        folderNameText = ""
                        folderNameTarget = .new
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import Bookmarks…", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
            }
        }
        .alert(
            folderNameAlertTitle,
            isPresented: Binding(
                get: { folderNameTarget != nil },
                set: { if !$0 { folderNameTarget = nil } }
            )
        ) {
            TextField("Name", text: $folderNameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveFolderName() }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { folderPendingDeletion != nil },
                set: { if !$0 { folderPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if let folderPendingDeletion {
                    viewModel.deleteFavoriteFolder(folderPendingDeletion.id)
                }
                folderPendingDeletion = nil
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.html, .zip]) { result in
            switch result {
            case .success(let url):
                do {
                    importMessage = try viewModel.importBookmarks(fromFileAt: url).message
                } catch {
                    importMessage = error.localizedDescription
                }
            case .failure(let error):
                importMessage = error.localizedDescription
            }
        }
        .alert(
            "Import Bookmarks",
            isPresented: Binding(
                get: { importMessage != nil },
                set: { if !$0 { importMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importMessage ?? "")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if isSearching && searchResults.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if !isSearching && subfolders.isEmpty && favorites.isEmpty {
            if folderID == nil {
                ContentUnavailableView {
                    Label("No Favorites", systemImage: "star")
                } description: {
                    Text("Touch and hold a tab and choose Add to Favorites, or import bookmarks exported from another browser.")
                } actions: {
                    Button("Import Bookmarks…") { showImporter = true }
                }
            } else {
                ContentUnavailableView(
                    "Empty Folder",
                    systemImage: "folder",
                    description: Text("Touch and hold a favorite and choose Move to Folder to put it here.")
                )
            }
        }
    }

    private func folderRow(_ subfolder: FavoriteFolder) -> some View {
        let count = viewModel.favoriteCount(inFolderTree: subfolder.id)
        return NavigationLink(value: subfolder.id) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.body)
                    .foregroundStyle(BrowserDesign.Tint.favorite)
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                Text(subfolder.title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(count) \(count == 1 ? "favorite" : "favorites")")
            }
            .frame(minHeight: 44)
        }
        .contextMenu {
            Button {
                folderNameText = subfolder.title
                folderNameTarget = .rename(subfolder.id)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            moveMenu(current: subfolder.parentID, excluding: viewModel.favoriteFolderTree(subfolder.id)) { destination in
                viewModel.moveFavoriteFolder(subfolder.id, toFolder: destination)
            }
            Divider()
            Button(role: .destructive) {
                folderPendingDeletion = subfolder
            } label: {
                Label("Delete Folder", systemImage: "trash")
            }
        }
        .swipeActions {
            Button("Delete", role: .destructive) {
                folderPendingDeletion = subfolder
            }
        }
    }

    private func favoriteRow(_ favorite: Favorite, showsFolder: Bool) -> some View {
        Button {
            onOpen(favorite)
        } label: {
            FavoriteRow(
                favorite: favorite,
                folderPath: showsFolder ? favorite.folderID.map(viewModel.favoriteFolderPath) : nil
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                folderNameText = favorite.title
                folderNameTarget = .renameFavorite(favorite.id)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            moveMenu(current: favorite.folderID, excluding: []) { destination in
                viewModel.moveFavorite(favorite, toFolder: destination)
            }
            Divider()
            Button(role: .destructive) {
                viewModel.removeFromFavorites(favorite)
            } label: {
                Label("Remove Favorite", systemImage: "trash")
            }
        }
        .swipeActions {
            Button("Delete", role: .destructive) {
                viewModel.removeFromFavorites(favorite)
            }
        }
    }

    private func moveMenu(current: UUID?, excluding: Set<UUID>, move: @escaping (UUID?) -> Void) -> some View {
        Menu {
            Button("Top Level") { move(nil) }
                .disabled(current == nil)
            ForEach(viewModel.favoriteFolderPaths.filter { !excluding.contains($0.id) }) { item in
                Button(item.path) { move(item.id) }
                    .disabled(item.id == current)
            }
        } label: {
            Label("Move to Folder", systemImage: "folder")
        }
    }

    private var folderNameAlertTitle: String {
        switch folderNameTarget {
        case .new: return "New Folder"
        case .rename: return "Rename Folder"
        case .renameFavorite: return "Rename Favorite"
        case nil: return ""
        }
    }

    private var deletionTitle: String {
        guard let folderPendingDeletion else { return "" }
        let count = viewModel.favoriteCount(inFolderTree: folderPendingDeletion.id)
        return count == 0
            ? "Delete “\(folderPendingDeletion.title)”?"
            : "Delete “\(folderPendingDeletion.title)” and the \(count) \(count == 1 ? "favorite" : "favorites") in it?"
    }

    private func saveFolderName() {
        switch folderNameTarget {
        case .new:
            viewModel.createFavoriteFolder(named: folderNameText, in: folderID)
        case .rename(let id):
            viewModel.renameFavoriteFolder(id, to: folderNameText)
        case .renameFavorite(let id):
            if let favorite = viewModel.favorites.first(where: { $0.id == id }) {
                viewModel.renameFavorite(favorite, to: folderNameText)
            }
        case nil:
            break
        }
        folderNameTarget = nil
    }
}

/// One favorite: favicon (or initial), title and domain.
private struct FavoriteRow: View {
    let favorite: Favorite
    let folderPath: String?

    private var domain: String {
        guard var host = favorite.url.host else { return favorite.url.absoluteString }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let data = favorite.favicon, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 22, height: 22)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                } else {
                    Text(String(domain.prefix(1)).uppercased())
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 30, height: 30)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(favorite.title.isEmpty ? domain : favorite.title)
                    .font(.body)
                    .lineLimit(1)
                Text(folderPath.map { "\($0) · \(domain)" } ?? domain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
