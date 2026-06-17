import SwiftUI

/// Reader for a work in the Library.
/// - Downloaded works (chapters saved on device) read fully offline.
/// - Bookmarked-only works have no saved chapter text, so we fetch it from
///   AO3 on demand. From here you can also download it for offline reading.
struct SavedWorkReader: View {
    @Environment(\.ao3Client) private var client
    @Environment(\.modelContext) private var context
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage(ReaderProfile.deviceKey("reader.theme")) private var themeRaw: String = ReaderTheme.system.rawValue
    let work: Work

    @State private var payload: AO3WorkPayload?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isSavingOffline = false
    @State private var isDownloaded = false
    @State private var showingComments = false
    @State private var currentChapterIndex = 1

    private var hasOfflineText: Bool { !work.chapters.isEmpty }

    /// AO3 chapter id for the chapter currently on screen (per-chapter comments).
    /// nil → CommentsView falls back to the work-level thread.
    private var currentChapterAoId: Int? {
        if hasOfflineText {
            return work.chapters.first(where: { $0.index == currentChapterIndex })?.aoId
        }
        return payload?.chapters.first(where: { $0.index == currentChapterIndex })?.aoId
    }

    private var totalChapterCount: Int {
        if hasOfflineText { return work.chapters.count }
        return payload?.chapters.count ?? work.totalChapters ?? work.chapterCount
    }

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
                ReaderView(work: work, currentChapter: $currentChapterIndex)
            } else if let payload {
                ReaderView(payload: payload, currentChapter: $currentChapterIndex)
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
                    showingComments = true
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .accessibilityLabel("Comments")

                // Share + Save-offline live in one "…" menu so this plus the
                // reader's own items (chapters, Aa, minimize) stay within the
                // ~5 trailing icons the iPhone nav bar fits before it spills
                // into its own overflow (a confusing second ellipsis).
                Menu {
                    WorkExportButton(workId: work.ao3Id, title: work.title, useTextLabel: true)
                    Button {
                        Task { await saveOffline() }
                    } label: {
                        Label(isDownloaded ? "Downloaded" : "Save Offline",
                              systemImage: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                    }
                    .disabled(isSavingOffline || isDownloaded)
                } label: {
                    if isSavingOffline {
                        ProgressView()
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .accessibilityLabel("More")
            }
        }
        .sheet(isPresented: $showingComments) {
            CommentsView(workId: work.ao3Id, workTitle: work.title,
                         chapterId: currentChapterAoId,
                         chapterNumber: currentChapterIndex,
                         totalChapters: totalChapterCount)
        }
        .task { await load() }
        .onAppear {
            isDownloaded = WorkPersistence.epubURL(workId: work.ao3Id) != nil
            WorkPersistence.recordView(work: work, into: context)
        }
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
