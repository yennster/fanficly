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
    /// The reader is in full screen: no toolbar items at all.
    @State private var readerFullScreen = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// Why Save Offline failed, shown in an alert: the reader covers the
    /// screen, so `errorMessage`'s placeholder never shows while reading.
    @State private var saveError: String?
    @State private var isSavingOffline = false
    @State private var isDownloaded = false
    @State private var showingComments = false
    @State private var showingBookmark = false
    @State private var currentChapterIndex = 1
    @State private var isResolvingComments = false
    @State private var exporter = WorkExporter()
    @State private var kudos = KudosGiver()

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
            // A fetched payload wins over saved text, so saving it offline
            // mid-read keeps this one reader: switching branches would be a
            // new view, stopping narration and re-paginating. Both hold the
            // same chapters.
            if let payload {
                ReaderView(payload: payload, currentChapter: $currentChapterIndex)
            } else if hasOfflineText {
                ReaderView(work: work, currentChapter: $currentChapterIndex)
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
        .onPreferenceChange(ReaderFullScreenKey.self) { readerFullScreen = $0 }
        .toolbar {
            if !readerFullScreen {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        Task {
                            isResolvingComments = true
                            await ensureChapterIds()
                            isResolvingComments = false
                            showingComments = true
                        }
                    } label: {
                        if isResolvingComments {
                            ProgressView()
                        } else {
                            Label("Comments", systemImage: "bubble.left.and.bubble.right")
                        }
                    }
                    .disabled(isResolvingComments)
                    .accessibilityLabel("Comments")

                    // Kudos, share and save-offline live in one More menu so this plus the
                    // reader's own items (chapters, Aa, minimize) stay within the
                    // ~5 trailing icons the iPhone nav bar fits before it spills
                    // into its own overflow. Not an ellipsis symbol: Apple keeps
                    // that for the system overflow (iPhone Duo's vertical strip).
                    Menu {
                        KudosMenuButton(workId: work.ao3Id, giver: kudos)
                        Button {
                            showingBookmark = true
                        } label: {
                            Label("Bookmark on AO3", systemImage: "bookmark.square")
                        }
                        WorkExportButton(workId: work.ao3Id, title: work.title,
                                         exporter: exporter, useTextLabel: true)
                        Button {
                            Task { await saveOffline() }
                        } label: {
                            Label(isDownloaded ? "Downloaded" : "Save Offline",
                                  systemImage: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                        }
                        .disabled(isSavingOffline || isDownloaded)
                    } label: {
                        if isSavingOffline || exporter.isExporting || kudos.isSending {
                            ProgressView()
                        } else {
                            Label("More", systemImage: "book.circle")
                        }
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .sheet(isPresented: $showingComments) {
            CommentsView(workId: work.ao3Id, workTitle: work.title,
                         chapterId: currentChapterAoId,
                         chapterNumber: currentChapterIndex,
                         totalChapters: totalChapterCount)
        }
        .sheet(isPresented: $showingBookmark) {
            AO3BookmarkSheet(workId: work.ao3Id, workTitle: work.title)
        }
        // On the screen view, NOT inside the menu — see WorkExporter's docs.
        .workExportPresentation(exporter)
        .kudosPresentation(kudos, workId: work.ao3Id)
        .saveOfflineAlert($saveError)
        .task { await load() }
        .onAppear {
            isDownloaded = WorkPersistence.epubURL(workId: work.ao3Id) != nil
            WorkPersistence.recordView(work: work, into: context)
        }
    }

    /// Downloaded works saved before per-chapter comments have no chapter ids,
    /// so the reader can't tell which chapter's thread to load (it falls back to
    /// the work/first-chapter thread, often empty). Resolve them once from the
    /// work page and persist — a one-time fetch per old download; new downloads
    /// already carry ids. No-op (and silent on failure) when ids are present or
    /// the work isn't downloaded.
    private func ensureChapterIds() async {
        guard hasOfflineText, currentChapterAoId == nil else { return }
        guard let fetched = try? await client.fetchWork(id: work.ao3Id) else { return }
        var changed = false
        for ch in fetched.chapters {
            guard let id = ch.aoId,
                  let local = work.chapters.first(where: { $0.index == ch.index }),
                  local.aoId == nil else { continue }
            local.aoId = id
            changed = true
        }
        if changed { try? context.save() }
    }

    private func load() async {
        guard !hasOfflineText, payload == nil else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            payload = try await client.fetchWork(id: work.ao3Id)
        } catch {
            errorMessage = "This bookmarked work loads on demand. Connect to the internet to read it, then choose Save Offline in the More menu to keep it on this device."
        }
    }

    /// Saves the chapter text (when it isn't stored yet), then the EPUB.
    /// When the text can't be fetched nothing is downloaded, so the work is
    /// never marked Downloaded without text to read offline.
    private func saveOffline() async {
        isSavingOffline = true
        defer { isSavingOffline = false }
        if let payload {
            _ = WorkPersistence.upsert(payload: payload, into: context)
            iCloudSyncManager.shared.queueBackup(context: context)
        } else if !hasOfflineText {
            do {
                let fetched = try await client.fetchWork(id: work.ao3Id)
                _ = WorkPersistence.upsert(payload: fetched, into: context)
                iCloudSyncManager.shared.queueBackup(context: context)
            } catch {
                saveError = "Couldn't get the story's text from AO3, so nothing was saved: \(error)"
                return
            }
        }
        do {
            _ = try await client.downloadEPUB(workId: work.ao3Id)
            isDownloaded = true
        } catch {
            saveError = "The text is saved for offline reading, but the EPUB download failed: \(error)"
        }
    }
}
