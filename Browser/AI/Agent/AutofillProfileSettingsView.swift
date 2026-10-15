import SwiftUI
import UIKit

struct AutofillProfileSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var profile = AutofillProfile()
    @State private var hasLoaded = false
    @State private var isBusy = false
    @State private var message: String?
    @State private var didLoadStoredProfile = false
    @State private var operationID = UUID()
    @State private var operationTask: Task<Void, Never>?

    private let service: AutofillProfileService

    init(service: AutofillProfileService) {
        self.service = service
    }

    var body: some View {
        Form {
            if hasLoaded {
                Section {
                    Text("Only the fields you approve are filled. Passwords and payment details are never stored here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    profileField("Given name", text: $profile.givenName)
                    profileField("Middle name", text: $profile.middleName)
                    profileField("Family name", text: $profile.familyName)
                    profileField("Email", text: $profile.email, contentType: .emailAddress, keyboard: .emailAddress)
                    profileField("Phone", text: $profile.phone, contentType: .telephoneNumber, keyboard: .phonePad)
                } header: {
                    Text("Name and contact")
                }

                Section("Address") {
                    profileField("Address line 1", text: $profile.addressLine1, contentType: .fullStreetAddress)
                    profileField("Address line 2", text: $profile.addressLine2)
                    profileField("City", text: $profile.city, contentType: .addressCity)
                    profileField("Region", text: $profile.region, contentType: .addressState)
                    profileField("Postal code", text: $profile.postalCode, contentType: .postalCode)
                    profileField("Country", text: $profile.country, contentType: .countryName)
                    profileField("Organization", text: $profile.organization, contentType: .organizationName)
                }

                Section {
                    Button {
                        save()
                    } label: {
                        if isBusy { ProgressView() } else { Text("Save Profile") }
                    }
                    .disabled(isBusy)

                    if didLoadStoredProfile {
                        Button("Delete Profile", role: .destructive) {
                            delete()
                        }
                        .disabled(isBusy)
                    }
                }
            } else if isBusy {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Authenticate to open your autofill profile.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    Text(message ?? "Authenticate before your profile values are loaded.")
                        .foregroundStyle(.secondary)
                    Button("Unlock Profile") { load() }
                }
            }
        }
        .navigationTitle("Autofill Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if !hasLoaded && message == nil { load() }
        }
        .onDisappear { lockAndClear() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { lockAndClear() }
        }
        .alert(
            "Autofill Profile",
            isPresented: Binding(get: { message != nil && hasLoaded }, set: { if !$0 { message = nil } })
        ) {
            Button("OK", role: .cancel) { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    private func profileField(
        _ title: String,
        text: Binding<String>,
        contentType: UITextContentType? = nil,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        TextField(title, text: text)
            .textContentType(contentType)
            .keyboardType(keyboard)
            .textInputAutocapitalization(contentType == .emailAddress ? .never : .words)
            .autocorrectionDisabled(contentType == .emailAddress)
    }

    private func load() {
        guard !isBusy else { return }
        isBusy = true
        let token = UUID()
        operationID = token
        operationTask?.cancel()
        operationTask = Task { @MainActor in
            defer { if operationID == token { isBusy = false; operationTask = nil } }
            do {
                let loaded = try await service.loadForEditing()
                try Task.checkCancellation()
                guard operationID == token else { return }
                profile = loaded
                didLoadStoredProfile = !loaded.isEmpty
                hasLoaded = true
                message = nil
            } catch {
                guard operationID == token else { return }
                profile = AutofillProfile()
                hasLoaded = false
                message = error.localizedDescription
            }
        }
    }

    private func save() {
        guard !isBusy else { return }
        isBusy = true
        let submittedProfile = profile
        let token = UUID()
        operationID = token
        operationTask?.cancel()
        operationTask = Task { @MainActor in
            defer { if operationID == token { isBusy = false; operationTask = nil } }
            do {
                try await service.save(submittedProfile)
                try Task.checkCancellation()
                guard operationID == token else { return }
                didLoadStoredProfile = !submittedProfile.isEmpty
                message = "Your autofill profile was saved securely."
            } catch {
                guard operationID == token else { return }
                message = error.localizedDescription
            }
        }
    }

    private func delete() {
        guard !isBusy else { return }
        isBusy = true
        let token = UUID()
        operationID = token
        operationTask?.cancel()
        operationTask = Task { @MainActor in
            defer { if operationID == token { isBusy = false; operationTask = nil } }
            do {
                try await service.delete()
                try Task.checkCancellation()
                guard operationID == token else { return }
                profile = AutofillProfile()
                didLoadStoredProfile = false
                message = "Your autofill profile was deleted."
            } catch {
                guard operationID == token else { return }
                message = error.localizedDescription
            }
        }
    }

    private func lockAndClear() {
        operationID = UUID()
        operationTask?.cancel()
        operationTask = nil
        isBusy = false
        hasLoaded = false
        didLoadStoredProfile = false
        profile = AutofillProfile()
        message = nil
    }
}
