import SwiftUI

/// Translate To…: one page into a language of your choice. Settings → Translate To sets
/// the language the plain Translate uses.
struct TranslateLanguagePicker: View {
    let onPick: (Locale.Language) -> Void

    @ObservedObject private var languages = TranslationLanguages.shared
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [TranslationLanguages.Option] {
        search.isEmpty ? languages.all : languages.all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { option in
                Button(option.name) {
                    dismiss()
                    onPick(option.language)
                }
                .foregroundStyle(.primary)
            }
            .overlay {
                if languages.all.isEmpty { ProgressView() }
            }
            .searchable(text: $search, prompt: "Language")
            .navigationTitle("Translate To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
