import Foundation
import SwiftData

@MainActor
final class iCloudSyncManager {
    static let shared = iCloudSyncManager()
    
    private var backupTask: Task<Void, Never>? = nil
    
    private init() {}
    
    /// An optional local URL override for testing.
    static var overrideBackupURL: URL? = nil
    
    /// The URL to the backup file in the iCloud ubiquitous container.
    static var backupURL: URL? {
        if let overrideBackupURL { return overrideBackupURL }
        guard let ubiquityURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
        let docsURL = ubiquityURL.appendingPathComponent("Documents")
        try? FileManager.default.createDirectory(at: docsURL, withIntermediateDirectories: true)
        return docsURL.appendingPathComponent("library_backup.json")
    }
    
    /// Checks if a backup is available in iCloud (either downloaded or as a placeholder).
    var isBackupAvailable: Bool {
        guard let url = Self.backupURL else { return false }
        if FileManager.default.fileExists(atPath: url.path) {
            return true
        }
        let dir = url.deletingLastPathComponent()
        let filename = url.lastPathComponent
        let placeholderURL = dir.appendingPathComponent(".\(filename).icloud")
        return FileManager.default.fileExists(atPath: placeholderURL.path)
    }
    
    /// Where the copy of the backup each write replaces is kept, beside it:
    /// `library_backup.prev.json`.
    nonisolated static func previousBackupURL(for url: URL) -> URL {
        let name = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent()
            .appendingPathComponent("\(name).prev")
            .appendingPathExtension(url.pathExtension)
    }

    /// Why the last backup that didn't write the file stopped, or nil after
    /// one that did.
    private(set) var lastBackupFailure: String?

    /// Gets the modification date of the iCloud backup file.
    var lastBackupDate: Date? {
        guard let url = Self.backupURL else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }
    
    /// Triggers a debounced backup to iCloud.
    func queueBackup(context: ModelContext) {
        WidgetDataStore.updateAll(context: context)
        
        let iCloudEnabled = UserDefaults.standard.bool(forKey: "settings.iCloudSyncEnabled")
        guard iCloudEnabled else { return }
        
        backupTask?.cancel()
        backupTask = Task {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self.backupToiCloud(context: context)
        }
    }
    
    /// Performs a backup of the SwiftData database to iCloud, merging with the
    /// backup already in the cloud so a device that holds only part of the
    /// library (a fresh install, a metadata-only iPad) can never last-writer-
    /// wins away another device's records.
    func backupToiCloud(context: ModelContext) {
        guard let url = Self.backupURL else { return }

        // If the cloud backup isn't downloaded yet we can't merge with it, and
        // overwriting would drop every record the other device backed up.
        // iOS shows that as a `.icloud` placeholder; newer macOS keeps the
        // real name and reports it through the downloading status. Kick off
        // the download and let a later queueBackup (they fire on every
        // mutation) retry once it's local.
        if Self.isUndownloaded(url) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            lastBackupFailure = String(localized: "The backup in iCloud is still downloading. Fanficly will back up once it's on this device.")
            return
        }

