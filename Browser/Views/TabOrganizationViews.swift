import SwiftUI

struct BrowserTabOrganizerHeader: View {
    @Binding var searchText: String
    @Binding var selectedScope: BrowserTabScope
    let groups: [BrowserTabGroup]
    let recentlyClosedCount: Int
    let onManageGroups: () -> Void
    let onShowRecentlyClosed: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search tabs", text: $searchText)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .accessibilityLabel("Search open tabs")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Clear tab search")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, searchText.isEmpty ? 12 : 0)
            .frame(minHeight: 44)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: 8) {
                Menu {
                    Button {
                        selectedScope = .all
                    } label: {
                        Label("All Tabs", systemImage: selectedScope == .all ? "checkmark" : "rectangle.stack")
                    }
                    Button {
                        selectedScope = .ungrouped
                    } label: {
                        Label("Ungrouped", systemImage: selectedScope == .ungrouped ? "checkmark" : "tray")
                    }
                    if !groups.isEmpty { Divider() }
                    ForEach(groups) { group in
                        Button {
                            selectedScope = .group(group.id)
                        } label: {
                            Label(
                                group.title,
                                systemImage: selectedScope == .group(group.id) ? "checkmark" : "folder"
                            )
                        }
                    }
                } label: {
                    Label(scopeTitle, systemImage: "folder")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel("Tab group: \(scopeTitle)")

                Button(action: onManageGroups) {
                    Image(systemName: "folder.badge.gearshape")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel("Manage tab groups")

                Button(action: onShowRecentlyClosed) {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "clock.arrow.circlepath")
                        if recentlyClosedCount > 0 {
                            Text("\(min(recentlyClosedCount, 99))")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(Color.accentColor, in: Capsule())
                                .offset(x: 8, y: -7)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel("Recently closed tabs, \(recentlyClosedCount)")
            }
        }
    }

    private var scopeTitle: String {
        switch selectedScope {
        case .all: return "All Tabs"
        case .ungrouped: return "Ungrouped"
        case .group(let id): return groups.first(where: { $0.id == id })?.title ?? "All Tabs"
        }
    }
}

struct RecentlyClosedTabsSheet: View {
    @ObservedObject var viewModel: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.recentlyClosedTabs.isEmpty {
                    ContentUnavailableView(
                        "No Recently Closed Tabs",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Tabs you close will appear here, except private tabs.")
                    )
                } else {
                    List(viewModel.recentlyClosedTabs) { record in
                        Button {
                            viewModel.reopenRecentlyClosed(record)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.title).font(.headline).lineLimit(1)
                                Text(record.url.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(record.closedAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Reopens this tab")
                    }
                }
            }
            .navigationTitle("Recently Closed")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
                if !viewModel.recentlyClosedTabs.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Clear", role: .destructive, action: viewModel.clearRecentlyClosed)
                    }
                }
            }
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
