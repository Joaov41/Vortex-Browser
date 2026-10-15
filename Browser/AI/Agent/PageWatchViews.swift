import SwiftUI

/// A page the user asked to watch from the page menu. A new value is made for each request, so the sheet always presents.
struct PageWatchDraft: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let title: String
}

/// One request to open a stored page watch in the library. Opening the same watch again still presents.
struct AgentWatchOpenRequest: Identifiable, Equatable {
    let id = UUID()
    let watchID: UUID
}

extension PageWatchCoordinator.RecordedResult {
    /// The one-line message shown after Check Now.
    func statusMessage(for title: String) -> String {
        switch self {
        case .baseline: return "Recorded the first reading of \(title)."
        case .unchanged: return "\(title) has not changed."
        case .changed: return "\(title) changed."
        case .failed(let message): return message
        case .skipped(let reason): return reason
        case .missing: return PageWatchURLParser.missingWatchMessage
        }
    }
}

/// Creates a page watch for the current page, or edits an existing one.
struct PageWatchEditorView: View {
    let url: URL
    let existing: PageWatch?
    var onSaved: (PageWatch) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var titleText: String
    @State private var interval: PageWatchInterval
    @State private var notify: Bool
    @State private var selectorText: String
    @State private var useSavedTask: Bool
    @State private var selectedTaskID: UUID?
    @State private var savedTasks: [SavedAgentTask] = []
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(url: URL, title: String, existing: PageWatch?, onSaved: @escaping (PageWatch) -> Void = { _ in }) {
        self.url = url
        self.existing = existing
        self.onSaved = onSaved
        _titleText = State(initialValue: existing?.title ?? title)
        _interval = State(initialValue: existing?.interval ?? .daily)
        _notify = State(initialValue: existing?.notify ?? true)
        switch existing?.mode {
        case .text(let selector):
            _selectorText = State(initialValue: selector ?? "")
            _useSavedTask = State(initialValue: false)
            _selectedTaskID = State(initialValue: nil)
        case .agent(let savedTaskID):
            _selectorText = State(initialValue: "")
            _useSavedTask = State(initialValue: true)
            _selectedTaskID = State(initialValue: savedTaskID)
        case nil:
            _selectorText = State(initialValue: "")
            _useSavedTask = State(initialValue: false)
            _selectedTaskID = State(initialValue: nil)
        }
    }

    private var isEditing: Bool { existing != nil }

    private var canSave: Bool {
        !titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Page") {
                    LabeledContent("Address") {
                        Text(url.host ?? url.absoluteString)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    TextField("Title", text: $titleText)
                        .textInputAutocapitalization(.sentences)
                }
                Section("Schedule") {
                    Picker("Check", selection: $interval) {
                        ForEach(PageWatchInterval.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    Toggle("Notify when it changes", isOn: $notify)
                }
                if !useSavedTask {
                    Section {
                        DisclosureGroup("Advanced") {
                            TextField("CSS selector (optional)", text: $selectorText)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Text("Compare only the element that matches this selector. Leave it empty to compare the page's main text.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Toggle("Run a saved task instead", isOn: $useSavedTask)
                    if useSavedTask {
                        if savedTasks.isEmpty {
                            Text("Save a browser task first, then choose it here.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Saved task", selection: $selectedTaskID) {
                                ForEach(savedTasks) { task in
                                    Text(task.title).tag(Optional(task.id))
                                }
                            }
                        }
                        Text("A saved task runs only while Vortyra is open. Its result is compared, not the page.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button(isEditing ? "Save Changes" : "Watch Page") {
                        save()
                    }
                    .disabled(!canSave)
                }
            }
            .navigationTitle(isEditing ? "Edit Watch" : "Watch This Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                savedTasks = Self.loadSavedTasks()
                if selectedTaskID == nil {
                    selectedTaskID = savedTasks.first?.id
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private static func loadSavedTasks() -> [SavedAgentTask] {
        guard let store = try? AgentTaskIntentRuntime.makeStore() else { return [] }
        do {
            try store.load()
            return store.savedTasks
        } catch {
            return []
        }
    }

    private func save() {
        let title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            errorMessage = "Give this watch a title."
            return
        }
        let mode: PageWatchMode
        if useSavedTask {
            guard let selectedTaskID else {
                errorMessage = "Choose a saved task, or turn off Run a saved task instead."
                return
            }
            mode = .agent(savedTaskID: selectedTaskID)
        } else {
            let selector = PageWatch.normalizedSelector(selectorText)
            guard selector.map({ $0.count <= PageWatch.maximumSelectorCharacters }) ?? true else {
                errorMessage = "The CSS selector is too long."
                return
            }
            mode = .text(selector: selector)
        }

        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            await PageWatchCoordinator.shared.prepareNotifications(for: notify)
            do {
                if let existing {
                    let updated = try PageWatchCoordinator.shared.editWatch(
                        id: existing.id,
                        title: title,
                        interval: interval,
                        notify: notify,
                        mode: mode
                    )
                    onSaved(updated)
                } else {
                    let created = PageWatch(
                        title: String(title.prefix(PageWatch.maximumTitleCharacters)),
                        url: url,
                        mode: mode,
                        interval: interval,
                        notify: notify
                    )
                    try PageWatchCoordinator.shared.createWatch(created)
                    onSaved(created)
                }
                errorMessage = nil
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// One row in the Watches tab of the agent task library.
struct PageWatchRow: View {
    let watch: PageWatch
    let isChecking: Bool
    let onCheck: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(watch.title)
                .font(.headline)
                .lineLimit(2)
            Label(watch.url.host ?? watch.url.absoluteString, systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 3) {
                Text(modeDescription)
                if let lastChecked = watch.lastCheckedAt {
                    Text("Last checked \(lastChecked, style: .relative)")
                } else {
                    Text("Not checked yet")
                }
                if let lastChange = watch.lastChangeAt {
                    Text("Last change \(lastChange, style: .relative)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let lastError = watch.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            HStack {
                Button(action: onCheck) {
                    if isChecking {
                        ProgressView()
                    } else {
                        Label("Check Now", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isChecking)
                Button("Edit", action: onEdit)
                    .buttonStyle(.bordered)
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 5)
    }

    private var modeDescription: String {
        let cadence = watch.interval.title
        switch watch.mode {
        case .text(let selector):
            return selector == nil ? "Page text, \(cadence.lowercased())" : "Selected element, \(cadence.lowercased())"
        case .agent:
            return "Saved task, \(cadence.lowercased())"
        }
    }
}
