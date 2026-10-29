//
//  AgentResultHandoffViews.swift
//  Vortex
//
//  The handoff action row and the system sheets it opens. Calendar and Messages use the system
//  editors; Mail and Messages fall back to the share sheet when they cannot send. Nothing is sent
//  automatically, and Reminders access is requested only after the user taps Save Reminder.
//

import SwiftUI
import EventKit
import UniformTypeIdentifiers
import UIKit
#if !targetEnvironment(macCatalyst)
import EventKitUI
import MessageUI
#endif

/// The row of handoff actions under a finished agent reply, and in the run details.
struct AgentResultHandoffRow: View {
    let onSelect: (AgentHandoffAction) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(AgentHandoffAction.allCases) { action in
                    Button {
                        onSelect(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                            .font(.footnote.weight(.semibold))
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("agentHandoff.\(action.accessibilityKey)")
                }
            }
            .padding(.vertical, 2)
        }
    }
}

extension View {
    /// Presents the handoff for `request`. Setting the binding to nil dismisses it.
    func agentHandoffSheet(_ request: Binding<AgentHandoffRequest?>) -> some View {
        sheet(item: request) { item in
            AgentHandoffSheet(request: item) {
                request.wrappedValue = nil
            }
        }
    }
}

/// Chooses the system sheet for one prepared handoff.
struct AgentHandoffSheet: View {
    let request: AgentHandoffRequest
    let onFinish: () -> Void

    var body: some View {
        switch request.kind {
        case let .calendar(title, notes, start, end):
            #if targetEnvironment(macCatalyst)
            ActivityViewRepresentable(items: [title + "\n\n" + notes], onFinish: onFinish)
                .ignoresSafeArea()
            #else
            CalendarEventEditorRepresentable(
                title: title,
                notes: notes,
                start: start,
                end: end,
                onFinish: onFinish
            )
            .ignoresSafeArea()
            #endif
        case let .reminder(title, due):
            ReminderConfirmationView(title: title, due: due, onFinish: onFinish)
        case let .email(subject, body, attachments):
            emailSheet(subject: subject, body: body, attachments: attachments)
        case let .message(body):
            messageSheet(body: body)
        case let .share(text, files):
            ActivityViewRepresentable(items: Self.shareItems(text: text, files: files), onFinish: onFinish)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func emailSheet(subject: String, body: String, attachments: [URL]) -> some View {
        #if targetEnvironment(macCatalyst)
        ActivityViewRepresentable(items: Self.shareItems(text: subject + "\n\n" + body, files: attachments), onFinish: onFinish)
            .ignoresSafeArea()
        #else
        if MFMailComposeViewController.canSendMail() {
            MailComposerRepresentable(subject: subject, body: body, attachments: attachments, onFinish: onFinish)
                .ignoresSafeArea()
        } else {
            ActivityViewRepresentable(items: Self.shareItems(text: subject + "\n\n" + body, files: attachments), onFinish: onFinish)
                .ignoresSafeArea()
        }
        #endif
    }

    @ViewBuilder
    private func messageSheet(body: String) -> some View {
        #if targetEnvironment(macCatalyst)
        ActivityViewRepresentable(items: [body], onFinish: onFinish)
            .ignoresSafeArea()
        #else
        if MFMessageComposeViewController.canSendText() {
            MessageComposerRepresentable(body: body, onFinish: onFinish)
                .ignoresSafeArea()
        } else {
            ActivityViewRepresentable(items: [body], onFinish: onFinish)
                .ignoresSafeArea()
        }
        #endif
    }

    static func shareItems(text: String, files: [URL]) -> [Any] {
        var items: [Any] = [text]
        items.append(contentsOf: files)
        return items
    }
}

/// Shows the reminder before anything is saved. Reminders access is requested only when the user taps Save Reminder.
private struct ReminderConfirmationView: View {
    let title: String
    let due: Date?
    let onFinish: () -> Void

    @State private var message: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Reminder") {
                    LabeledContent("Title") {
                        Text(title)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Due") {
                        Text(dueText)
                    }
                }
                if let message {
                    Section {
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Add Reminder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onFinish)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Reminder") {
                        save()
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("saveReminderConfirmation")
                }
            }
        }
    }

    private var dueText: String {
        guard let due else { return "No due date" }
        return due.formatted(date: .abbreviated, time: .shortened)
    }

    private func save() {
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            let store = EKEventStore()
            do {
                guard try await store.requestFullAccessToReminders() else {
                    message = "Vortyra can't add reminders. Allow Reminders access for Vortyra in Settings, then try again."
                    return
                }
                guard let calendar = store.defaultCalendarForNewReminders() else {
                    message = "No Reminders list is available to add this reminder to."
                    return
                }
                let reminder = EKReminder(eventStore: store)
                reminder.title = title
                reminder.calendar = calendar
                if let due {
                    reminder.dueDateComponents = Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute],
                        from: due
                    )
                }
                try store.save(reminder, commit: true)
                onFinish()
            } catch {
                message = "The reminder couldn't be saved. \(error.localizedDescription)"
            }
        }
    }
}

#if !targetEnvironment(macCatalyst)
/// Calendar's own event editor. No calendar permission is requested; the user chooses the calendar and saves.
private struct CalendarEventEditorRepresentable: UIViewControllerRepresentable {
    let title: String
    let notes: String
    let start: Date?
    let end: Date?
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let store = EKEventStore()
        let event = EKEvent(eventStore: store)
        event.title = title
        event.notes = notes
        // With no detected date, start at the next whole hour so the editor shows a usable default the user can change.
        let startDate = start ?? Calendar.current.nextDate(
            after: Date(),
            matching: DateComponents(minute: 0),
            matchingPolicy: .nextTime
        ) ?? Date().addingTimeInterval(AgentResultHandoffDraft.defaultEventDuration)
        event.startDate = startDate
        event.endDate = end ?? startDate.addingTimeInterval(AgentResultHandoffDraft.defaultEventDuration)
        let controller = EKEventEditViewController()
        controller.eventStore = store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: EKEventEditViewController, context: Context) {}

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            onFinish()
        }
    }
}

/// Mail composer with the subject, body and files already filled in. The user sends it.
private struct MailComposerRepresentable: UIViewControllerRepresentable {
    let subject: String
    let body: String
    let attachments: [URL]
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setSubject(subject)
        controller.setMessageBody(body, isHTML: false)
        for url in attachments {
            guard let data = try? Data(contentsOf: url) else { continue }
            let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            controller.addAttachmentData(data, mimeType: mimeType, fileName: url.lastPathComponent)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            onFinish()
        }
    }
}

/// Messages composer with the body filled in. The user sends it.
private struct MessageComposerRepresentable: UIViewControllerRepresentable {
    let body: String
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        controller.body = body
        return controller
    }

    func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            onFinish()
        }
    }
}
#endif

/// The system share sheet with text and files.
private struct ActivityViewRepresentable: UIViewControllerRepresentable {
    let items: [Any]
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            onFinish()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
