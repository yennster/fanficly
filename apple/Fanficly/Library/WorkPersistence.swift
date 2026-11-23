import Foundation
import SwiftData
import CoreSpotlight
import UniformTypeIdentifiers

enum WorkPersistence {
    @MainActor
    static func upsert(payload: AO3WorkPayload, into context: ModelContext, save: Bool = true) -> Work {
        let work = upsertMetadata(summary: payload.summary, into: context, save: false)
        // New text makes a saved EPUB stale; the caller saves a current one
        // (Save Offline, an import), and until then Export builds from the
        // text (#173).
        removeSavedEPUB(workId: payload.summary.id)

        for ch in work.chapters { context.delete(ch) }
        work.chapters.removeAll()
        for ch in payload.chapters {
            let chapter = Chapter(work: work, index: ch.index, title: ch.title, bodyHTML: ch.bodyHTML, aoId: ch.aoId,
                                  summaryHTML: ch.summaryHTML, notesHTML: ch.notesHTML, endNotesHTML: ch.endNotesHTML)
            context.insert(chapter)
        }
        // Saving the text again undoes an earlier Remove Download.
        setDownloadRemoved(work.ao3Id, removed: false)

        if save { try? context.save() }
        return work
    }

    /// Saves a work opened from a shared, dropped or pasted link (#176): its
    /// metadata and every chapter, from the fetch the import already made, so
    /// the story reads offline with no second request. The work is followed;
    /// one already in the Library keeps when it was saved and followed.
    @MainActor
    @discardableResult
    static func saveImported(payload: AO3WorkPayload, into context: ModelContext) -> Work {
        // Importing a work deleted a moment ago keeps it (#169).
        UndoCenter.shared.cancel(UndoCenter.Key.work(payload.summary.id))
        let work = upsert(payload: payload, into: context, save: false)
        if !work.isFollowed {
            work.isFollowed = true
            work.followedAt = .now
            // Following now isn't news: alert only for chapters after this.
            work.lastSeenChapterCount = payload.summary.chapterCount
        }
        try? context.save()
        return work
    }

