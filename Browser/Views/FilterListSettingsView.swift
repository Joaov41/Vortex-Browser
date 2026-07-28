import SwiftUI

struct FilterListSettingsView: View {
    @ObservedObject var adBlockService = AdBlockService.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showAddList = false
    @State private var showAddRule = false
    @State private var newListName = ""
    @State private var newListURL = ""
    @State private var newCustomRule = ""

    var body: some View {
        if horizontalSizeClass == .compact {
            filterListContent
                .listStyle(.insetGrouped)
        } else {
            filterListContent
                .listStyle(.plain)
        }
    }

    private var filterListContent: some View {
        List {
            // MARK: - Ad Blocking Toggle
            Section {
                Toggle("Enable Ad Blocking", isOn: $adBlockService.isEnabled)
            } header: {
                Text("Ad Blocker")
            } footer: {
                Text("Blocks ads, trackers, and annoyances across websites")
            }

            // MARK: - Statistics
            Section {
                HStack {
                    Text("Ads Blocked This Session")
                    Spacer()
                    Text("\(adBlockService.blockedCount)")
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Statistics")
            }

            // MARK: - Filter Lists
            Section {
                ForEach(adBlockService.filterLists) { list in
                    FilterListRow(list: list)
                }
                .onDelete(perform: deleteFilterList)

                Button(action: { showAddList = true }) {
                    Label("Add Filter List", systemImage: "plus.circle")
                }

                Button {
                    Task {
                        await adBlockService.clearCacheAndRecompile()
                    }
                } label: {
                    Label("Clear Cache & Recompile", systemImage: "arrow.clockwise")
                        .foregroundColor(.orange)
                }
                .disabled(adBlockService.isUpdatingFilters)
            } header: {
                HStack {
                    Text("Filter Lists")
                    Spacer()
                    if adBlockService.isUpdatingFilters {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Button("Update All") {
                            Task {
                                await adBlockService.updateAllFilterLists()
                            }
                        }
                        .font(.caption)
                    }
                }
            } footer: {
                Text("Filter lists contain rules to block ads and trackers. Use 'Clear Cache & Recompile' if blocking seems inconsistent.")
            }

            // MARK: - Custom Rules
            Section {
                ForEach(adBlockService.customRules, id: \.self) { rule in
                    Text(rule)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                }
                .onDelete(perform: deleteCustomRule)

                Button(action: { showAddRule = true }) {
                    Label("Add Custom Rule", systemImage: "plus.circle")
                }
            } header: {
                Text("Custom Rules")
            } footer: {
                Text("Add custom URL patterns to block. Use regex patterns like 'example\\.com/ads/.*'")
            }

            // MARK: - Preset Lists
            Section {
                PresetListRow(
                    name: "EasyList",
                    description: "Primary ad blocking list",
                    url: "https://easylist.to/easylist/easylist.txt"
                )
                PresetListRow(
                    name: "EasyPrivacy",
                    description: "Tracking protection",
                    url: "https://easylist.to/easylist/easyprivacy.txt"
                )
                PresetListRow(
                    name: "Fanboy's Annoyance",
                    description: "Blocks popups, banners, newsletters",
                    url: "https://easylist.to/easylist/fanboy-annoyance.txt"
                )
                PresetListRow(
                    name: "uBlock Filters",
                    description: "Additional uBlock Origin filters",
                    url: "https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters/filters.txt"
                )
                PresetListRow(
                    name: "Peter Lowe's List",
                    description: "Ad and tracking server list",
                    url: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=0"
                )
            } header: {
                Text("Available Filter Lists")
            } footer: {
                Text("Enable these lists in the Filter Lists section above. More lists = better blocking but may slow page loading slightly.")
            }
        }
        .navigationTitle("Ad Blocker Settings")
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .toolbarBackground(.hidden, for: .navigationBar)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showAddList) {
            AddFilterListSheet(
                isPresented: $showAddList,
                name: $newListName,
                url: $newListURL,
                onAdd: {
                    if !newListName.isEmpty && !newListURL.isEmpty {
                        adBlockService.addFilterList(name: newListName, url: newListURL)
                        newListName = ""
                        newListURL = ""
                    }
                }
            )
        }
        .sheet(isPresented: $showAddRule) {
            AddCustomRuleSheet(
                isPresented: $showAddRule,
                rule: $newCustomRule,
                onAdd: {
                    if !newCustomRule.isEmpty {
                        adBlockService.addCustomRule(newCustomRule)
                        newCustomRule = ""
                    }
                }
            )
        }
    }

    private func deleteFilterList(at offsets: IndexSet) {
        for index in offsets {
            let list = adBlockService.filterLists[index]
            adBlockService.removeFilterList(list)
        }
    }

    private func deleteCustomRule(at offsets: IndexSet) {
        for index in offsets {
            let rule = adBlockService.customRules[index]
            adBlockService.removeCustomRule(rule)
        }
    }
}

// MARK: - Filter List Row
struct FilterListRow: View {
    let list: FilterList
    @ObservedObject var adBlockService = AdBlockService.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(list.name)
                    .font(.headline)

                HStack(spacing: 8) {
                    if list.ruleCount > 0 {
                        Text("\(list.ruleCount) rules")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let lastUpdated = list.lastUpdated {
                        Text("Updated \(lastUpdated, style: .relative) ago")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { list.isEnabled },
                set: { _ in adBlockService.toggleFilterList(list) }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
    }
}

// MARK: - Preset List Row
struct PresetListRow: View {
    let name: String
    let description: String
    let url: String
    @ObservedObject var adBlockService = AdBlockService.shared

    var isEnabled: Bool {
        adBlockService.filterLists.contains { $0.url == url && $0.isEnabled }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isEnabled {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
        .listRowBackground(Color.clear)
    }
}

// MARK: - Add Filter List Sheet
struct AddFilterListSheet: View {
    @Binding var isPresented: Bool
    @Binding var name: String
    @Binding var url: String
    let onAdd: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("List Name", text: $name)
                    TextField("URL", text: $url)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                } header: {
                    Text("Filter List Details")
                } footer: {
                    Text("Enter the URL of an AdBlock Plus compatible filter list (e.g., EasyList format)")
                }
            }
            .navigationTitle("Add Filter List")
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd()
                        isPresented = false
                    }
                    .disabled(name.isEmpty || url.isEmpty)
                }
            }
        }
    }
}

// MARK: - Add Custom Rule Sheet
struct AddCustomRuleSheet: View {
    @Binding var isPresented: Bool
    @Binding var rule: String
    let onAdd: () -> Void

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("URL Pattern", text: $rule)
                        .autocapitalization(.none)
                        .font(.system(.body, design: .monospaced))
                } header: {
                    Text("Custom Blocking Rule")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Examples:")
                            .font(.caption.bold())
                        Text("• ads\\.example\\.com")
                        Text("• example\\.com/ads/.*")
                        Text("• tracking\\..*\\.com")
                    }
                    .font(.caption)
                }
            }
            .navigationTitle("Add Custom Rule")
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        onAdd()
                        isPresented = false
                    }
                    .disabled(rule.isEmpty)
                }
            }
        }
    }
}

#Preview {
    NavigationView {
        FilterListSettingsView()
    }
}
