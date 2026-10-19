import SwiftUI

/// Creates or edits the signed-in user's AO3 bookmark for a work: notes,
/// their own tags, rec and private. Loads AO3's own form from the work page
/// (prefilled when the work is already bookmarked) and posts it back, so the
/// field names and CSRF token come from AO3 rather than being hardcoded.
struct AO3BookmarkSheet: View {
    let workId: Int
    let workTitle: String
    @Environment(\.ao3Client) private var client
    @Environment(AuthState.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var form: AO3BookmarkForm?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Group {
                if auth.username == nil {
                    ContentUnavailableView("Log in to bookmark", systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Log in to AO3 (Settings) to bookmark this work on AO3."))
                } else if let binding = Binding($form) {
                    editor(binding)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Couldn't load your bookmark", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Retry") { Task { await load() } }
                    }
                } else {
                    VStack { Spacer(); ProgressView("Loading…"); Spacer() }
                }
            }
            .navigationTitle(form?.isExisting == true ? "Edit Bookmark" : "Bookmark on AO3")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if form != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task { await save() }
                        } label: {
                            if isSaving { ProgressView() } else { Text("Save") }
                        }
                        .disabled(isSaving)
                        .accessibilityLabel("Save bookmark")
                    }
                }
            }
            .task { await load() }
        }
    }

    private func editor(_ form: Binding<AO3BookmarkForm>) -> some View {
        Form {
            Section {
                Text(workTitle).font(.headline)
            }
            Section {
                TextEditor(text: form.notes)
                    .frame(minHeight: 120)
                    .accessibilityLabel("Notes")
            } header: {
                Text("Notes")
            } footer: {
                Text("The creator's summary is added automatically.")
            }
            Section {
                TextField("Your tags", text: form.tags, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Your tags")
            } footer: {
                Text("Comma separated. The creator's tags are added automatically.")
            }
            Section {
                Toggle("Rec", isOn: form.isRec)
                Toggle("Private bookmark", isOn: form.isPrivate)
            } footer: {
                Text("A rec is a bookmark you recommend. A private bookmark is only visible to you.")
            }
            if let saveError {
                Section {
                    Text(saveError).foregroundStyle(.red)
                }
            }
        }
        .disabled(isSaving)
    }

    private func load() async {
        guard auth.username != nil, form == nil, !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            form = try await client.fetchBookmarkForm(workId: workId)
        } catch {
            loadError = Self.message(for: error)
        }
    }

    private func save() async {
        guard let form, !isSaving else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        do {
            try await client.saveBookmark(form)
            UIAccessibility.post(notification: .announcement,
                                 argument: form.isExisting ? "Bookmark updated" : "Bookmarked on AO3")
            dismiss()
        } catch {
            saveError = "Couldn't save: \(Self.message(for: error))"
            // Not when AO3 asked us to slow down or the session is gone.
            if case AO3Error.rateLimited = error { return }
            if case AO3Error.unauthorized = error { return }
            await refreshForm(keeping: form)
        }
    }

    /// After a failed save, reload AO3's form but keep the user's edits, so a
    /// second Save posts with a fresh token and, if the first one did land
    /// (a lost response), updates that bookmark instead of creating another.
    private func refreshForm(keeping edited: AO3BookmarkForm) async {
        guard var fresh = try? await client.fetchBookmarkForm(workId: workId) else { return }
        fresh.notes = edited.notes
        fresh.tags = edited.tags
        fresh.isPrivate = edited.isPrivate
        fresh.isRec = edited.isRec
        form = fresh
    }

    private static func message(for error: Error) -> String {
        switch error {
        case AO3Error.unauthorized: return "Your AO3 session has expired. Log in again in Settings."
        case AO3Error.parseFailed(let reason): return reason
        case AO3Error.http(let status): return "AO3 returned HTTP \(status)."
        case AO3Error.network(let underlying): return "Network: \(underlying)"
        case AO3Error.rateLimited: return "AO3 is asking us to slow down. Try again in a minute."
        default: return error.localizedDescription
        }
    }
}