    /// Upsert just the metadata (no chapter bodies). Used by the local
    /// follow action, which doesn't need to download the full work.
    @MainActor
    @discardableResult
    static func upsertMetadata(summary: AO3WorkSummary, into context: ModelContext, save: Bool = true) -> Work {
        let ao3Id = summary.id
        let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == ao3Id })
        let existing = (try? context.fetch(descriptor))?.first

        let work: Work
        if let existing {
            work = existing
        } else {
            work = Work(ao3Id: summary.id, title: summary.title, authorName: summary.author)
            context.insert(work)
        }

        work.title = summary.title
        work.authorName = summary.author
        work.authorUsername = summary.authorUsername
        work.summary = summary.summary
        work.rating = summary.rating
        work.warnings = summary.warnings
        work.categories = summary.categories
        work.fandoms = summary.fandoms
        work.characters = summary.characters
        work.relationships = summary.relationships
        work.freeforms = summary.freeforms
        work.language = summary.language
        work.wordCount = summary.wordCount
        work.chapterCount = summary.chapterCount
        work.totalChapters = summary.totalChapters
        work.kudos = summary.kudos
        work.hits = summary.hits
        work.isComplete = summary.isComplete
        work.updatedAt = summary.updatedAt

        if save { try? context.save() }
        // Every library work is findable in Spotlight, followed or not.
        indexWork(work)
        return work
    }

    // MARK: - Spotlight

    /// Core Spotlight domain for library works. The index is on-device; a tap
    /// on a result reaches `RootView`'s `CSSearchableItemActionType` handler,
    /// which opens the work through the resume route.
    static let spotlightDomain = "io.github.yennster.fanficly.works"

    /// Set once the launch task has rebuilt the index from the whole library.
    static let spotlightReindexedKey = "spotlight.reindexed.v1"

    /// What Spotlight shows for one library work. A Sendable value so items
    /// can be built off the main actor, in the index's completion handler.
    struct SpotlightEntry: Sendable, Equatable {
        let ao3Id: Int
        let title: String
        let author: String
        let summary: String
        let keywords: [String]
    }

    static func spotlightIdentifier(ao3Id: Int) -> String {
        "work-\(ao3Id)"
    }

    /// The AO3 work id in a `work-<id>` Spotlight identifier, or nil for
    /// anything else.
    static func workId(fromSpotlightIdentifier identifier: String) -> Int? {
        guard identifier.hasPrefix("work-") else { return nil }
        guard let id = Int(identifier.dropFirst("work-".count)), id > 0 else { return nil }
        return id
    }

    @MainActor
    static func spotlightEntry(for work: Work) -> SpotlightEntry {
        SpotlightEntry(
            ao3Id: work.ao3Id,
            title: work.title,
            author: work.authorName,
            summary: work.summary,
            keywords: work.fandoms + work.relationships + work.characters
        )
    }

    static func searchableItem(for entry: SpotlightEntry) -> CSSearchableItem {
        let attributeSet = CSSearchableItemAttributeSet(contentType: .text)
        attributeSet.title = entry.title
        attributeSet.contentDescription = entry.summary
        attributeSet.artist = entry.author
        attributeSet.keywords = entry.keywords
        return CSSearchableItem(
            uniqueIdentifier: spotlightIdentifier(ao3Id: entry.ao3Id),
            domainIdentifier: spotlightDomain,
            attributeSet: attributeSet
        )
    }

    @MainActor
    static func indexWork(_ work: Work) {
        // Demo mode's library is in memory, but the index is the device's own.
        guard !FanficlyApp.isDemoMode else { return }
        CSSearchableIndex.default().indexSearchableItems(
            [searchableItem(for: spotlightEntry(for: work))], completionHandler: nil)
    }

    /// Removes a work from the library with its downloaded EPUB and its
    /// Spotlight entry, without saving. Recording the deletion for sync is
    /// the caller's job: a user's delete records it, and a restore applying
    /// another device's delete doesn't need to.
    @MainActor
    static func delete(_ work: Work, in context: ModelContext) {
        if let url = epubURL(workId: work.ao3Id) {
            try? FileManager.default.removeItem(at: url)
        }
        deindexWork(ao3Id: work.ao3Id)
        // The Continue reading widget mustn't keep its title (#209).
        clearLastRead(workId: work.ao3Id)
        // Saved again later, it starts without an earlier Remove Download.
        setDownloadRemoved(work.ao3Id, removed: false)
        context.delete(work)
    }

    // MARK: - Removing a download

    /// Per device: works whose download was removed here, so a restore
    /// doesn't put their chapters back from another device's copy (and offer
    /// to re-download them). Removing a download here leaves it on the other
    /// devices. Same key and comma-separated format as the Windows app.
    static let removedDownloadsKey = "sync.removedDownloads"

    static func removedDownloads(defaults: UserDefaults = .standard) -> Set<Int> {
        Set((defaults.string(forKey: removedDownloadsKey) ?? "")
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    /// Marks (or, with `removed` false, unmarks) a work's download as removed
    /// on this device.
    static func setDownloadRemoved(_ ao3Id: Int, removed: Bool, defaults: UserDefaults = .standard) {
        var ids = removedDownloads(defaults: defaults)
        guard removed ? ids.insert(ao3Id).inserted : ids.remove(ao3Id) != nil else { return }
        if ids.isEmpty {
            defaults.removeObject(forKey: removedDownloadsKey)
        } else {
            defaults.set(ids.sorted().map(String.init).joined(separator: ","), forKey: removedDownloadsKey)
        }
    }

    /// Deletes the offline copy, the EPUB file and the saved chapter text,
    /// and saves. The work stays in the Library and loads from AO3 when it's
    /// read. Queuing the backup is the caller's job.
    @MainActor
    static func removeDownload(_ work: Work, in context: ModelContext, defaults: UserDefaults = .standard,
                               epubURL: URL? = nil) {
        if let url = epubURL ?? Self.epubURL(workId: work.ao3Id) {
            try? FileManager.default.removeItem(at: url)
        }
        for ch in work.chapters { context.delete(ch) }
        work.chapters.removeAll()
        setDownloadRemoved(work.ao3Id, removed: true, defaults: defaults)
        try? context.save()
    }

    /// Saves a library work for offline reading, like the reader's Save
    /// Offline: the chapter text first when it isn't stored yet, then the
    /// EPUB. When the text can't be fetched nothing is downloaded, so the
    /// work is never marked Downloaded without text to read offline.
    /// Returns false when there was nothing to save it for.
    @MainActor
    @discardableResult
    static func saveOffline(workId: Int, client: any AO3ClientProtocol, context: ModelContext) async throws -> Bool {
        let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == workId })
        // Removed from the library mid-run, or waiting to be (#169): nothing
        // to save it for. A download never cancels the user's delete.
        guard !UndoCenter.shared.isPending(UndoCenter.Key.work(workId)),
              let work = try? context.fetch(descriptor).first else { return false }
        if work.chapters.isEmpty {
            let payload = try await client.fetchWork(id: workId)
            // Deleted while the fetch ran: don't bring it back.
            guard work.modelContext != nil, !work.isDeleted,
                  !UndoCenter.shared.isPending(UndoCenter.Key.work(workId)) else { return false }
            _ = upsert(payload: payload, into: context)
            iCloudSyncManager.shared.queueBackup(context: context)
        }
        _ = try await client.downloadEPUB(workId: workId)
        return true
    }

    // MARK: - Renaming a folder

    enum FolderRename: Equatable {
        case renamed
        /// Blank, or the same name: nothing to do.
        case unchanged
        /// Another folder already has the name.
        case taken
    }

    /// Renames a folder in place, so its works and any open screen keep it.
    /// For sync, a folder's name is its identity, so this is recorded the way
    /// the Windows app's rename is: a deletion marker for the old name (or
    /// another device's copy would bring it back beside the renamed one), and
    /// the folder stamped now, so a name deleted before still wins over its
    /// old marker. Saves; queuing the backup is the caller's job.
    @MainActor
    static func renameFolder(_ folder: CustomFolder, to newName: String, in context: ModelContext,
                             now: Date = .now) -> FolderRename {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let oldName = folder.name
        guard !name.isEmpty, name != oldName else { return .unchanged }
        let descriptor = FetchDescriptor<CustomFolder>(predicate: #Predicate { $0.name == name })
        if (try? context.fetch(descriptor))?.first != nil {
            // A folder with that name deleted a moment ago is still waiting
            // behind Undo (#169): its delete runs now, and the name is free.
            guard UndoCenter.shared.isPending(UndoCenter.Key.folder(name)) else { return .taken }
            UndoCenter.shared.commitPending()
            if (try? context.fetch(descriptor))?.first != nil { return .taken }
        }
        // Stamped after any marker this device holds for the new name (one
        // just written by the delete above, or a rename away from it in the
        // same second): a tie goes to the marker, which would drop the folder
        // at the next sync.
        let marker = iCloudSyncManager.localDeletions()
            .filter { $0.kind == DeletionKind.folder.rawValue && $0.key == name }
            .map(\.deletedAt).max()
        let stamp = marker.map { max(now, $0.addingTimeInterval(1)) } ?? now
        iCloudSyncManager.recordDeletion(.folder, key: oldName, at: stamp)
        folder.name = name
        folder.createdAt = stamp
        try? context.save()
        return .renamed
    }

    /// Forgets the last-read widget entry when it names `workId` (nil: any
    /// work): a deleted or hidden work, or a cleared history (#209). Not in
    /// demo mode: its library is in memory, but the widget's store is the
    /// device's own.
    @MainActor
    static func clearLastRead(workId: Int?) {
        guard !FanficlyApp.isDemoMode else { return }
        WidgetProgressStore.clear(workId: workId)
    }

    /// A hidden work never shows as the last-read widget entry, whenever its
    /// copy was saved, until it's unhidden (#209). Not in demo mode.
    @MainActor
    static func setLastReadHidden(_ workId: Int, hidden: Bool) {
        guard !FanficlyApp.isDemoMode else { return }
        WidgetProgressStore.setHidden(workId, hidden: hidden)
    }

    @MainActor
    static func deindexWork(ao3Id: Int) {
        CSSearchableIndex.default().deleteSearchableItems(
            withIdentifiers: [spotlightIdentifier(ao3Id: ao3Id)], completionHandler: nil)
    }

    /// Indexes every saved work without clearing the domain first, so
    /// Fanficly's Spotlight results stay up while it runs (indexing an item
    /// again replaces it). Run after `applyBackup` (an iCloud restore or a
    /// library file import): restored works skip `upsertMetadata`, and works
    /// it deletes leave through `delete`.
    @MainActor
    static func indexLibrary(context: ModelContext) {
        guard !FanficlyApp.isDemoMode else { return }
        let entries = ((try? context.fetch(FetchDescriptor<Work>())) ?? []).map { spotlightEntry(for: $0) }
        guard !entries.isEmpty else { return }
        CSSearchableIndex.default().indexSearchableItems(entries.map(searchableItem(for:)), completionHandler: nil)
    }

    /// Rebuilds the Spotlight index from the whole library: clears the domain,
    /// then indexes every saved work. Run once at launch (works saved before
    /// every library work was indexed, when only followed ones were).
    @MainActor
    static func reindexLibrary(context: ModelContext) {
        // Demo mode's library is in memory, but the index is the device's own.
        guard !FanficlyApp.isDemoMode else { return }
        let entries = ((try? context.fetch(FetchDescriptor<Work>())) ?? []).map { spotlightEntry(for: $0) }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [spotlightDomain]) { @Sendable _ in
            // Explicitly @Sendable: CoreSpotlight calls this off the main
            // actor, so it must not inherit this function's isolation.
            guard !entries.isEmpty else { return }
            CSSearchableIndex.default().indexSearchableItems(
                entries.map(searchableItem(for:)), completionHandler: nil)
        }
    }

    @MainActor
    static func isFollowed(workId: Int, in context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == workId })
        return (try? context.fetch(descriptor))?.first?.isFollowed ?? false
    }

    /// Whether a story is in the Library: saved, and not waiting behind the
    /// Undo toast to be removed. This is what "Save to Library" / "Remove
    /// from Library" shows, whether the story was saved, followed, downloaded
    /// or imported (#168).
    @MainActor
    static func isInLibrary(workId: Int, in context: ModelContext, undo: UndoCenter = .shared) -> Bool {
        guard !undo.isPending(UndoCenter.Key.work(workId)) else { return false }
        let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == workId })
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    /// The one "Save to Library" / "Remove from Library" action (#168), used
    /// by result rows, their context menus and the work page. Saving creates
    /// the story and follows it for new-chapter alerts. Removing deletes it
    /// fully, like Library → Delete: offline text, EPUB, note, tags, folder
    /// links and progress on the `Work` go with it, behind the Undo toast.
    /// Returns whether the story is in the Library afterwards.
    @MainActor
    @discardableResult
    static func toggleLibrary(summary: AO3WorkSummary, into context: ModelContext,
                              undoHost: UUID? = nil, undo: UndoCenter = .shared) -> Bool {
        setInLibrary(!isInLibrary(workId: summary.id, in: context, undo: undo), summary: summary,
                     into: context, undoHost: undoHost, undo: undo)
    }

    /// Saves (`true`) or removes (`false`) a story, as a button showing that
    /// action asks: a button acts on what it shows, so a row whose state is
    /// stale never deletes a story it offered to save. Saving a story that is
    /// already in the Library just keeps it. Returns whether the story is in
    /// the Library afterwards.
    @MainActor
    @discardableResult
    static func setInLibrary(_ wanted: Bool, summary: AO3WorkSummary, into context: ModelContext,
                             undoHost: UUID? = nil, undo: UndoCenter = .shared) -> Bool {
        guard !wanted else {
            saveToLibrary(summary: summary, into: context, undo: undo)
            return true
        }
        let workId = summary.id
        if !undo.isPending(UndoCenter.Key.work(workId)),
           let work = (try? context.fetch(FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == workId })))?.first {
            scheduleRemoval(work, in: context, undoHost: undoHost, undo: undo)
        }
        return false
    }

    /// Saves a story's metadata and follows it. A story whose removal is
    /// still behind the Undo toast keeps everything it had (#169).
    @MainActor
    @discardableResult
    static func saveToLibrary(summary: AO3WorkSummary, into context: ModelContext, undo: UndoCenter = .shared) -> Work {
        undo.cancel(UndoCenter.Key.work(summary.id))
        let work = upsertMetadata(summary: summary, into: context, save: false)
        if !work.isFollowed {
            work.isFollowed = true
            work.followedAt = .now
            work.lastSeenChapterCount = summary.chapterCount
            // Following opts into the poller's new-chapter alerts — the one
            // notification source that works fully logged out — so this is
            // the moment to ask for permission, not the login-gated
            // Subscriptions tab.
            NotificationsAuthorization.requestAfterFollow()
        }
        try? context.save()
        iCloudSyncManager.shared.queueBackup(context: context)
        return work
    }

    /// Removes a story from the Library behind the Undo toast (#169): it
    /// leaves every list at once and is deleted when the toast closes, with
    /// its offline text, EPUB, note, tags and folder links. Library → Delete
    /// and "Remove from Library" both come here.
    @MainActor
    static func scheduleRemoval(_ work: Work, in context: ModelContext,
                                undoHost: UUID? = nil, undo: UndoCenter = .shared) {
        undo.schedule(String(localized: "Deleted “\(work.title)”"),
                      keys: [UndoCenter.Key.work(work.ao3Id)],
                      host: undoHost) {
            guard !work.isDeleted, work.modelContext != nil else { return }
            iCloudSyncManager.recordDeletion(.work, key: String(work.ao3Id))
            delete(work, in: context)
            try? context.save()
            iCloudSyncManager.shared.queueBackup(context: context)
        }
    }

    /// The Library's copy of a story, if it's saved there.
    static func savedWork(ao3Id: Int, in context: ModelContext) -> Work? {
        var descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == ao3Id })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Record (or bump to "now") a work in the recently-viewed history,
    /// keeping its details for the row.
    @MainActor
    static func recordView(summary: AO3WorkSummary, into context: ModelContext, limit: Int = 50) {
        // History rows open the AO3 work page, which an imported book that
        // isn't on AO3 doesn't have; it stays in the Library instead.
        guard !EPUBImport.isLocalWork(summary.id) else { return }
        let ao3Id = summary.id
        let descriptor = FetchDescriptor<RecentlyViewed>(predicate: #Predicate { $0.ao3Id == ao3Id })
        if let existing = (try? context.fetch(descriptor))?.first {
            existing.viewedAt = .now
            existing.update(from: summary)
        } else {
            context.insert(RecentlyViewed(summary: summary))
        }

        let all = (try? context.fetch(FetchDescriptor<RecentlyViewed>(
            sortBy: [SortDescriptor(\.viewedAt, order: .reverse)]))) ?? []
        if all.count > limit {
            for stale in all[limit...] { context.delete(stale) }
        }
        try? context.save()
    }

    /// Overload for Library reads, which carry a `Work` rather than a summary.
    @MainActor
    static func recordView(work: Work, into context: ModelContext, limit: Int = 50) {
        recordView(summary: work.workSummary, into: context, limit: limit)
    }

    // MARK: - Followed authors

    @MainActor
    static func isAuthorFollowed(username: String, in context: ModelContext) -> Bool {
        guard !username.isEmpty else { return false }
        let descriptor = FetchDescriptor<FollowedAuthor>(predicate: #Predicate { $0.username == username })
        return ((try? context.fetch(descriptor))?.first) != nil
    }

    /// Toggle following an author. `seedWorkIds` are the work ids currently
    /// visible for the author at follow time, recorded so the poller doesn't
    /// alert for already-published works on its first check. Returns the new
    /// follow state.
    @MainActor
    @discardableResult
    static func toggleFollowAuthor(username: String, displayName: String,
                                   seedWorkIds: [Int] = [], into context: ModelContext) -> Bool {
        guard !username.isEmpty else { return false }
        let descriptor = FetchDescriptor<FollowedAuthor>(predicate: #Predicate { $0.username == username })
        if let existing = (try? context.fetch(descriptor))?.first {
            context.delete(existing)
            try? context.save()
            iCloudSyncManager.shared.queueBackup(context: context)
            return false
        } else {
            context.insert(FollowedAuthor(
                username: username,
                displayName: displayName.isEmpty ? username : displayName,
                knownWorkIds: seedWorkIds
            ))
            try? context.save()
            iCloudSyncManager.shared.queueBackup(context: context)
            NotificationsAuthorization.requestAfterFollow()  // see saveToLibrary
            return true
        }
    }

    /// Badges for one page of search/browse results, keyed by work id. One
    /// fetch per model for the whole page, never one per row.
    @MainActor
    static func resultBadges(for works: [AO3WorkSummary], in context: ModelContext,
                             undo: UndoCenter = .shared) -> [Int: ResultBadge] {
        guard !works.isEmpty else { return [:] }
        let ids = works.map(\.id)
        let saved = (try? context.fetch(FetchDescriptor<Work>(predicate: #Predicate { ids.contains($0.ao3Id) }))) ?? []
        let started = (try? context.fetch(FetchDescriptor<ReadingProgress>(predicate: #Predicate { ids.contains($0.ao3Id) }))) ?? []
        let stats = (try? context.fetch(FetchDescriptor<ReadingStat>(predicate: #Predicate { ids.contains($0.ao3Id) }))) ?? []
        let savedById = Dictionary(saved.map { ($0.ao3Id, $0) }, uniquingKeysWith: { first, _ in first })
        let startedIds = Set(started.map(\.ao3Id))
        let statById = Dictionary(stats.map { ($0.ao3Id, $0) }, uniquingKeysWith: { first, _ in first })

        var badges: [Int: ResultBadge] = [:]
        for work in works {
            // A story waiting behind the Undo toast to be removed is shown
            // as gone already (#168).
            let savedWork = undo.isPending(UndoCenter.Key.work(work.id)) ? nil : savedById[work.id]
            // The saved position, as the Library row shows it; a story read
            // without saving only has its stats row's furthest point.
            let progress = [savedWork?.lastReadProgress, statById[work.id]?.maxProgress]
                .compactMap { $0 }
                .first { $0 > 0 }
            badges[work.id] = resultBadge(
                inLibrary: savedWork != nil,
                started: startedIds.contains(work.id) || savedWork?.lastReadAt != nil,
                progress: progress,
                isComplete: work.isComplete
            )
        }
        return badges
    }

    /// The pure mapping behind a result row's badge. Reading status wins over
    /// "In Library"; "Finished" uses the Library row's rule (99%, or 95% of a
    /// complete work).
    static func resultBadge(inLibrary: Bool, started: Bool, progress: Double?, isComplete: Bool) -> ResultBadge? {
        if let raw = progress, raw.isFinite, raw > 0 {
            let p = min(raw, 1)
            if p >= 0.99 || (isComplete && p >= 0.95) { return .finished }
            return .percent(min(max(Int(p * 100), 1), 99))
        }
        if started { return .started }
        return inLibrary ? .inLibrary : nil
    }

    static let invalidEPUBSweepKey = "library.invalidEPUBSweep.v1"

    /// One-time: deletes `library/<id>.epub` files that aren't an e-book.
    /// Before downloads failed closed (#128), AO3's login page or an error
    /// page could be saved there, and `epubURL` only checks the file exists,
    /// so the work showed as Downloaded and nothing ever re-downloaded it.
    /// Returns the files it removed.
    @discardableResult
    static func removeInvalidEPUBsIfNeeded(defaults: UserDefaults = .standard,
                                           directory: URL? = nil) -> [URL] {
        guard !defaults.bool(forKey: invalidEPUBSweepKey) else { return [] }
        let fm = FileManager.default
        guard let dir = directory ?? (try? fm.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ))?.appendingPathComponent("library", isDirectory: true),
              let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        // Only once the folder could be listed, so a launch that can't read
        // it (or before the first download) doesn't use up the sweep.
        defaults.set(true, forKey: invalidEPUBSweepKey)
        var removed: [URL] = []
        for file in files where file.pathExtension == "epub" {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let head = (try? handle.read(upToCount: 68)) ?? Data()
            try? handle.close()
            if !AO3Client.isEbook(head), (try? fm.removeItem(at: file)) != nil {
                removed.append(file)
            }
        }
        return removed
    }

    /// The saved EPUB for a work (AO3's download or an imported book), if
    /// there is one. Only Export reads it (#173); Downloaded doesn't depend
    /// on it, since the saved EPUBs can be removed in Settings → Storage.
    static func epubURL(workId: Int) -> URL? {
        guard let dir = epubDirectory() else { return nil }
        let url = dir.appendingPathComponent("\(workId).epub")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Deletes one work's saved EPUB, if there is one.
    static func removeSavedEPUB(workId: Int) {
        if let url = epubURL(workId: workId) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// `Documents/library`, where saved EPUBs live.
    static func epubDirectory() -> URL? {
        (try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ))?.appendingPathComponent("library", isDirectory: true)
    }

    /// Downloaded means the story's text is saved on this device, so it reads
    /// offline (#173). The EPUB file is an extra copy for Export: a restore
    /// doesn't bring it back and Settings → Storage can remove them all, and
    /// neither should make a readable story look not downloaded.
    static func isDownloaded(_ work: Work) -> Bool {
        !work.chapters.isEmpty
    }

    @MainActor
    static func isDownloaded(workId: Int, in context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == workId })
        guard let work = (try? context.fetch(descriptor))?.first else { return false }
        return isDownloaded(work)
    }

    /// How many saved EPUBs there are and how many bytes they take, for
    /// Settings → Storage.
    struct EPUBStorage: Equatable, Sendable {
        var count: Int
        var bytes: Int64
    }

    static func savedEPUBStorage(directory: URL? = nil) -> EPUBStorage {
        var total = EPUBStorage(count: 0, bytes: 0)
        for file in savedEPUBFiles(directory: directory) {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total.count += 1
            total.bytes += Int64(size)
        }
        return total
    }

    /// Deletes every saved EPUB (Settings → Storage). The saved chapter text
    /// stays, so every story still reads offline, shows as Downloaded and
    /// exports (Export builds the EPUB from the text). Returns how many it
    /// removed.
    @discardableResult
    static func removeAllSavedEPUBs(directory: URL? = nil) -> Int {
        var removed = 0
        for file in savedEPUBFiles(directory: directory)
        where (try? FileManager.default.removeItem(at: file)) != nil {
            removed += 1
        }
        return removed
    }

    /// AO3 downloads only: an imported book that isn't on AO3 (a negative
    /// id) keeps its file, the only copy of the original with its pictures,
    /// which nothing can download again.
    private static func savedEPUBFiles(directory: URL?) -> [URL] {
        guard let dir = directory ?? epubDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey])
        else { return [] }
        return files.filter {
            guard $0.pathExtension.lowercased() == "epub" else { return false }
            let id = Int($0.deletingPathExtension().lastPathComponent)
            return !(id.map(EPUBImport.isLocalWork) ?? false)
        }
    }
}

/// Works you've left kudos on, remembered on this device so the kudos button
/// reads "Kudos Left" instead of inviting a second tap. Cleared on logout, so
/// it always belongs to the signed-in account (AO3 counts one kudo per
/// account) and no username is kept beside it. Not in the iCloud library
/// backup: AO3 itself still refuses a duplicate, which reads as already left.
enum KudosStore {
    static let key = "kudos.leftWorkIds"

    static func hasLeft(workId: Int, defaults: UserDefaults = .standard) -> Bool {
        workIds(defaults).contains(workId)
    }

    static func markLeft(workId: Int, defaults: UserDefaults = .standard) {
        var ids = workIds(defaults)
        guard !ids.contains(workId) else { return }
        ids.append(workId)
        defaults.set(ids, forKey: key)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    private static func workIds(_ defaults: UserDefaults) -> [Int] {
        defaults.array(forKey: key) as? [Int] ?? []
    }
}

/// The small status badge on a search or browse result row (RM-002).
enum ResultBadge: Equatable, Sendable {
    case finished
    case percent(Int)
    /// Opened in the reader, but no fraction is known yet.
    case started
    case inLibrary

    var text: String {
        switch self {
        case .finished:           "Finished"
        case .percent(let value): "\(value)%"
        case .started:            "Started"
        case .inLibrary:          "In Library"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .finished:           "Finished reading"
        case .percent(let value): "\(value) percent read"
        case .started:            "Started reading"
        case .inLibrary:          "In your Library"
        }
    }

    var symbol: String {
        switch self {
        case .finished:  "checkmark.circle.fill"
        case .percent:   "book"
        case .started:   "book"
        case .inLibrary: "books.vertical"
        }
    }
}
