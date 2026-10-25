import SwiftUI

struct AgentTaskSaveDraft: Identifiable {
    let id = UUID()
    let replyID: UUID
    let task: String
    let startURL: URL?
    let title: String
    /// Recorded steps from teach mode. Nil for a draft that is not a recording.
    let recipe: [RecordedStep]?

    init(replyID: UUID, task: String, startURL: URL?, title: String? = nil, recipe: [RecordedStep]? = nil) {
        self.replyID = replyID
        self.task = task
        self.startURL = startURL
        self.recipe = recipe
        if let title {
            self.title = title
        } else {
            let words = task.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
            self.title = String((words.isEmpty ? "Browser task" : words).prefix(64))
        }
    }
}

/// Carries the requested library mode and its exact save draft in one sheet
/// presentation update, avoiding a first-render race between separate state.
/// One request to open a stored run's detail page. A new value is made for each link, so opening the same run again still presents.
struct AgentRunDetailRequest: Identifiable, Equatable {
    let id = UUID()
    let runID: UUID
}

enum AgentTaskLibraryPresentation: Identifiable {
    case browse(UUID)
    case save(AgentTaskSaveDraft)
    case run(AgentRunDetailRequest)
    case watch(AgentWatchOpenRequest)

    var id: UUID {
        switch self {
        case .browse(let id): id
        case .save(let draft): draft.id
        case .run(let request): request.id
        case .watch(let request): request.id
        }
    }

    var initialWatchID: UUID? {
        guard case .watch(let request) = self else { return nil }
        return request.watchID
    }

    var initialDraft: AgentTaskSaveDraft? {
        guard case .save(let draft) = self else { return nil }
        return draft
    }

    var initialRunID: UUID? {
        guard case .run(let request) = self else { return nil }
        return request.runID
    }
}

/// Keeps a save action attached to the exact assistant reply that produced the
/// completed agent run, even if newer chat messages arrive before the tap.
struct AgentTaskReplySaveAssociation: Equatable {
    let replyID: UUID
    let task: String
    let startURL: URL?

    func draft(for displayedReplyID: UUID) -> AgentTaskSaveDraft? {
        guard displayedReplyID == replyID else { return nil }
        return AgentTaskSaveDraft(replyID: replyID, task: task, startURL: startURL)
    }
}

struct AgentTaskLibrarySheet: View {
    let storeProvider: @MainActor @Sendable () throws -> AgentTaskStore
    let initialDraft: AgentTaskSaveDraft?
    let onRun: (AgentTaskLaunchRequest) -> Void
    let onSavedReply: (UUID) -> Void
    /// Opens this run's detail page on appear, when the sheet was requested from a `webmebrowser://run` link.
    var initialRunID: UUID? = nil
    /// Opens the Watches tab on this watch, when the sheet was requested from a `webmebrowser://watch` link.
    var initialWatchID: UUID? = nil
    /// Starts teach-mode recording on the current tab. Shown as "Record a New Task" when provided.
    var onRecordNewTask: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var savedTasks: [SavedAgentTask] = []
    @State private var history: [AgentRunRecord] = []
    @State private var pageWatches: [PageWatch] = []
    @State private var checkingWatchIDs: Set<UUID> = []
    @State private var editingWatch: PageWatch?
    @State private var selectedSection = 0
    @State private var showingEditor = false
    @State private var editingTask: SavedAgentTask?
    @State private var editorReplyID: UUID?
    @State private var titleText = ""
    @State private var taskText = ""
    @State private var startURLText = ""
    @State private var errorMessage: String?
    @State private var detailRecord: AgentRunRecord?
    @State private var libraryNotice: String?
    /// Recipe of the task being saved or edited. Kept so editing a recorded task does not drop its steps.
    @State private var editingRecipe: [RecordedStep]?
    /// True for a fresh recording: Cancel in its editor discards the recording and closes the sheet.
    @State private var discardsDraftOnCancel = false

    private var isEditingExistingTask: Bool { editingTask != nil }