        do {
            // 1. Fetch all records from SwiftData
            let works = (try? context.fetch(FetchDescriptor<Work>())) ?? []
            let bookmarks = (try? context.fetch(FetchDescriptor<BookmarkRecord>())) ?? []
            let subscriptions = (try? context.fetch(FetchDescriptor<SubscriptionRecord>())) ?? []
            let searches = (try? context.fetch(FetchDescriptor<SavedSearch>())) ?? []
            let progress = (try? context.fetch(FetchDescriptor<ReadingProgress>())) ?? []
            let filters = (try? context.fetch(FetchDescriptor<SavedFilter>())) ?? []
            let hidden = (try? context.fetch(FetchDescriptor<HiddenWork>())) ?? []
            let folders = (try? context.fetch(FetchDescriptor<CustomFolder>())) ?? []
            let readingStats = (try? context.fetch(FetchDescriptor<ReadingStat>())) ?? []
            let blockedTerms = (try? context.fetch(FetchDescriptor<BlockedTerm>())) ?? []
            
            // 2. Map them to Codable structures
            let workBackups = works.map { work in
                WorkBackup(
                    ao3Id: work.ao3Id,
                    title: work.title,
                    authorName: work.authorName,
                    authorUsername: work.authorUsername,
                    summary: work.summary,
                    rating: work.rating,
                    warnings: work.warnings,
                    categories: work.categories,
                    fandoms: work.fandoms,
                    characters: work.characters,
                    relationships: work.relationships,
                    freeforms: work.freeforms,
                    language: work.language,
                    wordCount: work.wordCount,
                    chapterCount: work.chapterCount,
                    totalChapters: work.totalChapters,
                    kudos: work.kudos,
                    hits: work.hits,
                    bookmarksCount: work.bookmarksCount,
                    commentsCount: work.commentsCount,
                    isComplete: work.isComplete,
                    publishedAt: work.publishedAt,
                    updatedAt: work.updatedAt,
                    savedAt: work.savedAt,
                    lastReadAt: work.lastReadAt,
                    lastReadChapter: work.lastReadChapter,
                    lastReadProgress: work.lastReadProgress,
                    isFollowed: work.isFollowed,
                    followedAt: work.followedAt,
                    lastSeenChapterCount: work.lastSeenChapterCount,
                    isStarred: work.isStarred,
                    isPinned: work.isPinned,
                    note: work.note,
                    personalTags: work.personalTags,
                    notesUpdatedAt: work.notesUpdatedAt,
                    chapters: work.chapters.sorted(by: { $0.index < $1.index }).map { ch in
                        ChapterBackup(index: ch.index, title: ch.title, bodyHTML: ch.bodyHTML, aoId: ch.aoId)
                    },
                    folderName: work.folders.first?.name,
                    folderNames: work.folders.map(\.name)
                )
            }
            
            let bookmarkBackups = bookmarks.map {
                BookmarkBackup(ao3Id: $0.ao3Id, workAo3Id: $0.workAo3Id, notes: $0.notes, tags: $0.tags, savedAt: $0.savedAt)
            }
            
            let subscriptionBackups = subscriptions.map {
                SubscriptionBackup(
                    key: $0.key,
                    kind: $0.kind,
                    displayName: $0.displayName,
                    authorName: $0.authorName,
                    lastSeenChapterCount: $0.lastSeenChapterCount,
                    lastCheckedAt: $0.lastCheckedAt
                )
            }
            
            let searchBackups = searches.map {
                SearchBackup(name: $0.name, prompt: $0.prompt, sortColumn: $0.sortColumn, sortDirection: $0.sortDirection, savedAt: $0.savedAt)
            }
            
            let progressBackups = progress.map {
                ProgressBackup(ao3Id: $0.ao3Id, chapterIndex: $0.chapterIndex, paragraphIndex: $0.paragraphIndex, title: $0.title, author: $0.author, updatedAt: $0.updatedAt)
            }
            
            let filterBackups = filters.map {
                FilterBackup(name: $0.name, filtersJSON: $0.filtersJSON, savedAt: $0.savedAt)
            }
            
            let hiddenBackups = hidden.map {
                HiddenBackup(ao3Id: $0.ao3Id, title: $0.title, hiddenAt: $0.hiddenAt)
            }
            
            let defaults = UserDefaults.standard
            let settingsBackup = SettingsBackup(
                theme: defaults.string(forKey: "reader.theme"),
                fontFamily: defaults.string(forKey: "reader.fontFamily"),
                width: defaults.string(forKey: "reader.width"),
                widthPercent: defaults.object(forKey: "reader.widthPercent") as? Double,
                mode: defaults.string(forKey: "reader.mode"),
                fontSizePt: defaults.object(forKey: "reader.fontSizePt") as? Double,
                lineSpacingPt: defaults.object(forKey: "reader.lineSpacingPt") as? Double,
                paragraphSpacingPt: defaults.object(forKey: "reader.paragraphSpacingPt") as? Double,
                pageTurnHaptics: defaults.object(forKey: "reader.pageTurnHaptics") as? Bool,
                pageTurnAnimations: defaults.object(forKey: "reader.pageTurnAnimations") as? Bool,
                kerningPt: defaults.object(forKey: "reader.kerningPt") as? Double,
                boldText: defaults.object(forKey: "reader.boldText") as? Bool,
                ttsRate: defaults.object(forKey: "reader.ttsRate") as? Double,
                ttsVoiceId: defaults.string(forKey: "reader.ttsVoiceId"),
                filterMatureExplicit: defaults.object(forKey: "content.filterMatureExplicit") as? Bool,
                ageConfirmed: defaults.object(forKey: "content.ageConfirmed") as? Bool,
                activeProfile: defaults.string(forKey: "reader.activeProfile"),
                activeProfilePhone: defaults.string(forKey: "reader.activeProfile.phone"),
                activeProfileMac: defaults.string(forKey: "reader.activeProfile.mac"),
                activeProfilePad: defaults.string(forKey: "reader.activeProfile.pad"),
                profiles: defaults.string(forKey: "reader.profiles"),
                
                themePhone: defaults.string(forKey: "reader.theme.phone"),
                themeMac: defaults.string(forKey: "reader.theme.mac"),
                themePad: defaults.string(forKey: "reader.theme.pad"),
                fontFamilyPhone: defaults.string(forKey: "reader.fontFamily.phone"),
                fontFamilyMac: defaults.string(forKey: "reader.fontFamily.mac"),
                fontFamilyPad: defaults.string(forKey: "reader.fontFamily.pad"),
                widthPercentPhone: defaults.object(forKey: "reader.widthPercent.phone") as? Double,
                widthPercentMac: defaults.object(forKey: "reader.widthPercent.mac") as? Double,
                widthPercentPad: defaults.object(forKey: "reader.widthPercent.pad") as? Double,
                modePhone: defaults.string(forKey: "reader.mode.phone"),
                modeMac: defaults.string(forKey: "reader.mode.mac"),
                modePad: defaults.string(forKey: "reader.mode.pad"),
                fontSizePtPhone: defaults.object(forKey: "reader.fontSizePt.phone") as? Double,
                fontSizePtMac: defaults.object(forKey: "reader.fontSizePt.mac") as? Double,
                fontSizePtPad: defaults.object(forKey: "reader.fontSizePt.pad") as? Double,
                lineSpacingPtPhone: defaults.object(forKey: "reader.lineSpacingPt.phone") as? Double,
                lineSpacingPtMac: defaults.object(forKey: "reader.lineSpacingPt.mac") as? Double,
                lineSpacingPtPad: defaults.object(forKey: "reader.lineSpacingPt.pad") as? Double,
                paragraphSpacingPtPhone: defaults.object(forKey: "reader.paragraphSpacingPt.phone") as? Double,
                paragraphSpacingPtMac: defaults.object(forKey: "reader.paragraphSpacingPt.mac") as? Double,
                paragraphSpacingPtPad: defaults.object(forKey: "reader.paragraphSpacingPt.pad") as? Double,
                pageTurnHapticsPhone: defaults.object(forKey: "reader.pageTurnHaptics.phone") as? Bool,
                pageTurnHapticsMac: defaults.object(forKey: "reader.pageTurnHaptics.mac") as? Bool,
                pageTurnHapticsPad: defaults.object(forKey: "reader.pageTurnHaptics.pad") as? Bool,
                pageTurnAnimationsPhone: defaults.object(forKey: "reader.pageTurnAnimations.phone") as? Bool,
                pageTurnAnimationsMac: defaults.object(forKey: "reader.pageTurnAnimations.mac") as? Bool,
                pageTurnAnimationsPad: defaults.object(forKey: "reader.pageTurnAnimations.pad") as? Bool,
                
                kerningPtPhone: defaults.object(forKey: "reader.kerningPt.phone") as? Double,
                kerningPtMac: defaults.object(forKey: "reader.kerningPt.mac") as? Double,
                kerningPtPad: defaults.object(forKey: "reader.kerningPt.pad") as? Double,
                boldTextPhone: defaults.object(forKey: "reader.boldText.phone") as? Bool,
                boldTextMac: defaults.object(forKey: "reader.boldText.mac") as? Bool,
                boldTextPad: defaults.object(forKey: "reader.boldText.pad") as? Bool
            )
            
            let folderBackups = folders.map {
                FolderBackup(name: $0.name, createdAt: $0.createdAt)
            }

            let statBackups = readingStats.map {
                StatBackup(
                    ao3Id: $0.ao3Id, title: $0.title, author: $0.author,
                    fandoms: $0.fandoms, categories: $0.categories, relationships: $0.relationships,
                    rating: $0.rating, wordCount: $0.wordCount,
                    firstReadAt: $0.firstReadAt, lastReadAt: $0.lastReadAt,
                    totalSeconds: $0.totalSeconds, daySeconds: $0.daySeconds,
                    maxProgress: $0.maxProgress, workIsComplete: $0.workIsComplete
                )
            }

            let blockedBackups = blockedTerms.map {
                BlockedBackup(kind: $0.kind, value: $0.value, createdAt: $0.createdAt)
            }

            var backup = LibraryBackup(
                works: workBackups,
                bookmarks: bookmarkBackups,
                subscriptions: subscriptionBackups,
                searches: searchBackups,
                progress: progressBackups,
                filters: filterBackups,
                hidden: hiddenBackups,
                settings: settingsBackup,
                folders: folderBackups,
                stats: statBackups,
                blocked: blockedBackups,
                timestamp: .now
            )

            // 3. Union with the backup already in the cloud. Only a file that
            // isn't there at all starts from the local snapshot alone: one
            // that can't be read (a download or file-coordination conflict)
            // or decoded (truncated, or a newer app's format) is left alone,
            // because writing this library over it would drop every other
            // device's records and restore couldn't bring them back.
            // Note whether that file held changes this device hasn't applied
            // yet: they go into the file, not into this library, so the file
            // we write isn't "applied here" until a restore pulls them in.
            // The read, merge and write happen inside one coordinated write,
            // so a file another device delivers can't land in between.
            var mergedUnappliedChanges = false
            var readError: (any Error)?
            var mergedWith: Data?
            try Self.updateBackup(at: url) { existing in
                switch existing {
                case .missing:
                    break
                case .unreadable(let error):
                    readError = error
                    return nil
                case .backup(let cloudBackup, let cloudData):
                    mergedUnappliedChanges = cloudBackupHasUnappliedChanges
                    backup = Self.mergedBackup(local: backup, cloud: cloudBackup)
                    mergedWith = cloudData
                }
                // 4. Serialize to JSON for the write, keeping the keys this app
                // doesn't know from the file it merged with (the Windows
                // app's fields, or a newer version's).
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(backup)
                guard let mergedWith else { return data }
                return try Self.preservingUnknownKeys(in: data, from: mergedWith, merged: backup)
            }
            if let readError {
                print("Skipped the iCloud backup, the existing backup can't be read: \(readError)")
                lastBackupFailure = String(localized: "The backup in iCloud couldn't be read, so it was left as it is. It may be damaged or from a newer version of Fanficly. Update Fanficly, or use Clear iCloud Data to start a new backup from this device.")
                return
            }
            lastBackupFailure = nil
            // When everything in the file came from this library (or was
            // already applied here), stamp it so the launch auto-sync doesn't
            // re-restore our own backup. When we merged in another device's
            // unapplied records, leave the stamp alone: the next launch sees
            // the file as changed and restores them into this library.
            if !mergedUnappliedChanges {
                markCloudBackupApplied()
            }
        } catch {
            print("Failed to backup to iCloud: \(error)")
            lastBackupFailure = error.localizedDescription
        }
    }

    // MARK: - Coordinated file access

    /// What reading the backup file found.
    enum BackupRead {
        /// There's no file (and no placeholder) at all.
        case missing
        /// The decoded backup and the file's bytes as read.
        case backup(LibraryBackup, Data)
        /// There's a file, but it couldn't be read or decoded.
        case unreadable(any Error)
    }

    /// Whether the backup exists in iCloud but isn't on this device yet: a
    /// `.icloud` placeholder (iOS), or a file whose contents haven't
    /// downloaded (newer macOS keeps the real name).
    nonisolated static func isUndownloaded(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        let placeholderURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        guard fileManager.fileExists(atPath: url.path) else {
            return fileManager.fileExists(atPath: placeholderURL.path)
        }
        // URL caches resource values, and callers poll this while waiting.
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let status = (try? fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus
        return status == .notDownloaded
    }

    /// Reads and decodes the backup through `NSFileCoordinator`, as Apple
    /// requires for files in the ubiquitous container.
    nonisolated static func readBackup(at url: URL) -> BackupRead {
        var result = BackupRead.missing
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = decodedBackup(at: readURL)
        }
        if let coordinationError { return .unreadable(coordinationError) }
        return result
    }

    /// Reads the backup, hands it to `body` and, when `body` returns data,
    /// writes that, all inside one coordinated write (`.forMerging`, Apple's
    /// option for read-modify-write) so another device's file can't arrive
    /// between the read and the write. The file being replaced is first kept
    /// as `library_backup.prev.json`, so one bad write can be undone by hand.
    nonisolated static func updateBackup(at url: URL, _ body: (BackupRead) throws -> Data?) throws {
        let fileManager = FileManager.default
        let previousURL = previousBackupURL(for: url)
        var coordinationError: NSError?
        var bodyError: (any Error)?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forMerging,
            writingItemAt: previousURL, options: .forReplacing,
            error: &coordinationError
        ) { writeURL, previousWriteURL in
            do {
                guard let data = try body(decodedBackup(at: writeURL)) else { return }
                if fileManager.fileExists(atPath: writeURL.path) {
                    do {
                        if fileManager.fileExists(atPath: previousWriteURL.path) {
                            try fileManager.removeItem(at: previousWriteURL)
                        }
                        try fileManager.copyItem(at: writeURL, to: previousWriteURL)
                    } catch {
                        print("Couldn't keep the previous iCloud backup: \(error)")
                    }
                }
                try data.write(to: writeURL, options: .atomic)
            } catch {
                bodyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let bodyError { throw bodyError }
    }

    // MARK: - Keys the other app wrote

    /// `encoded` (a merged backup) with the keys `cloudData` (the file it
    /// merged with) holds that this app doesn't know. The Apple and Windows
    /// apps add fields at different times (the Windows reader settings and
    /// followed authors, notes and tags before Windows had them), and a
    /// backup that dropped every key it couldn't decode would erase the other
    /// app's data from the file. The Windows app's `BackupUnknownKeys` does
    /// the same.
    /// - Top-level keys this app doesn't know are copied over whole.
    /// - Each record (and each work's chapter) the file also has, matched by
    ///   its identity key, gets back the keys this app doesn't know. Keys it
    ///   does know are never copied: a missing one can mean "cleared" (the
    ///   encoder omits nil optionals).
    /// - `settings` merge key by key: a key the file has and this device
    ///   doesn't is kept, known or not, because settings are only ever set,
    ///   never cleared.
    /// The known keys are each backup struct's stored properties (none of them
    /// customizes `CodingKeys`, so those are its JSON keys).
    nonisolated static func preservingUnknownKeys(in encoded: Data, from cloudData: Data, merged: LibraryBackup) throws -> Data {
        guard var output = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let file = (try? JSONSerialization.jsonObject(with: cloudData)) as? [String: Any] else { return encoded }
        var changed = false

        let topLevelKeys = propertyNames(of: merged)
        for (key, value) in file where !topLevelKeys.contains(key) && output[key] == nil {
            output[key] = value
            changed = true
        }

        if let fileSettings = file["settings"] as? [String: Any] {
            var settings = output["settings"] as? [String: Any] ?? [:]
            for (key, value) in fileSettings where settings[key] == nil {
                settings[key] = value
                changed = true
            }
            output["settings"] = settings
        }

        let chapterKeys = merged.works.lazy.compactMap(\.chapters.first).first.map(propertyNames(of:))
        let records: [(array: String, id: String, known: Set<String>?)] = [
            ("works", "ao3Id", merged.works.first.map(propertyNames(of:))),
            ("bookmarks", "ao3Id", merged.bookmarks.first.map(propertyNames(of:))),
            ("subscriptions", "key", merged.subscriptions.first.map(propertyNames(of:))),
            ("searches", "name", merged.searches.first.map(propertyNames(of:))),
            ("progress", "ao3Id", merged.progress.first.map(propertyNames(of:))),
            ("filters", "name", merged.filters.first.map(propertyNames(of:))),
            ("hidden", "ao3Id", merged.hidden.first.map(propertyNames(of:))),
            ("folders", "name", merged.folders?.first.map(propertyNames(of:))),
            ("stats", "ao3Id", merged.stats?.first.map(propertyNames(of:))),
        ]
        for (array, id, known) in records {
            guard let known,
                  var outRecords = output[array] as? [[String: Any]],
                  let fileRecords = file[array] as? [[String: Any]] else { continue }
            var fileById: [String: [String: Any]] = [:]
            for record in fileRecords {
                if let key = identity(record[id]), fileById[key] == nil { fileById[key] = record }
            }
            for i in outRecords.indices {
                guard let key = identity(outRecords[i][id]), let fileRecord = fileById[key] else { continue }
                if copyUnknownKeys(into: &outRecords[i], from: fileRecord, known: known) { changed = true }
                guard array == "works", let chapterKeys,
                      var chapters = outRecords[i]["chapters"] as? [[String: Any]],
                      let fileChapters = fileRecord["chapters"] as? [[String: Any]] else { continue }
                var fileByIndex: [String: [String: Any]] = [:]
                for chapter in fileChapters {
                    if let index = identity(chapter["index"]), fileByIndex[index] == nil { fileByIndex[index] = chapter }
                }
                var chaptersChanged = false
                for j in chapters.indices {
                    guard let index = identity(chapters[j]["index"]), let fileChapter = fileByIndex[index] else { continue }
                    if copyUnknownKeys(into: &chapters[j], from: fileChapter, known: chapterKeys) { chaptersChanged = true }
                }
                if chaptersChanged {
                    outRecords[i]["chapters"] = chapters
                    changed = true
                }
            }
            output[array] = outRecords
        }

        guard changed else { return encoded }
        return try JSONSerialization.data(withJSONObject: output, options: [.withoutEscapingSlashes])
    }

    private nonisolated static func propertyNames(of value: Any) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap(\.label))
    }

    private nonisolated static func identity(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private nonisolated static func copyUnknownKeys(into record: inout [String: Any], from fileRecord: [String: Any], known: Set<String>) -> Bool {
        var changed = false
        for (key, value) in fileRecord where !known.contains(key) && record[key] == nil {
            record[key] = value
            changed = true
        }
        return changed
    }

    /// Reads and decodes the backup at a URL a coordinator handed out.
    private nonisolated static func decodedBackup(at url: URL) -> BackupRead {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return .backup(try decoder.decode(LibraryBackup.self, from: data), data)
        } catch {
            return .unreadable(error)
        }
    }

    // MARK: - Launch auto-sync bookkeeping

    static let lastRestoredStampKey = "icloud.lastRestoredBackupDate"

    /// Whether the cloud backup has changed since this device last applied
    /// (or wrote) it — the launch auto-sync's cheap "anything new?" check.
    /// True when we can't tell (no stamp yet, or an undownloaded placeholder
    /// with no readable date): restore is a conservative merge, so restoring
    /// once too often is safe; skipping a real change is not.
    /// Any date other than the stamp counts, not just a later one: iCloud
    /// keeps the writing device's modification date, so a backup written
    /// offline (or on a device whose clock runs behind) can arrive older
    /// than this device's last write.
    var cloudBackupHasUnappliedChanges: Bool {
        guard let applied = UserDefaults.standard.object(forKey: Self.lastRestoredStampKey) as? Date,
              let cloudDate = lastBackupDate else { return true }
        return cloudDate != applied
    }

    /// Stamps `date` (the file's modification date when it was read, or just
    /// after it was written) as applied here. Pass the date from before a
    /// restore's read, so a file another device swaps in while the restore
    /// runs isn't marked applied unread.
    private func markCloudBackupApplied(date: Date? = nil) {
        UserDefaults.standard.set(date ?? lastBackupDate ?? Date(), forKey: Self.lastRestoredStampKey)
    }

    /// Unions a freshly-built local backup with the backup already in iCloud.
    /// Records the other device backed up but this one doesn't hold are kept;
    /// on conflicts the local record wins (this device just produced it), with
    /// the exceptions mirroring the restore rules: chapters survive from
    /// whichever side has more, reading positions keep the newer one, and
    /// reading stats merge conservatively.
    nonisolated static func mergedBackup(local: LibraryBackup, cloud: LibraryBackup) -> LibraryBackup {
        var worksById = Dictionary(cloud.works.map { ($0.ao3Id, $0) }, uniquingKeysWith: { a, _ in a })
        for var w in local.works {
            if let cloudWork = worksById[w.ao3Id] {
                if cloudWork.chapters.count > w.chapters.count {
                    w.chapters = cloudWork.chapters
                }
                let notes = mergedNotes(
                    local: WorkNotes(note: w.note, personalTags: w.personalTags ?? [], updatedAt: w.notesUpdatedAt),
                    other: WorkNotes(note: cloudWork.note, personalTags: cloudWork.personalTags ?? [], updatedAt: cloudWork.notesUpdatedAt)
                )
                w.note = notes.note
                w.personalTags = notes.personalTags
                w.notesUpdatedAt = notes.updatedAt
            }
            worksById[w.ao3Id] = w
        }

        var bookmarksById = Dictionary(cloud.bookmarks.map { ($0.ao3Id, $0) }, uniquingKeysWith: { a, _ in a })
        for b in local.bookmarks { bookmarksById[b.ao3Id] = b }

        var subscriptionsByKey = Dictionary(cloud.subscriptions.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for s in local.subscriptions { subscriptionsByKey[s.key] = s }

        var searchesByName = Dictionary(cloud.searches.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for s in local.searches { searchesByName[s.name] = s }

        var progressById = Dictionary(cloud.progress.map { ($0.ao3Id, $0) }, uniquingKeysWith: { a, _ in a })
        for p in local.progress {
            if let c = progressById[p.ao3Id], c.updatedAt > p.updatedAt { continue }
            progressById[p.ao3Id] = p
        }

        var filtersByName = Dictionary(cloud.filters.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for f in local.filters { filtersByName[f.name] = f }

        var hiddenById = Dictionary(cloud.hidden.map { ($0.ao3Id, $0) }, uniquingKeysWith: { a, _ in a })
        for h in local.hidden { hiddenById[h.ao3Id] = h }

        var foldersByName = Dictionary((cloud.folders ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for f in local.folders ?? [] { foldersByName[f.name] = f }

        var blockedByKey = Dictionary((cloud.blocked ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for b in local.blocked ?? [] { blockedByKey[b.key] = b }

        var statsById = Dictionary((cloud.stats ?? []).map { ($0.ao3Id, $0) }, uniquingKeysWith: { a, _ in a })
        for s in local.stats ?? [] {
            if let c = statsById[s.ao3Id] {
                statsById[s.ao3Id] = mergedStat(local: s, cloud: c)
            } else {
                statsById[s.ao3Id] = s
            }
        }

        return LibraryBackup(
            works: worksById.values.sorted { $0.ao3Id < $1.ao3Id },
            bookmarks: bookmarksById.values.sorted { $0.ao3Id < $1.ao3Id },
            subscriptions: subscriptionsByKey.values.sorted { $0.key < $1.key },
            searches: searchesByName.values.sorted { $0.name < $1.name },
            progress: progressById.values.sorted { $0.ao3Id < $1.ao3Id },
            filters: filtersByName.values.sorted { $0.name < $1.name },
            hidden: hiddenById.values.sorted { $0.ao3Id < $1.ao3Id },
            settings: local.settings ?? cloud.settings,
            folders: foldersByName.values.sorted { $0.name < $1.name },
            stats: statsById.values.sorted { $0.ao3Id < $1.ao3Id },
            blocked: blockedByKey.values.sorted { $0.key < $1.key },
            timestamp: local.timestamp
        )
    }

    /// A work's note and personal tags merge as one value. The side edited
    /// most recently wins, so clearing or changing a note reaches every
    /// device (ties go to local). Only when neither side has an edit stamp
    /// (data from before stamps existed) does the forward-only rule apply:
    /// an empty value never replaces a filled one, and local wins.
    nonisolated static func mergedNotes(local: WorkNotes, other: WorkNotes) -> WorkNotes {
        if local.updatedAt != nil || other.updatedAt != nil {
            return (other.updatedAt ?? .distantPast) > (local.updatedAt ?? .distantPast) ? other : local
        }
        return WorkNotes(
            note: mergedNote(local: local.note, other: other.note),
            personalTags: mergedPersonalTags(local: local.personalTags, other: other.personalTags),
            updatedAt: nil
        )
    }

    /// The unstamped note fallback: a non-empty note is never replaced by an
    /// empty one, and when both sides have one, local wins.
    nonisolated static func mergedNote(local: String?, other: String?) -> String? {
        if let local, !local.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return local }
        if let other, !other.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return other }
        return nil
    }

    /// The unstamped tags fallback, the same way as the note: local wins
    /// unless it's empty.
    nonisolated static func mergedPersonalTags(local: [String], other: [String]?) -> [String] {
        local.isEmpty ? (other ?? []) : local
    }

    /// The same conservative per-stat merge `restoreFromiCloud` applies: max of
    /// totals and per-day buckets, widest date span, non-empty metadata wins —
    /// and `totalSeconds` is lifted to at least Σ daySeconds, because per-day
    /// maxima from two devices can sum past either device's own total.
    nonisolated static func mergedStat(local: StatBackup, cloud: StatBackup) -> StatBackup {
        var daySeconds = local.daySeconds
        for (day, seconds) in cloud.daySeconds {
            daySeconds[day] = max(daySeconds[day] ?? 0, seconds)
        }
        let totalSeconds = max(max(local.totalSeconds, cloud.totalSeconds),
                               daySeconds.values.reduce(0, +))
        return StatBackup(
            ao3Id: local.ao3Id,
            title: local.title.isEmpty ? cloud.title : local.title,
            author: local.author.isEmpty ? cloud.author : local.author,
            fandoms: local.fandoms.isEmpty ? cloud.fandoms : local.fandoms,
            categories: local.categories.isEmpty ? cloud.categories : local.categories,
            relationships: local.relationships.isEmpty ? cloud.relationships : local.relationships,
            rating: local.rating.isEmpty ? cloud.rating : local.rating,
            wordCount: local.wordCount > 0 ? local.wordCount : cloud.wordCount,
            firstReadAt: min(local.firstReadAt, cloud.firstReadAt),
            lastReadAt: max(local.lastReadAt, cloud.lastReadAt),
            totalSeconds: totalSeconds,
            daySeconds: daySeconds,
            maxProgress: max(local.maxProgress ?? 0, cloud.maxProgress ?? 0),
            workIsComplete: (local.workIsComplete == true) || (cloud.workIsComplete == true)
        )
    }

    /// Restores all records from iCloud backup. Returns true if successful.
    @discardableResult
    func restoreFromiCloud(context: ModelContext) async -> Bool {
        guard let url = Self.backupURL else {
            return false
        }
        
        let fileManager = FileManager.default
        // Not downloaded yet (an iOS `.icloud` placeholder, or a file under
        // its real name on newer macOS): start the download and wait up to
        // 5 seconds, rather than block on a coordinated read of it.
        if Self.isUndownloaded(url) {
            do {
                try fileManager.startDownloadingUbiquitousItem(at: url)
            } catch {
                print("Failed to download ubiquitous item: \(error)")
                return false
            }
            var downloaded = false
            for _ in 0..<25 {
                if !Self.isUndownloaded(url), fileManager.fileExists(atPath: url.path) {
                    downloaded = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            if !downloaded {
                print("iCloud backup download timed out")
                return false
            }
        }
        
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }
        let readDate = lastBackupDate
        
        let backup: LibraryBackup
        switch Self.readBackup(at: url) {
        case .missing:
            return false
        case .unreadable(let error):
            print("Failed to restore from iCloud: \(error)")
            return false
        case .backup(let read, _):
            backup = read
        }

        do {
            // 0. Restore settings and themes
            if let s = backup.settings {
                let defaults = UserDefaults.standard
                if let theme = s.theme { defaults.set(theme, forKey: "reader.theme") }
                if let fontFamily = s.fontFamily { defaults.set(fontFamily, forKey: "reader.fontFamily") }
                if let width = s.width { defaults.set(width, forKey: "reader.width") }
                if let widthPercent = s.widthPercent { defaults.set(widthPercent, forKey: "reader.widthPercent") }
                if let mode = s.mode { defaults.set(mode, forKey: "reader.mode") }
                if let fontSizePt = s.fontSizePt { defaults.set(fontSizePt, forKey: "reader.fontSizePt") }
                if let lineSpacingPt = s.lineSpacingPt { defaults.set(lineSpacingPt, forKey: "reader.lineSpacingPt") }
                if let paragraphSpacingPt = s.paragraphSpacingPt { defaults.set(paragraphSpacingPt, forKey: "reader.paragraphSpacingPt") }
                if let pageTurnHaptics = s.pageTurnHaptics { defaults.set(pageTurnHaptics, forKey: "reader.pageTurnHaptics") }
                if let pageTurnAnimations = s.pageTurnAnimations { defaults.set(pageTurnAnimations, forKey: "reader.pageTurnAnimations") }
                if let kerningPt = s.kerningPt { defaults.set(kerningPt, forKey: "reader.kerningPt") }
                if let boldText = s.boldText { defaults.set(boldText, forKey: "reader.boldText") }
                if let ttsRate = s.ttsRate { defaults.set(ttsRate, forKey: "reader.ttsRate") }
                if let ttsVoiceId = s.ttsVoiceId { defaults.set(ttsVoiceId, forKey: "reader.ttsVoiceId") }
                if let filterMatureExplicit = s.filterMatureExplicit { defaults.set(filterMatureExplicit, forKey: "content.filterMatureExplicit") }
                if let ageConfirmed = s.ageConfirmed { defaults.set(ageConfirmed, forKey: "content.ageConfirmed") }
                if let activeProfile = s.activeProfile { defaults.set(activeProfile, forKey: "reader.activeProfile") }
                if let activeProfilePhone = s.activeProfilePhone { defaults.set(activeProfilePhone, forKey: "reader.activeProfile.phone") }
                if let activeProfileMac = s.activeProfileMac { defaults.set(activeProfileMac, forKey: "reader.activeProfile.mac") }
                if let activeProfilePad = s.activeProfilePad { defaults.set(activeProfilePad, forKey: "reader.activeProfile.pad") }
                if let profiles = s.profiles {
                    let mergedProfiles = ReaderProfile.mergedProfiles(
                        localJSON: defaults.string(forKey: "reader.profiles"),
                        incomingJSON: profiles
                    )
                    defaults.set(mergedProfiles, forKey: "reader.profiles")
                    ReaderProfileSyncStore.publishLocalProfiles(mergedProfiles)
                }

                // Device-specific settings
                if let themePhone = s.themePhone { defaults.set(themePhone, forKey: "reader.theme.phone") }
                if let themeMac = s.themeMac { defaults.set(themeMac, forKey: "reader.theme.mac") }
                if let themePad = s.themePad { defaults.set(themePad, forKey: "reader.theme.pad") }
                if let fontFamilyPhone = s.fontFamilyPhone { defaults.set(fontFamilyPhone, forKey: "reader.fontFamily.phone") }
                if let fontFamilyMac = s.fontFamilyMac { defaults.set(fontFamilyMac, forKey: "reader.fontFamily.mac") }
                if let fontFamilyPad = s.fontFamilyPad { defaults.set(fontFamilyPad, forKey: "reader.fontFamily.pad") }
                if let widthPercentPhone = s.widthPercentPhone { defaults.set(widthPercentPhone, forKey: "reader.widthPercent.phone") }
                if let widthPercentMac = s.widthPercentMac { defaults.set(widthPercentMac, forKey: "reader.widthPercent.mac") }
                if let widthPercentPad = s.widthPercentPad { defaults.set(widthPercentPad, forKey: "reader.widthPercent.pad") }
                if let modePhone = s.modePhone { defaults.set(modePhone, forKey: "reader.mode.phone") }
                if let modeMac = s.modeMac { defaults.set(modeMac, forKey: "reader.mode.mac") }
                if let modePad = s.modePad { defaults.set(modePad, forKey: "reader.mode.pad") }
                if let fontSizePtPhone = s.fontSizePtPhone { defaults.set(fontSizePtPhone, forKey: "reader.fontSizePt.phone") }
                if let fontSizePtMac = s.fontSizePtMac { defaults.set(fontSizePtMac, forKey: "reader.fontSizePt.mac") }
                if let fontSizePtPad = s.fontSizePtPad { defaults.set(fontSizePtPad, forKey: "reader.fontSizePt.pad") }
                if let lineSpacingPtPhone = s.lineSpacingPtPhone { defaults.set(lineSpacingPtPhone, forKey: "reader.lineSpacingPt.phone") }
                if let lineSpacingPtMac = s.lineSpacingPtMac { defaults.set(lineSpacingPtMac, forKey: "reader.lineSpacingPt.mac") }
                if let lineSpacingPtPad = s.lineSpacingPtPad { defaults.set(lineSpacingPtPad, forKey: "reader.lineSpacingPt.pad") }
                if let paragraphSpacingPtPhone = s.paragraphSpacingPtPhone { defaults.set(paragraphSpacingPtPhone, forKey: "reader.paragraphSpacingPt.phone") }
                if let paragraphSpacingPtMac = s.paragraphSpacingPtMac { defaults.set(paragraphSpacingPtMac, forKey: "reader.paragraphSpacingPt.mac") }
                if let paragraphSpacingPtPad = s.paragraphSpacingPtPad { defaults.set(paragraphSpacingPtPad, forKey: "reader.paragraphSpacingPt.pad") }
                if let pageTurnHapticsPhone = s.pageTurnHapticsPhone { defaults.set(pageTurnHapticsPhone, forKey: "reader.pageTurnHaptics.phone") }
                if let pageTurnHapticsMac = s.pageTurnHapticsMac { defaults.set(pageTurnHapticsMac, forKey: "reader.pageTurnHaptics.mac") }
                if let pageTurnHapticsPad = s.pageTurnHapticsPad { defaults.set(pageTurnHapticsPad, forKey: "reader.pageTurnHaptics.pad") }
                if let pageTurnAnimationsPhone = s.pageTurnAnimationsPhone { defaults.set(pageTurnAnimationsPhone, forKey: "reader.pageTurnAnimations.phone") }
                if let pageTurnAnimationsMac = s.pageTurnAnimationsMac { defaults.set(pageTurnAnimationsMac, forKey: "reader.pageTurnAnimations.mac") }
                if let pageTurnAnimationsPad = s.pageTurnAnimationsPad { defaults.set(pageTurnAnimationsPad, forKey: "reader.pageTurnAnimations.pad") }
                
                if let kerningPtPhone = s.kerningPtPhone { defaults.set(kerningPtPhone, forKey: "reader.kerningPt.phone") }
                if let kerningPtMac = s.kerningPtMac { defaults.set(kerningPtMac, forKey: "reader.kerningPt.mac") }
                if let kerningPtPad = s.kerningPtPad { defaults.set(kerningPtPad, forKey: "reader.kerningPt.pad") }
                if let boldTextPhone = s.boldTextPhone { defaults.set(boldTextPhone, forKey: "reader.boldText.phone") }
                if let boldTextMac = s.boldTextMac { defaults.set(boldTextMac, forKey: "reader.boldText.mac") }
                if let boldTextPad = s.boldTextPad { defaults.set(boldTextPad, forKey: "reader.boldText.pad") }
            }
            
            // 0.5. Restore CustomFolders
            if let customFolders = backup.folders {
                for f in customFolders {
                    let descriptor = FetchDescriptor<CustomFolder>(predicate: #Predicate { $0.name == f.name })
                    let existing = (try? context.fetch(descriptor))?.first
                    if existing == nil {
                        context.insert(CustomFolder(name: f.name, createdAt: f.createdAt))
                    }
                }
            }
            
            // 1. Restore Works and their Chapters
            for w in backup.works {
                let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == w.ao3Id })
                let existing = (try? context.fetch(descriptor))?.first
                
                let work: Work
                if let existing {
                    work = existing
                } else {
                    work = Work(ao3Id: w.ao3Id, title: w.title, authorName: w.authorName)
                    context.insert(work)
                }
                
                work.title = w.title
                work.authorName = w.authorName
                work.authorUsername = w.authorUsername
                work.summary = w.summary
                work.rating = w.rating
                work.warnings = w.warnings
                work.categories = w.categories
                work.fandoms = w.fandoms
                work.characters = w.characters
                work.relationships = w.relationships
                work.freeforms = w.freeforms
                work.language = w.language
                work.wordCount = w.wordCount
                work.chapterCount = w.chapterCount
                work.totalChapters = w.totalChapters
                work.kudos = w.kudos
                work.hits = w.hits
                work.bookmarksCount = w.bookmarksCount
                work.commentsCount = w.commentsCount
                work.isComplete = w.isComplete
                work.publishedAt = w.publishedAt
                work.updatedAt = w.updatedAt
                work.savedAt = w.savedAt
                // Reading position: keep whichever side read more recently.
                // Restore also runs as a background launch sync now, which
                // must never rewind this device to an older backup.
                if (w.lastReadAt ?? .distantPast) > (work.lastReadAt ?? .distantPast) {
                    work.lastReadAt = w.lastReadAt
                    work.lastReadChapter = w.lastReadChapter
                    work.lastReadProgress = w.lastReadProgress
                }
                // Follow/star/pin merge as an OR: the cloud union can lag a
                // flag set locally moments ago, and un-flagging deliberately
                // doesn't propagate (same rule as mergedBackup).
                work.isFollowed = work.isFollowed || w.isFollowed
                if work.followedAt == nil { work.followedAt = w.followedAt }
                // Notification baseline only advances — regressing it would
                // re-fire "new chapter" alerts for chapters already seen.
                if let cloudSeen = w.lastSeenChapterCount {
                    work.lastSeenChapterCount = max(work.lastSeenChapterCount ?? 0, cloudSeen)
                }
                work.isStarred = work.isStarred || (w.isStarred ?? false)
                work.isPinned = work.isPinned || (w.isPinned ?? false)
                // Note and personal tags: the newest edit wins (see
                // mergedNotes), so an older backup never undoes an edit here.
                let notes = Self.mergedNotes(
                    local: WorkNotes(note: work.note, personalTags: work.personalTags, updatedAt: work.notesUpdatedAt),
                    other: WorkNotes(note: w.note, personalTags: w.personalTags ?? [], updatedAt: w.notesUpdatedAt)
                )
                if notes != WorkNotes(note: work.note, personalTags: work.personalTags, updatedAt: work.notesUpdatedAt) {
                    work.note = notes.note
                    work.personalTags = notes.personalTags
                    work.notesUpdatedAt = notes.updatedAt
                }

                work.folder = nil // clear legacy single folder reference
                // Folders union, not replace: a launch sync must not drop an
                // assignment made locally since the last backup.
                let folderNames = w.folderNames ?? w.folderName.map { [$0] } ?? []
                for fName in folderNames where !work.folders.contains(where: { $0.name == fName }) {
                    let folderDescriptor = FetchDescriptor<CustomFolder>(predicate: #Predicate { $0.name == fName })
                    if let folder = (try? context.fetch(folderDescriptor))?.first {
                        work.folders.append(folder)
                    }
                }
                
                // Replace chapters only when the backup carries more than we
                // hold: a metadata-only backup (chapters: []) or a stale
                // partial download must not wipe a fuller offline download —
                // the Downloaded badge keys off the epub file, so deleting
                // here would silently strand it.
                if w.chapters.count > work.chapters.count {
                    // Clear existing chapters first to prevent duplicates
                    for ch in work.chapters { context.delete(ch) }
                    work.chapters.removeAll()

                    for ch in w.chapters {
                        let chapter = Chapter(work: work, index: ch.index, title: ch.title, bodyHTML: ch.bodyHTML, aoId: ch.aoId)
                        context.insert(chapter)
                    }
                }
            }
            
            // 2. Restore BookmarkRecords
            for b in backup.bookmarks {
                let descriptor = FetchDescriptor<BookmarkRecord>(predicate: #Predicate { $0.ao3Id == b.ao3Id })
                let existing = (try? context.fetch(descriptor))?.first
                if let existing {
                    existing.workAo3Id = b.workAo3Id
                    existing.notes = b.notes
                    existing.tags = b.tags
                    existing.savedAt = b.savedAt
                } else {
                    context.insert(BookmarkRecord(ao3Id: b.ao3Id, workAo3Id: b.workAo3Id, notes: b.notes, tags: b.tags, savedAt: b.savedAt))
                }
            }
            
            // 3. Restore SubscriptionRecords
            for s in backup.subscriptions {
                let descriptor = FetchDescriptor<SubscriptionRecord>(predicate: #Predicate { $0.key == s.key })
                let existing = (try? context.fetch(descriptor))?.first
                if let existing {
                    existing.kind = s.kind
                    existing.displayName = s.displayName
                    existing.authorName = s.authorName
                    existing.lastSeenChapterCount = s.lastSeenChapterCount
                    existing.lastCheckedAt = s.lastCheckedAt
                } else {
                    let rec = SubscriptionRecord(key: s.key, kind: s.kind, displayName: s.displayName, authorName: s.authorName)
                    rec.lastSeenChapterCount = s.lastSeenChapterCount
                    rec.lastCheckedAt = s.lastCheckedAt
                    context.insert(rec)
                }
            }
            
            // 4. Restore SavedSearches
            for s in backup.searches {
                let descriptor = FetchDescriptor<SavedSearch>(predicate: #Predicate { $0.name == s.name })
                let existing = (try? context.fetch(descriptor))?.first
                if let existing {
                    existing.prompt = s.prompt
                    existing.sortColumn = s.sortColumn
                    existing.sortDirection = s.sortDirection
                    existing.savedAt = s.savedAt
                } else {
                    context.insert(SavedSearch(name: s.name, prompt: s.prompt, sortColumn: s.sortColumn, sortDirection: s.sortDirection, savedAt: s.savedAt))
                }
            }
            
            // 5. Restore ReadingProgress entries — newer side wins, so a
            // background sync can only advance a position, never rewind it.
            for p in backup.progress {
                let descriptor = FetchDescriptor<ReadingProgress>(predicate: #Predicate { $0.ao3Id == p.ao3Id })
                let existing = (try? context.fetch(descriptor))?.first
                if let existing {
                    if p.updatedAt > existing.updatedAt {
                        existing.chapterIndex = p.chapterIndex
                        existing.paragraphIndex = p.paragraphIndex
                        existing.title = p.title
                        existing.author = p.author
                        existing.updatedAt = p.updatedAt
                    }
                } else {
                    context.insert(ReadingProgress(ao3Id: p.ao3Id, chapterIndex: p.chapterIndex, paragraphIndex: p.paragraphIndex, title: p.title, author: p.author, updatedAt: p.updatedAt))
                }
            }
            
            // 6. Restore SavedFilters
            for f in backup.filters {
                let descriptor = FetchDescriptor<SavedFilter>(predicate: #Predicate { $0.name == f.name })
                let existing = (try? context.fetch(descriptor))?.first
                if let existing {
                    existing.filtersJSON = f.filtersJSON
                    existing.savedAt = f.savedAt
                } else {
                    context.insert(SavedFilter(name: f.name, filtersJSON: f.filtersJSON, savedAt: f.savedAt))
                }
            }
            
            // 7. Restore HiddenWorks
            for h in backup.hidden {
                let descriptor = FetchDescriptor<HiddenWork>(predicate: #Predicate { $0.ao3Id == h.ao3Id })
                let existing = (try? context.fetch(descriptor))?.first
                if let existing {
                    existing.title = h.title
                    existing.hiddenAt = h.hiddenAt
                } else {
                    context.insert(HiddenWork(ao3Id: h.ao3Id, title: h.title, hiddenAt: h.hiddenAt))
                }
            }
            
            // 8. Restore BlockedTerms: add any this device lacks (a union, so
            // unblocking on one device doesn't propagate, like hidden works).
            for b in backup.blocked ?? [] {
                guard let kind = BlockedTermKind(rawValue: b.kind) else { continue }
                let key = b.key
                let descriptor = FetchDescriptor<BlockedTerm>(predicate: #Predicate { $0.key == key })
                if ((try? context.fetch(descriptor))?.first) == nil {
                    context.insert(BlockedTerm(kind: kind, value: b.value, createdAt: b.createdAt))
                }
            }

            // 9. Restore ReadingStats. Merge conservatively — take the larger of
            // the two totals and the per-day maxima, and the widest date span —
            // so syncing two devices never double-counts or loses reading time.
            for st in (backup.stats ?? []) {
                let descriptor = FetchDescriptor<ReadingStat>(predicate: #Predicate { $0.ao3Id == st.ao3Id })
                if let existing = (try? context.fetch(descriptor))?.first {
                    if !st.fandoms.isEmpty { existing.fandoms = st.fandoms }
                    if !st.categories.isEmpty { existing.categories = st.categories }
                    if !st.relationships.isEmpty { existing.relationships = st.relationships }
                    if !st.rating.isEmpty { existing.rating = st.rating }
                    if st.wordCount > 0 { existing.wordCount = st.wordCount }
                    if !st.title.isEmpty { existing.title = st.title }
                    if !st.author.isEmpty { existing.author = st.author }
                    existing.totalSeconds = max(existing.totalSeconds, st.totalSeconds)
                    existing.firstReadAt = min(existing.firstReadAt, st.firstReadAt)
                    existing.lastReadAt = max(existing.lastReadAt, st.lastReadAt)
                    existing.maxProgress = max(existing.maxProgress, st.maxProgress ?? 0)
                    if st.workIsComplete == true { existing.workIsComplete = true }
                    var merged = existing.daySeconds
                    for (day, seconds) in st.daySeconds {
                        merged[day] = max(merged[day] ?? 0, seconds)
                    }
                    existing.daySeconds = merged
                    // Per-day maxima from two devices can sum past either
                    // device's own total (iPhone read Monday, iPad Tuesday),
                    // which would leave All Time showing less than a single
                    // period. Lift the total back to Σ daySeconds.
                    existing.totalSeconds = max(existing.totalSeconds, merged.values.reduce(0, +))
                } else {
                    context.insert(ReadingStat(
                        ao3Id: st.ao3Id, title: st.title, author: st.author,
                        fandoms: st.fandoms, categories: st.categories, relationships: st.relationships,
                        rating: st.rating, wordCount: st.wordCount,
                        firstReadAt: st.firstReadAt, lastReadAt: st.lastReadAt,
                        totalSeconds: st.totalSeconds, daySeconds: st.daySeconds,
                        maxProgress: st.maxProgress ?? 0, workIsComplete: st.workIsComplete ?? false
                    ))
                }
            }

            try context.save()
            markCloudBackupApplied(date: readDate)
            return true
        } catch {
            print("Failed to restore from iCloud: \(error)")
            return false
        }
    }
    
    /// Deletes the backup file (and the copy of the previous one) from iCloud.
    @discardableResult
    func clearFromiCloud() -> Bool {
        guard let url = Self.backupURL else { return false }
        let previousURL = Self.previousBackupURL(for: url)
        if FileManager.default.fileExists(atPath: previousURL.path) {
            try? FileManager.default.removeItem(at: previousURL)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            print("Failed to clear iCloud backup: \(error)")
            return false
        }
    }

}

// MARK: - Backup Codable Structs

struct LibraryBackup: Codable {
    let works: [WorkBackup]
    let bookmarks: [BookmarkBackup]
    let subscriptions: [SubscriptionBackup]
    let searches: [SearchBackup]
    let progress: [ProgressBackup]
    let filters: [FilterBackup]
    let hidden: [HiddenBackup]
    let settings: SettingsBackup?
    let folders: [FolderBackup]?
    /// Optional so older backups (written before the Stats feature) still decode.
    let stats: [StatBackup]?
    /// Blocked tags and authors (RM-006). Optional so older backups still
    /// decode; defaulted so existing initializer calls still compile.
    var blocked: [BlockedBackup]? = nil
    let timestamp: Date
}

struct BlockedBackup: Codable {
    let kind: String
    let value: String
    let createdAt: Date

    var key: String { BlockedTerm.key(kind: kind, value: value) }
}

struct FolderBackup: Codable {
    let name: String
    let createdAt: Date
}

struct StatBackup: Codable {
    let ao3Id: Int
    let title: String
    let author: String
    let fandoms: [String]
    let categories: [String]
    let relationships: [String]
    let rating: String
    let wordCount: Int
    let firstReadAt: Date
    let lastReadAt: Date
    let totalSeconds: Double
    let daySeconds: [String: Double]
    // Optional so backups written before these fields still decode.
    let maxProgress: Double?
    let workIsComplete: Bool?
}

struct SettingsBackup: Codable {
    let theme: String?
    let fontFamily: String?
    let width: String?
    let widthPercent: Double?
    let mode: String?
    let fontSizePt: Double?
    let lineSpacingPt: Double?
    let paragraphSpacingPt: Double?
    let pageTurnHaptics: Bool?
    let pageTurnAnimations: Bool?
    let kerningPt: Double?
    let boldText: Bool?
    let ttsRate: Double?
    let ttsVoiceId: String?
    let filterMatureExplicit: Bool?
    let ageConfirmed: Bool?
    let activeProfile: String?
    let activeProfilePhone: String?
    let activeProfileMac: String?
    let activeProfilePad: String?
    let profiles: String?

    // Device-specific settings
    let themePhone: String?
    let themeMac: String?
    let themePad: String?
    let fontFamilyPhone: String?
    let fontFamilyMac: String?
    let fontFamilyPad: String?
    let widthPercentPhone: Double?
    let widthPercentMac: Double?
    let widthPercentPad: Double?
    let modePhone: String?
    let modeMac: String?
    let modePad: String?
    let fontSizePtPhone: Double?
    let fontSizePtMac: Double?
    let fontSizePtPad: Double?
    let lineSpacingPtPhone: Double?
    let lineSpacingPtMac: Double?
    let lineSpacingPtPad: Double?
    let paragraphSpacingPtPhone: Double?
    let paragraphSpacingPtMac: Double?
    let paragraphSpacingPtPad: Double?
    let pageTurnHapticsPhone: Bool?
    let pageTurnHapticsMac: Bool?
    let pageTurnHapticsPad: Bool?
    let pageTurnAnimationsPhone: Bool?
    let pageTurnAnimationsMac: Bool?
    let pageTurnAnimationsPad: Bool?
    
    let kerningPtPhone: Double?
    let kerningPtMac: Double?
    let kerningPtPad: Double?
    let boldTextPhone: Bool?
    let boldTextMac: Bool?
    let boldTextPad: Bool?
}

struct WorkBackup: Codable {
    let ao3Id: Int
    let title: String
    let authorName: String
    let authorUsername: String
    let summary: String
    let rating: String
    let warnings: [String]
    let categories: [String]
    let fandoms: [String]
    let characters: [String]
    let relationships: [String]
    let freeforms: [String]
    let language: String
    let wordCount: Int
    let chapterCount: Int
    let totalChapters: Int?
    let kudos: Int
    let hits: Int
    let bookmarksCount: Int
    let commentsCount: Int
    let isComplete: Bool
    let publishedAt: Date?
    let updatedAt: Date?
    let savedAt: Date
    let lastReadAt: Date?
    let lastReadChapter: Int?
    let lastReadProgress: Double?
    let isFollowed: Bool
    let followedAt: Date?
    let lastSeenChapterCount: Int?
    let isStarred: Bool?
    let isPinned: Bool?
    /// Optional so backups from before notes and personal tags still decode;
    /// `var` so the backup merge can take the cloud copy's when it's newer.
    var note: String?
    var personalTags: [String]?
    var notesUpdatedAt: Date?
    /// `var` so the backup merge can graft the cloud copy's chapters onto a
    /// local metadata-only record.
    var chapters: [ChapterBackup]
    let folderName: String?
    let folderNames: [String]?
}

/// A work's note, personal tags and when they were last edited, merged as
/// one value (`iCloudSyncManager.mergedNotes`).
struct WorkNotes: Equatable, Sendable {
    var note: String?
    var personalTags: [String]
    var updatedAt: Date?
}

struct ChapterBackup: Codable {
    let index: Int
    let title: String
    let bodyHTML: String
    /// AO3 chapter id (drives per-chapter comments). Optional so backups
    /// written before this field still decode.
    let aoId: Int?
}

struct BookmarkBackup: Codable {
    let ao3Id: Int
    let workAo3Id: Int
    let notes: String
    let tags: [String]
    let savedAt: Date
}

struct SubscriptionBackup: Codable {
    let key: String
    let kind: String
    let displayName: String
    let authorName: String
    let lastSeenChapterCount: Int?
    let lastCheckedAt: Date?
}

struct SearchBackup: Codable {
    let name: String
    let prompt: String
    let sortColumn: String
    let sortDirection: String
    let savedAt: Date
}

struct ProgressBackup: Codable {
    let ao3Id: Int
    let chapterIndex: Int
    let paragraphIndex: Int
    let title: String
    let author: String
    let updatedAt: Date
}

struct FilterBackup: Codable {
    let name: String
    let filtersJSON: String
    let savedAt: Date
}

struct HiddenBackup: Codable {
    let ao3Id: Int
    let title: String
    let hiddenAt: Date
}
