import SwiftUI

/// Reader for a work in the Library.
/// - Downloaded works (chapters saved on device) read fully offline.
/// - Bookmarked-only works have no saved chapter text, so we fetch it from
///   AO3 on demand. From here you can also download it for offline reading.
struct SavedWorkReader: View {
    @Environment(\.ao3Client) private var client
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage("reader.theme") private var themeRaw: String = ReaderTheme.system.rawValue
    let work: Work

    @State private var payload: AO3WorkPayload?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isSavingOffline = false
    @State private var isDownloaded = false

    private var hasOfflineText: Bool { !work.chapters.isEmpty }

    /// The reader's themed page colour (same derivation as `ReaderView`), so the
    /// screen is opaque from the first frame instead of letting the Library list
    /// show through while a bookmarked work loads on demand.
    private var readerBackground: Color {
        let theme = ReaderTheme(rawValue: themeRaw) ?? .system
        let scheme = theme.preferredColorScheme ?? systemColorScheme
        return theme.background(for: scheme)
    }

    var body: some View {
        Group {
            if hasOfflineText {
                ReaderView(work: work)
            } else if let payload {
                ReaderView(payload: payload)
            } else if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading from AO3…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Couldn't load", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") { Task { await load() } }
                }
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(readerBackground.ignoresSafeArea())
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    work.isStarred.toggle()
                    try? context.save()
                    iCloudSyncManager.shared.queueBackup(context: context)
                } label: {
                    Image(systemName: work.isStarred ? "star.fill" : "star")
                        .foregroundStyle(work.isStarred ? .yellow : Color.primary)
                }
                .accessibilityLabel(work.isStarred ? "Starred" : "Star")
                
                Button {
                    work.isPinned.toggle()
                    try? context.save()
                    iCloudSyncManager.shared.queueBackup(context: context)
                } label: {
                    Image(systemName: work.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(work.isPinned ? .blue : Color.primary)
                }
                .accessibilityLabel(work.isPinned ? "Pinned" : "Pin")

                WorkExportButton(workId: work.ao3Id, title: work.title)
                saveOfflineButton
            }
        }
        .task { await load() }
        .onAppear {
            isDownloaded = WorkPersistence.epubURL(workId: work.ao3Id) != nil
            WorkPersistence.recordView(work: work, into: context)
        }
    }

    @ViewBuilder
    private var saveOfflineButton: some View {
        Button {
            Task { await saveOffline() }
        } label: {
            if isSavingOffline {
                ProgressView()
            } else {
                Image(systemName: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(isDownloaded ? .green : .primary)
            }
        }
        .disabled(isSavingOffline || isDownloaded)
        .accessibilityLabel(isDownloaded ? "Downloaded" : "Save offline")
    }

    private func load() async {
        guard !hasOfflineText, payload == nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            payload = try await client.fetchWork(id: work.ao3Id)
        } catch {
            errorMessage = "This bookmarked work loads on demand. Connect to the internet to read it, or tap the download button to save it offline."
        }
    }

    private func saveOffline() async {
        isSavingOffline = true
        defer { isSavingOffline = false }
        // Make sure we have the full work to persist its chapters.
        let toSave: AO3WorkPayload?
        if let payload {
            toSave = payload
        } else {
            toSave = try? await client.fetchWork(id: work.ao3Id)
        }
        if let toSave {
            _ = WorkPersistence.upsert(payload: toSave, into: context)
            payload = toSave
        }
        do {
            _ = try await client.downloadEPUB(workId: work.ao3Id)
            isDownloaded = true
        } catch {
            errorMessage = "Couldn't download for offline: \(error)"
        }
    }
}