    var body: some View {
        NavigationStack {
            Group {
                if showingEditor {
                    editor
                } else {
                    library
                }
            }
            .navigationDestination(item: $detailRecord) { record in
                AgentRunDetailView(
                    record: record,
                    onRunAgain: {
                        onRun(AgentTaskLaunchRequest(historyRecord: record))
                        dismiss()
                    },
                    onSaveAsTask: { prepareSaveFromRun(record) }
                )
            }
            .navigationTitle(showingEditor ? (isEditingExistingTask ? "Edit Task" : "Save Task") : "Agent Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(showingEditor ? "Cancel" : "Done") {
                        if showingEditor {
                            if discardsDraftOnCancel {
                                dismiss()
                                return
                            }
                            showingEditor = false
                            editingTask = nil
                            editorReplyID = nil
                            editingRecipe = nil
                        } else {
                            dismiss()
                        }
                    }
                }
                if !showingEditor {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            prepareNewTask()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("New saved task")
                    }
                }
            }
            .alert("Saved Tasks", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(item: $editingWatch) { watch in
                PageWatchEditorView(url: watch.url, title: watch.title, existing: watch) { _ in
                    reloadWatches()
                }
            }
            .onAppear {
                reload()
                reloadWatches()
                if let initialDraft {
                    titleText = initialDraft.title
                    taskText = initialDraft.task
                    startURLText = initialDraft.startURL?.absoluteString ?? ""
                    editorReplyID = initialDraft.replyID
                    editingRecipe = initialDraft.recipe
                    discardsDraftOnCancel = initialDraft.recipe != nil
                    showingEditor = true
                }
                if let initialRunID {
                    openRun(initialRunID)
                }
                if let initialWatchID {
                    openWatch(initialWatchID)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var library: some View {
        VStack(spacing: 0) {
            if let libraryNotice {
                Text(libraryNotice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 10)
            }
            Picker("Library", selection: $selectedSection) {
                Text("Tasks").tag(0)
                Text("History").tag(1)
                Text("Watches").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)

            List {
                if selectedSection == 0 {
                    if let onRecordNewTask {
                        Button {
                            dismiss()
                            onRecordNewTask()
                        } label: {
                            Label("Record a New Task", systemImage: "record.circle")
                        }
                    }
                    if savedTasks.isEmpty {
                        ContentUnavailableView("No Saved Tasks", systemImage: "checklist", description: Text("Save a finished agent run or create a task to reuse it."))
                            .listRowSeparator(.hidden)
                    }
                    ForEach(savedTasks) { task in
                        savedTaskRow(task)
                    }
                } else if selectedSection == 1 {
                    if history.isEmpty {
                        ContentUnavailableView("No Run History", systemImage: "clock.arrow.circlepath", description: Text("Completed regular agent runs appear here."))
                            .listRowSeparator(.hidden)
                    }
                    ForEach(history) { record in
                        historyRow(record)
                    }
                } else {
                    if pageWatches.isEmpty {
                        ContentUnavailableView("No Page Watches", systemImage: "eye", description: Text("Use Watch Page in the page menu to be told when a page changes."))
                            .listRowSeparator(.hidden)
                    }
                    ForEach(pageWatches) { watch in
                        PageWatchRow(
                            watch: watch,
                            isChecking: checkingWatchIDs.contains(watch.id),
                            onCheck: { checkWatch(watch) },
                            onEdit: { editingWatch = watch },
                            onDelete: { deleteWatch(watch) }
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private var editor: some View {
        Form {
            Section("Task details") {
                TextField("Title", text: $titleText)
                    .textInputAutocapitalization(.sentences)
                TextField("Instructions", text: $taskText, axis: .vertical)
                    .lineLimit(3...8)
                TextField("Starting website (optional)", text: $startURLText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button(isEditingExistingTask ? "Save Changes" : "Save Task") {
                    saveTask()
                }
                .disabled(titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func savedTaskRow(_ task: SavedAgentTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title)
                .font(.headline)
            Text(task.task)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            if let host = task.startURL?.host {
                Label(host, systemImage: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    onRun(AgentTaskLaunchRequest(savedTask: task))
                    dismiss()
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                Button("Edit") { prepareEdit(task) }
                    .buttonStyle(.bordered)
                Button("Delete", role: .destructive) { delete(task) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .padding(.vertical, 5)
    }

    private func historyRow(_ record: AgentRunRecord) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                detailRecord = record
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    Text(record.task)
                        .font(.headline)
                        .lineLimit(3)
                    Text(record.outcome)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                    HStack {
                        Text(record.date, style: .date)
                        Text("·")
                        Text(AIModelBackend(rawValue: record.backend)?.displayName ?? record.backend)
                        if let status = record.status, status != .completed {
                            Text("·")
                            Text(status.title)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack {
                Spacer()
                Button("Run Again") {
                    onRun(AgentTaskLaunchRequest(historyRecord: record))
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
    }

    /// Shows the Watches page on one watch. A watch that no longer exists gets a short notice instead.
    private func openWatch(_ watchID: UUID) {
        reloadWatches()
        if pageWatches.contains(where: { $0.id == watchID }) {
            libraryNotice = nil
            selectedSection = 2
        } else {
            libraryNotice = PageWatchURLParser.missingWatchMessage
        }
    }

    private func reloadWatches() {
        pageWatches = (try? PageWatchCoordinator.shared.watches()) ?? []
    }

    private func checkWatch(_ watch: PageWatch) {
        guard !checkingWatchIDs.contains(watch.id) else { return }
        checkingWatchIDs.insert(watch.id)
        Task { @MainActor in
            defer { checkingWatchIDs.remove(watch.id) }
            do {
                let result = try await PageWatchCoordinator.shared.checkWatch(id: watch.id)
                libraryNotice = result.statusMessage(for: watch.title)
            } catch {
                errorMessage = error.localizedDescription
            }
            reloadWatches()
        }
    }

    private func deleteWatch(_ watch: PageWatch) {
        do {
            try PageWatchCoordinator.shared.deleteWatch(id: watch.id)
            reloadWatches()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Shows the History page with one run's detail. A run that has left history gets a short notice instead.
    private func openRun(_ runID: UUID) {
        if let record = history.first(where: { $0.id == runID }) {
            libraryNotice = nil
            selectedSection = 1
            detailRecord = record
        } else {
            libraryNotice = AgentRunURLParser.missingRunMessage
        }
    }

    /// Opens the existing new-task editor with this run's task, replacing the detail page.
    private func prepareSaveFromRun(_ record: AgentRunRecord) {
        let draft = AgentTaskSaveDraft(replyID: record.id, task: record.task, startURL: record.startURL)
        detailRecord = nil
        editingTask = nil
        editorReplyID = nil
        editingRecipe = nil
        discardsDraftOnCancel = false
        titleText = draft.title
        taskText = record.task
        startURLText = record.startURL?.absoluteString ?? ""
        errorMessage = nil
        showingEditor = true
    }

    private func prepareNewTask() {
        editingTask = nil
        editorReplyID = nil
        editingRecipe = nil
        discardsDraftOnCancel = false
        titleText = ""
        taskText = ""
        startURLText = ""
        errorMessage = nil
        showingEditor = true
    }

    private func prepareEdit(_ task: SavedAgentTask) {
        editingTask = task
        editorReplyID = nil
        editingRecipe = task.recipe
        discardsDraftOnCancel = false
        titleText = task.title
        taskText = task.task
        startURLText = task.startURL?.absoluteString ?? ""
        errorMessage = nil
        showingEditor = true
    }

    private func saveTask() {
        let title = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let taskText = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        let startingAddress = startURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let startURL: URL?
        if startingAddress.isEmpty {
            startURL = nil
        } else if let url = URL(string: startingAddress), AgentTaskURLParser.isAllowedStartURL(url) {
            startURL = url
        } else {
            errorMessage = "Starting website must be an HTTP or HTTPS address."
            return
        }

        do {
            let store = try storeProvider()
            let saved = SavedAgentTask(
                id: editingTask?.id ?? UUID(),
                title: title,
                task: taskText,
                startURL: startURL,
                createdAt: editingTask?.createdAt ?? Date(),
                lastRunAt: editingTask?.lastRunAt,
                recipe: editingRecipe
            )
            if editingTask == nil {
                try store.saveTask(saved)
            } else {
                try store.updateTask(saved)
            }
            reload(using: store)
            AgentTaskShortcutMetadata.refresh()
            if let editorReplyID { onSavedReply(editorReplyID) }
            errorMessage = nil
            showingEditor = false
            editingTask = nil
            editorReplyID = nil
            editingRecipe = nil
            discardsDraftOnCancel = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(_ task: SavedAgentTask) {
        do {
            let store = try storeProvider()
            try store.deleteTask(id: task.id)
            reload(using: store)
            AgentTaskShortcutMetadata.refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reload() {
        do {
            reload(using: try storeProvider())
        } catch {
            savedTasks = []
            history = []
            errorMessage = error.localizedDescription
        }
    }

    private func reload(using store: AgentTaskStore) {
        do {
            try store.load()
            savedTasks = store.savedTasks
            history = store.history
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
