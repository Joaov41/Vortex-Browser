import SwiftUI

/// Search field at the top of the tab sidebar. ⌘K focuses it on iPad.
struct BrowserTabSearchField: View {
    @Binding var searchText: String
    var isFocused: FocusState<Bool>.Binding
    var showsShortcutHint = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("Search tabs…", text: $searchText)
                .focused(isFocused)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .accessibilityLabel("Search open tabs")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 32, height: 44)
                .accessibilityLabel("Clear tab search")
            } else if showsShortcutHint {
                Text("⌘ K")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5)
                    )
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture {
            isFocused.wrappedValue = true
        }
    }
}

struct TabGroupManagerSheet: View {
    @ObservedObject var viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var groupName = ""
    @State private var groupBeingRenamed: BrowserTabGroup?
    @State private var showingNamePrompt = false

    var body: some View {
        NavigationStack {
            List {
                if viewModel.tabGroups.isEmpty {
                    ContentUnavailableView(
                        "No Tab Groups",
                        systemImage: "folder",
                        description: Text("Create a group to organize related tabs.")
                    )
                } else {
                    ForEach(viewModel.tabGroups) { group in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.title).font(.headline)
                                Text("\(viewModel.tabs.filter { $0.groupID == group.id }.count) tabs")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Button("Rename", systemImage: "pencil") {
                                    groupBeingRenamed = group
                                    groupName = group.title
                                    showingNamePrompt = true
                                }
                                Button("Delete Group", systemImage: "trash", role: .destructive) {
                                    viewModel.deleteTabGroup(group)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Options for \(group.title)")
                        }
                    }
                }
            }
            .navigationTitle("Tab Groups")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        groupBeingRenamed = nil
                        groupName = ""
                        showingNamePrompt = true
                    } label: {
                        Label("New Group", systemImage: "folder.badge.plus")
                    }
                }
            }
            .alert(groupBeingRenamed == nil ? "New Tab Group" : "Rename Tab Group", isPresented: $showingNamePrompt) {
                TextField("Group name", text: $groupName)
                Button("Cancel", role: .cancel) {}
                Button(groupBeingRenamed == nil ? "Create" : "Save") {
                    if let group = groupBeingRenamed {
                        viewModel.renameTabGroup(group, title: groupName)
                    } else {
                        viewModel.createTabGroup(title: groupName)
                    }
                }
                .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
