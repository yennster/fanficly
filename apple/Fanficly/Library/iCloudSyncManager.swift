import Foundation
import SwiftData
import UIKit

@MainActor
final class iCloudSyncManager {
    static let shared = iCloudSyncManager()
    
    private var backupTask: Task<Void, Never>? = nil
    /// The latest background write; the next one waits for it.
    private var lastWrite: Task<BackupOutcome, Never>? = nil
    
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

    /// How the last backup went; nil before the first one.
    private(set) var lastBackupOutcome: BackupOutcome?

    /// Why the last backup that didn't write the file stopped, or nil after
    /// one that did.
    var lastBackupFailure: String? { lastBackupOutcome?.failureMessage }

    /// What Settings shows next to "Last synced": why backups aren't running
    /// right now. iCloud being signed out shows even before a backup has
    /// tried, and stops showing once it's back.
    var backupProblem: String? {
        guard Self.backupURL != nil else { return BackupOutcome.iCloudUnavailable.failureMessage }
        return lastBackupOutcome == .iCloudUnavailable ? nil : lastBackupFailure
    }

    @discardableResult
    private func record(_ outcome: BackupOutcome) -> BackupOutcome {
        lastBackupOutcome = outcome
        return outcome
    }

    /// Gets the modification date of the iCloud backup file.
    var lastBackupDate: Date? {
        guard let url = Self.backupURL else { return nil }
        return Self.modificationDate(of: url)
    }

    nonisolated static func modificationDate(of url: URL) -> Date? {
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
            await self.backupInBackground(context: context)
        }
    }
    
    /// Performs a backup of the SwiftData database to iCloud, merging with the
    /// backup already in the cloud so a device that holds only part of the
    /// library (a fresh install, a metadata-only iPad) can never last-writer-
    /// wins away another device's records. Says whether the file was
    /// written, so Sync Now can report what really happened. Runs on the
    /// main actor from start to finish; the app's own backups use
    /// `backupInBackground`.
    @discardableResult
    func backupToiCloud(context: ModelContext) -> BackupOutcome {
        backup(to: Self.backupURL, context: context)
    }

    /// `backupToiCloud` with the file it writes passed in (nil: iCloud isn't
    /// available), so tests can cover a signed-out device.
    @discardableResult
    func backup(to url: URL?, context: ModelContext) -> BackupOutcome {
        guard let pending = pendingBackup(to: url, context: context) else { return lastBackupOutcome ?? .iCloudUnavailable }
        return finishBackup(Self.writeBackup(pending))
    }

    /// `backupToiCloud`, with only the snapshot of the library taken on the
    /// main actor: the merge with the cloud file, the encoding and the write
    /// run on a background thread, so a large library doesn't stall the UI.
    /// Holds a background-task assertion, so the write can finish after the
    /// app leaves the screen (#137).
    @discardableResult
    func backupInBackground(context: ModelContext) async -> BackupOutcome {
        guard let write = startBackgroundBackup(context: context) else { return lastBackupOutcome ?? .iCloudUnavailable }
        return await write.value
    }

    /// Takes the snapshot and the background-task assertion now, then hands
    /// the write to a task that runs after the one before it, so writes land
    /// (and stamp the file) in the order their snapshots were taken. Returns
    /// that task, or nil when there was nothing to write to.
    @discardableResult
    func startBackgroundBackup(context: ModelContext) -> Task<BackupOutcome, Never>? {
        let assertion = BackgroundAssertion(name: "Fanficly iCloud backup")
        guard let pending = pendingBackup(to: Self.backupURL, context: context) else {
            assertion.end()
            return nil
        }
        let previous = lastWrite
        let write = Task {
            _ = await previous?.value
            let result = await Task.detached(priority: .utility) {
                iCloudSyncManager.writeBackup(pending)
            }.value
            let outcome = finishBackup(result)
            assertion.end()
            return outcome
        }
        lastWrite = write
        return write
    }

    /// The library as a backup, ready to merge and write, or nil (with the
    /// reason recorded) when there's nothing to write to yet: no iCloud, or
    /// the cloud file is still downloading.
    private func pendingBackup(to url: URL?, context: ModelContext) -> PendingBackup? {
        guard let url else {
            record(.iCloudUnavailable)
            return nil
        }

        // If the cloud backup isn't downloaded yet we can't merge with it, and
        // overwriting would drop every record the other device backed up.
        // iOS shows that as a `.icloud` placeholder; newer macOS keeps the
        // real name and reports it through the downloading status. Kick off
        // the download and let a later queueBackup (they fire on every
        // mutation) retry once it's local.
        if Self.isUndownloaded(url) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            record(.waitingForDownload)
            return nil
        }

        return PendingBackup(url: url, backup: makeLocalBackup(context: context), deviceSuffix: Self.backupDeviceSuffix)
    }

    /// This device's whole library as a backup: what an iCloud backup merges
    /// into the cloud file, and what a library file export writes.
    func makeLocalBackup(context: ModelContext, account: String? = CredentialStore.shared.storedUsername()) -> LibraryBackup {
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
            let workBackups = works.map { Self.workBackup($0) }
            
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
                    lastCheckedAt: $0.lastCheckedAt,
                    account: account
                )
            }
            
            let searchBackups = searches.map { SearchBackup(search: $0) }
            
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

            let localDeletions = Self.prunedDeletions(Self.localDeletions(), now: .now)
            let backup = LibraryBackup(
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
                deleted: localDeletions.isEmpty ? nil : localDeletions,
                timestamp: .now
            )
            return backup
        }
    }

    /// Merges a snapshot with the backup already in the cloud and writes the
    /// result, off the main actor. Nothing here touches SwiftData.
    nonisolated static func writeBackup(_ pending: PendingBackup) -> BackupWrite {
        let url = pending.url
        var backup = pending.backup
        do {
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
            var unchanged = false
            try updateBackup(at: url) { existing in
                switch existing {
                case .missing:
                    break
                case .unreadable(let error):
                    readError = error
                    return nil
                case .backup(let cloudBackup, let cloudData):
                    mergedUnappliedChanges = backupHasUnappliedChanges(at: url)
                    backup = mergedBackup(local: backup, cloud: cloudBackup, deviceSuffix: pending.deviceSuffix)
                    mergedWith = cloudData
                }
                // 4. Serialize to JSON for the write, keeping the keys this app
                // doesn't know from the file it merged with (the Windows
                // app's fields, or a newer version's).
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(backup)
                guard let mergedWith else { return data }
                let merged = try preservingUnknownKeys(in: data, from: mergedWith, merged: backup)
                // 5. When that's what the file already holds, leave it alone:
                // rewriting it would only change `timestamp`, and iCloud
                // would upload the whole library again for nothing (#137).
                if sameBackupContent(merged, mergedWith) {
                    unchanged = true
                    return nil
                }
                return merged
            }
            if let readError {
                print("Skipped the iCloud backup, the existing backup can't be read: \(readError)")
                return (.unreadable, nil)
            }
            // When everything in the file came from this library (or was
            // already applied here), stamp it so the launch auto-sync doesn't
            // re-restore our own backup. When we merged in another device's
            // unapplied records, leave the stamp alone: the next launch sees
            // the file as changed and restores them into this library.
            // A file left unchanged was already stamped (nothing unapplied
            // means the stamp is its date); stamping it again could mark a
            // file another device swapped in since the read as applied.
            if unchanged { return (.unchanged, nil) }
            if mergedUnappliedChanges { return (.written, nil) }
            return (.written, modificationDate(of: url) ?? Date())
        } catch {
            print("Failed to backup to iCloud: \(error)")
            return (.failed(error.localizedDescription), nil)
        }
    }

    /// Stamps the file when `writeBackup` says to, and records how it went.
    private func finishBackup(_ result: BackupWrite) -> BackupOutcome {
        if let appliedStamp = result.appliedStamp { markCloudBackupApplied(date: appliedStamp) }
        return record(result.outcome)
    }

    /// Whether two encoded backups hold the same records and settings,
    /// ignoring `timestamp`, which every backup stamps afresh. Compares the
    /// parsed JSON, so key order and formatting don't count; a file written in
    /// another format (the Windows app's dates) just counts as different once.
    nonisolated static func sameBackupContent(_ a: Data, _ b: Data) -> Bool {
        guard var first = (try? JSONSerialization.jsonObject(with: a)) as? [String: Any],
              var second = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any] else { return false }
        first["timestamp"] = nil
        second["timestamp"] = nil
        return (first as NSDictionary).isEqual(to: second)
    }

    /// A work as its backup record. Restore passes `includeChapters: false`
    /// to merge a local work with the backup's copy by the same rules as a
    /// backup (`mergedWork`) without encoding its chapter text.
    static func workBackup(_ work: Work, includeChapters: Bool = true) -> WorkBackup {
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
            chapters: includeChapters ? work.chapters.sorted(by: { $0.index < $1.index }).map { ch in
                ChapterBackup(index: ch.index, title: ch.title, bodyHTML: ch.bodyHTML, aoId: ch.aoId)
            } : [],
            // Sorted: a to-many relationship's order can change between
            // fetches, and a new order would make an unchanged library look
            // changed and rewrite the whole file (#137).
            folderName: work.folders.map(\.name).min(),
            folderNames: work.folders.map(\.name).sorted()
        )
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

    nonisolated static let lastRestoredStampKey = "icloud.lastRestoredBackupDate"

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
        guard let url = Self.backupURL else { return true }
        return Self.backupHasUnappliedChanges(at: url)
    }

    nonisolated static func backupHasUnappliedChanges(at url: URL) -> Bool {
        guard let applied = UserDefaults.standard.object(forKey: lastRestoredStampKey) as? Date,
              let cloudDate = modificationDate(of: url) else { return true }
        return cloudDate != applied
    }

    /// Stamps `date` (the file's modification date when it was read, or just
    /// after it was written) as applied here. Pass the date from before a
    /// restore's read, so a file another device swaps in while the restore
    /// runs isn't marked applied unread.
    private func markCloudBackupApplied(date: Date? = nil) {
        UserDefaults.standard.set(date ?? lastBackupDate ?? Date(), forKey: Self.lastRestoredStampKey)
    }

    // MARK: - Deletion markers

    /// This device's own deletion markers, kept here until they age out so
    /// every backup carries them (the file may be cleared, or written by an
    /// app version that doesn't know them). Not synced itself.
    nonisolated static let deletionsKey = "sync.deletions"

    /// How long a deletion marker is kept: a device offline longer than this
    /// can bring a deleted record back, the same trade-off as profiles.
    nonisolated static let deletionLifetime: TimeInterval = 90 * 24 * 60 * 60

    /// Remembers that this device deleted a record, so the next backup
    /// carries the deletion to the file and to the other devices. Called by
    /// every delete of a work, hidden work, folder, saved search or filter,
    /// whether or not sync is on.
    nonisolated static func recordDeletion(_ kind: DeletionKind, key: String, at date: Date = .now) {
        let others = localDeletions().filter { !($0.kind == kind.rawValue && $0.key == key) }
        saveLocalDeletions(prunedDeletions(others + [DeletionBackup(kind: kind.rawValue, key: key, deletedAt: date)], now: date))
    }

    nonisolated static func localDeletions() -> [DeletionBackup] {
        guard let data = UserDefaults.standard.data(forKey: deletionsKey) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([DeletionBackup].self, from: data)) ?? []
    }

    private nonisolated static func saveLocalDeletions(_ deletions: [DeletionBackup]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        UserDefaults.standard.set(try? encoder.encode(deletions), forKey: deletionsKey)
    }

    /// The newest marker per record from both lists, without the ones older
    /// than `deletionLifetime`.
    nonisolated static func prunedDeletions(_ deletions: [DeletionBackup], now: Date) -> [DeletionBackup] {
        let cutoff = now.addingTimeInterval(-deletionLifetime)
        var newest: [String: DeletionBackup] = [:]
        for d in deletions where d.deletedAt >= cutoff {
            let id = "\(d.kind)\u{1F}\(d.key)"
            if let existing = newest[id], existing.deletedAt >= d.deletedAt { continue }
            newest[id] = d
        }
        return newest.values.sorted { ($0.kind, $0.key) < ($1.kind, $1.key) }
    }

    /// Unions a freshly-built local backup with the backup already in iCloud.
    /// Records the other device backed up but this one doesn't hold are kept;
    /// on conflicts the local record wins (this device just produced it),
    /// except where a field only moves forward: works and subscriptions merge
    /// by the restore's rules (`mergedWork`, `mergedSubscription`), reading
    /// positions keep the newer one, reading stats merge conservatively, and
    /// settings merge key by key (`mergedSettings`; `deviceSuffix` is this
    /// device's, see `backupDeviceSuffix`).
    /// Deletion markers from both sides are kept, and a work, hidden work,
    /// folder, saved search or filter that a newer marker covers is left out,
    /// so a delete doesn't come back from another device's copy (#135).
    nonisolated static func mergedBackup(local: LibraryBackup, cloud: LibraryBackup, deviceSuffix: String) -> LibraryBackup {
        var worksById = Dictionary(cloud.works.map { ($0.ao3Id, $0) }, uniquingKeysWith: { a, _ in a })
        for w in local.works {
            guard let cloudWork = worksById[w.ao3Id] else { worksById[w.ao3Id] = w; continue }
            // Follow, star and pin keep this device's values here (restore ORs
            // them): the file is the only record of an un-follow, and without an
            // edit stamp an OR would bring every un-followed work back on a restore.
            let m = mergedWork(local: w, other: cloudWork)
            worksById[w.ao3Id] = m.withFlags(of: w)
        }

        var bookmarksById = Dictionary(cloud.bookmarks.map { ($0.ao3Id, $0) }, uniquingKeysWith: { a, _ in a })
        for b in local.bookmarks { bookmarksById[b.ao3Id] = b }

        var subscriptionsByKey = Dictionary(cloud.subscriptions.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for s in local.subscriptions {
            subscriptionsByKey[s.key] = subscriptionsByKey[s.key].map { mergedSubscription(local: s, other: $0) } ?? s
        }

        var searchesByName = Dictionary(cloud.searches.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for s in local.searches {
            searchesByName[s.name] = searchesByName[s.name].map { mergedSearch(local: s, other: $0) } ?? s
        }

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

        // Deletion markers from both sides remove the records they're newer
        // than, whichever side still held them (#135).
        let deleted = prunedDeletions((cloud.deleted ?? []) + (local.deleted ?? []), now: local.timestamp)
        let tombstones = DeletionIndex(deleted)
        worksById = worksById.filter { !tombstones.removes(.work, String($0.key), stamp: $0.value.savedAt) }
        hiddenById = hiddenById.filter { !tombstones.removes(.hidden, String($0.key), stamp: $0.value.hiddenAt) }
        foldersByName = foldersByName.filter { !tombstones.removes(.folder, $0.key, stamp: $0.value.createdAt) }
        searchesByName = searchesByName.filter { !tombstones.removes(.search, $0.key, stamp: $0.value.savedAt) }
        filtersByName = filtersByName.filter { !tombstones.removes(.filter, $0.key, stamp: $0.value.savedAt) }

        return LibraryBackup(
            works: worksById.values.sorted { $0.ao3Id < $1.ao3Id },
            bookmarks: bookmarksById.values.sorted { $0.ao3Id < $1.ao3Id },
            subscriptions: subscriptionsByKey.values.sorted { $0.key < $1.key },
            searches: searchesByName.values.sorted { $0.name < $1.name },
            progress: progressById.values.sorted { $0.ao3Id < $1.ao3Id },
            filters: filtersByName.values.sorted { $0.name < $1.name },
            hidden: hiddenById.values.sorted { $0.ao3Id < $1.ao3Id },
            settings: mergedSettings(local: local.settings, cloud: cloud.settings, deviceSuffix: deviceSuffix),
            folders: foldersByName.values.sorted { $0.name < $1.name },
            stats: statsById.values.sorted { $0.ao3Id < $1.ao3Id },
            blocked: blockedByKey.values.sorted { $0.key < $1.key },
            deleted: deleted.isEmpty ? nil : deleted,
            timestamp: local.timestamp
        )
    }

    // MARK: - Settings (#133)

    /// This device's suffix on the backup's per-device settings keys
    /// (`themePhone`, `fontSizePtPad`, `boldTextMac`).
    static var backupDeviceSuffix: String {
        switch ReaderProfile.deviceKey("") {
        case ".mac": "Mac"
        case ".pad": "Pad"
        default: "Phone"
        }
    }

    /// The settings a restore writes here, as UserDefaults keys and values:
    /// every field the backup holds that is shared or carries this device's
    /// suffix, skipping keys this device already has (`isSet`). Settings only
    /// seed a fresh install. After that each device keeps its own, so a stale
    /// copy another device backed up can't revert them. Profiles merge
    /// separately and aren't included.
    nonisolated static func settingsToSeed(
        from settings: SettingsBackup, deviceSuffix: String, isSet: (String) -> Bool
    ) -> [(key: String, value: Any)] {
        var seeds: [(key: String, value: Any)] = []
        for child in Mirror(reflecting: settings).children {
            guard let name = child.label, name != "profiles", let value = unwrapped(child.value) else { continue }
            let key: String
            if let device = SettingsBackup.deviceSuffix(of: name) {
                guard device == deviceSuffix else { continue }
                key = SettingsBackup.defaultsKey(for: String(name.dropLast(device.count))) + "." + device.lowercased()
            } else {
                key = SettingsBackup.defaultsKey(for: name)
            }
            if !isSet(key) { seeds.append((key, value)) }
        }
        return seeds
    }

    /// Settings merge key by key. This device's own keys and the shared ones
    /// take its value (a key only the file has is kept); another device's
    /// per-device keys always come from the file, because any copies this
    /// device holds are only what an earlier restore brought in, and writing
    /// those back would revert that device's newer choices.
    nonisolated static func mergedSettings(
        local: SettingsBackup?, cloud: SettingsBackup?, deviceSuffix: String
    ) -> SettingsBackup? {
        guard let local else { return cloud }
        let encoder = JSONEncoder()
        guard let localKeys = (try? JSONSerialization.jsonObject(with: encoder.encode(local))) as? [String: Any]
        else { return local }
        var merged = cloud.flatMap { (try? JSONSerialization.jsonObject(with: encoder.encode($0))) as? [String: Any] } ?? [:]
        for (key, value) in localKeys {
            if let device = SettingsBackup.deviceSuffix(of: key), device != deviceSuffix { continue }
            merged[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let result = try? JSONDecoder().decode(SettingsBackup.self, from: data)
        else { return local }
        return result
    }

    private nonisolated static func unwrapped(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first?.value
    }

    /// Two copies of one work merged so nothing moves backwards, whichever
    /// device merges first: the backup merge passes this device's record as
    /// `local` and the cloud's as `other`, and restore passes this device's
    /// work and the backup's copy the same way. The Windows app's
    /// `LibrarySyncManager.MergedWork` applies the same rules.
    /// - AO3 metadata (title through `updatedAt`) comes whole from the
    ///   fresher copy (`hasFresherMetadata`); `savedAt` keeps the later date.
    /// - The reading position (`lastRead*`) comes from the copy read last.
    /// - Follow, star and pin are an OR; `followedAt` keeps local's when set.
    ///   (`mergedBackup` then puts local's flags back, so an un-follow reaches
    ///   the file.)
    /// - `lastSeenChapterCount` keeps the higher count, so an older copy never
    ///   re-announces chapters (nil only when both are nil).
    /// - Note and personal tags take the newest edit (`mergedNotes`).
    /// - Chapters come from the copy with more; folders union.
    nonisolated static func mergedWork(local: WorkBackup, other: WorkBackup) -> WorkBackup {
        let meta = hasFresherMetadata(other, than: local) ? other : local
        let position = (other.lastReadAt ?? .distantPast) > (local.lastReadAt ?? .distantPast) ? other : local
        let notes = mergedNotes(
            local: WorkNotes(note: local.note, personalTags: local.personalTags ?? [], updatedAt: local.notesUpdatedAt),
            other: WorkNotes(note: other.note, personalTags: other.personalTags ?? [], updatedAt: other.notesUpdatedAt)
        )
        let localFolders = local.folderNames ?? local.folderName.map { [$0] } ?? []
        let otherFolders = other.folderNames ?? other.folderName.map { [$0] } ?? []
        let folders = localFolders + otherFolders.filter { !localFolders.contains($0) }
        return WorkBackup(
            ao3Id: local.ao3Id,
            title: meta.title,
            authorName: meta.authorName,
            authorUsername: meta.authorUsername,
            summary: meta.summary,
            rating: meta.rating,
            warnings: meta.warnings,
            categories: meta.categories,
            fandoms: meta.fandoms,
            characters: meta.characters,
            relationships: meta.relationships,
            freeforms: meta.freeforms,
            language: meta.language,
            wordCount: meta.wordCount,
            chapterCount: meta.chapterCount,
            totalChapters: meta.totalChapters,
            kudos: meta.kudos,
            hits: meta.hits,
            bookmarksCount: meta.bookmarksCount,
            commentsCount: meta.commentsCount,
            isComplete: meta.isComplete,
            publishedAt: meta.publishedAt,
            updatedAt: meta.updatedAt,
            savedAt: max(local.savedAt, other.savedAt),
            lastReadAt: position.lastReadAt,
            lastReadChapter: position.lastReadChapter,
            lastReadProgress: position.lastReadProgress,
            isFollowed: local.isFollowed || other.isFollowed,
            followedAt: local.followedAt ?? other.followedAt,
            lastSeenChapterCount: higher(local.lastSeenChapterCount, other.lastSeenChapterCount),
            isStarred: (local.isStarred ?? false) || (other.isStarred ?? false),
            isPinned: (local.isPinned ?? false) || (other.isPinned ?? false),
            note: notes.note,
            personalTags: notes.personalTags,
            notesUpdatedAt: notes.updatedAt,
            chapters: other.chapters.count > local.chapters.count ? other.chapters : local.chapters,
            folderName: folders.first,
            folderNames: folders
        )
    }

    /// Whether `other` carries newer AO3 metadata than `local`: a later
    /// `updatedAt` (AO3's "Updated" date), then, on the same date, more
    /// chapters, then more hits (they only grow, so the copy fetched last
    /// has the most). A full tie keeps local.
    nonisolated static func hasFresherMetadata(_ other: WorkBackup, than local: WorkBackup) -> Bool {
        let otherDate = other.updatedAt ?? .distantPast
        let localDate = local.updatedAt ?? .distantPast
        if otherDate != localDate { return otherDate > localDate }
        if other.chapterCount != local.chapterCount { return other.chapterCount > local.chapterCount }
        return other.hits > local.hits
    }

    /// A subscription's two copies merged: the notification baseline keeps
    /// the higher count and `lastCheckedAt` the later date, so an older copy
    /// can't re-announce chapters or turn alerts off with a nil baseline.
    /// Its kind and names come from `local`.
    nonisolated static func mergedSubscription(local: SubscriptionBackup, other: SubscriptionBackup) -> SubscriptionBackup {
        SubscriptionBackup(
            key: local.key,
            kind: local.kind,
            displayName: local.displayName,
            authorName: local.authorName,
            lastSeenChapterCount: higher(local.lastSeenChapterCount, other.lastSeenChapterCount),
            lastCheckedAt: later(local.lastCheckedAt, other.lastCheckedAt),
            account: local.account ?? other.account
        )
    }

    /// Whether a backed-up subscription may be restored for the AO3 account
    /// signed in here (#159): only that account's own. One from a backup made
    /// before subscriptions recorded their account restores for anyone.
    nonisolated static func subscription(_ s: SubscriptionBackup, belongsTo account: String?) -> Bool {
        guard let owner = s.account else { return true }
        return account.map { owner.caseInsensitiveCompare($0) == .orderedSame } ?? false
    }

    /// A saved search merges forward-only too (#309). Its definition (prompt
    /// and sort) comes from the side saved last and its alert switch from the
    /// side switched last (ties keep local), so editing a search or switching
    /// its alerts off reaches every device. What its alerts have seen belongs
    /// to one prompt and one switch-on: when both sides share them, the seen
    /// ids union and the checks keep the later date, so a restore can't make
    /// alerts fire again for works another device already alerted for.
    /// Otherwise the seen ids come from the side whose prompt (then switch)
    /// is current, since switching alerts on or editing the search starts a
    /// fresh baseline.
    nonisolated static func mergedSearch(local: SearchBackup, other: SearchBackup) -> SearchBackup {
        let definition = other.savedAt > local.savedAt ? other : local
        let switched = (other.alertsChangedAt ?? .distantPast) > (local.alertsChangedAt ?? .distantPast) ? other : local
        var known = definition.alertKnownWorkIds
        var baselineAt = definition.alertsBaselineAt
        var lastCheckedAt = definition.alertsLastCheckedAt
        if local.prompt == other.prompt {
            if local.alertsChangedAt == other.alertsChangedAt {
                let union = SavedSearchAlerts.baseline(local.alertKnownWorkIds ?? [], adding: other.alertKnownWorkIds ?? [])
                known = union.isEmpty ? nil : union
                baselineAt = earlier(local.alertsBaselineAt, other.alertsBaselineAt)
                lastCheckedAt = later(local.alertsLastCheckedAt, other.alertsLastCheckedAt)
            } else {
                known = switched.alertKnownWorkIds
                baselineAt = switched.alertsBaselineAt
                lastCheckedAt = switched.alertsLastCheckedAt
            }
        }
        return SearchBackup(
            name: local.name,
            prompt: definition.prompt,
            sortColumn: definition.sortColumn,
            sortDirection: definition.sortDirection,
            savedAt: definition.savedAt,
            alertsEnabled: switched.alertsEnabled,
            alertsChangedAt: switched.alertsChangedAt,
            alertKnownWorkIds: known,
            alertsBaselineAt: baselineAt,
            alertsLastCheckedAt: lastCheckedAt
        )
    }

    private nonisolated static func earlier(_ a: Date?, _ b: Date?) -> Date? {
        guard let a else { return b }
        guard let b else { return a }
        return min(a, b)
    }

    private nonisolated static func higher(_ a: Int?, _ b: Int?) -> Int? {
        guard let a else { return b }
        guard let b else { return a }
        return max(a, b)
    }

    private nonisolated static func later(_ a: Date?, _ b: Date?) -> Date? {
        guard let a else { return b }
        guard let b else { return a }
        return max(a, b)
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

    /// Settings → Sync Now: first brings in what other devices backed up
    /// since this device last applied the file (the same forward-only restore
    /// the launch runs), then backs up. Restoring first means the backup's
    /// merge finds nothing unapplied, so it stamps the file it writes.
    /// A restore that fails still backs up this device's changes; the stamp
    /// didn't move, so the next launch or Sync Now tries it again.
    @discardableResult
    func syncNow(context: ModelContext) async -> SyncNowResult {
        var restored = false
        var restoreFailed = false
        if isBackupAvailable && cloudBackupHasUnappliedChanges {
            restored = await restoreFromiCloud(context: context)
            restoreFailed = !restored
        }
        return SyncNowResult(restored: restored, restoreFailed: restoreFailed,
                             backup: await backupInBackground(context: context))
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
            try applyBackup(backup, context: context)
            markCloudBackupApplied(date: readDate)
            return true
        } catch {
            print("Failed to restore from iCloud: \(error)")
            return false
        }
    }

    /// Merges a backup into the library and saves: the restore's
    /// forward-only rules, shared by the iCloud restore and a library file
    /// import. Throws when the save fails.
    func applyBackup(_ backup: LibraryBackup, context: ModelContext,
                     account: String? = CredentialStore.shared.storedUsername()) throws {
        // Deletion markers: the file's (every device's) and this device's
        // own, which the file may not hold yet. A record they cover isn't
        // restored, and this device's copy of it is deleted below (#135).
        let tombstones = DeletionIndex(Self.prunedDeletions((backup.deleted ?? []) + Self.localDeletions(), now: .now))
        // Works this restore gives chapter text: the only ones the
        // re-download prompt may offer afterwards (#152).
        var textRestored: [Int] = []

        do {
            // 0. Restore settings and themes. Restore only fills in what this
            // device hasn't set (a fresh install) and never copies another
            // device's per-device keys, so each device keeps its own (#133).
            if let s = backup.settings {
                let defaults = UserDefaults.standard
                let seeds = Self.settingsToSeed(from: s, deviceSuffix: Self.backupDeviceSuffix) {
                    defaults.object(forKey: $0) != nil
                }
                for seed in seeds { defaults.set(seed.value, forKey: seed.key) }
                if let profiles = s.profiles {
                    let mergedProfiles = ReaderProfile.mergedProfiles(
                        localJSON: defaults.string(forKey: "reader.profiles"),
                        incomingJSON: profiles
                    )
                    defaults.set(mergedProfiles, forKey: "reader.profiles")
                    ReaderProfileSyncStore.publishLocalProfiles(mergedProfiles)
                }
            }
            
            // 0.5. Restore CustomFolders
            if let customFolders = backup.folders {
                for f in customFolders where !tombstones.removes(.folder, f.name, stamp: f.createdAt) {
                    let descriptor = FetchDescriptor<CustomFolder>(predicate: #Predicate { $0.name == f.name })
                    let existing = (try? context.fetch(descriptor))?.first
                    if existing == nil {
                        context.insert(CustomFolder(name: f.name, createdAt: f.createdAt))
                    }
                }
            }
            
            // 1. Restore Works and their Chapters
            for w in backup.works where !tombstones.removes(.work, String(w.ao3Id), stamp: w.savedAt) {
                let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.ao3Id == w.ao3Id })
                let existing = (try? context.fetch(descriptor))?.first
                
                // Merge with the local copy by the backup's rules
                // (`mergedWork`), so restore also runs as a background launch
                // sync that never rewinds this device to an older backup:
                // fresher AO3 metadata, the position read last, OR'd flags, the
                // higher notification baseline (regressing it would re-fire
                // "new chapter" alerts) and the newest note edit.
                let work: Work
                let m: WorkBackup
                if let existing {
                    work = existing
                    m = Self.mergedWork(local: Self.workBackup(existing, includeChapters: false), other: w)
                } else {
                    work = Work(ao3Id: w.ao3Id, title: w.title, authorName: w.authorName)
                    context.insert(work)
                    m = w
                }

                work.title = m.title
                work.authorName = m.authorName
                work.authorUsername = m.authorUsername
                work.summary = m.summary
                work.rating = m.rating
                work.warnings = m.warnings
                work.categories = m.categories
                work.fandoms = m.fandoms
                work.characters = m.characters
                work.relationships = m.relationships
                work.freeforms = m.freeforms
                work.language = m.language
                work.wordCount = m.wordCount
                work.chapterCount = m.chapterCount
                work.totalChapters = m.totalChapters
                work.kudos = m.kudos
                work.hits = m.hits
                work.bookmarksCount = m.bookmarksCount
                work.commentsCount = m.commentsCount
                work.isComplete = m.isComplete
                work.publishedAt = m.publishedAt
                work.updatedAt = m.updatedAt
                work.savedAt = m.savedAt
                work.lastReadAt = m.lastReadAt
                work.lastReadChapter = m.lastReadChapter
                work.lastReadProgress = m.lastReadProgress
                work.isFollowed = m.isFollowed
                work.followedAt = m.followedAt
                work.lastSeenChapterCount = m.lastSeenChapterCount
                work.isStarred = m.isStarred ?? false
                work.isPinned = m.isPinned ?? false
                let notes = WorkNotes(note: m.note, personalTags: m.personalTags ?? [], updatedAt: m.notesUpdatedAt)
                if notes != WorkNotes(note: work.note, personalTags: work.personalTags, updatedAt: work.notesUpdatedAt) {
                    work.note = notes.note
                    work.personalTags = notes.personalTags
                    work.notesUpdatedAt = notes.updatedAt
                }

                work.folder = nil // clear legacy single folder reference
                // Folders union, not replace: a launch sync must not drop an
                // assignment made locally since the last backup.
                let folderNames = m.folderNames ?? m.folderName.map { [$0] } ?? []
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
                    textRestored.append(w.ao3Id)
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
            
            // 3. Restore SubscriptionRecords. The baseline and last check
            // only move forward (`mergedSubscription`): an older backup must
            // not re-announce chapters, and a nil baseline must not switch
            // alerts off until the next poll. Names come from the backup.
            // Another AO3 account's subscriptions stay in the file (another
            // device may still be signed in as it) but never restore here (#159).
            for s in backup.subscriptions where Self.subscription(s, belongsTo: account) {
                let descriptor = FetchDescriptor<SubscriptionRecord>(predicate: #Predicate { $0.key == s.key })
                let existing = (try? context.fetch(descriptor))?.first
                if let existing {
                    let m = Self.mergedSubscription(local: s, other: SubscriptionBackup(
                        key: existing.key, kind: existing.kind, displayName: existing.displayName,
                        authorName: existing.authorName, lastSeenChapterCount: existing.lastSeenChapterCount,
                        lastCheckedAt: existing.lastCheckedAt
                    ))
                    existing.kind = m.kind
                    existing.displayName = m.displayName
                    existing.authorName = m.authorName
                    existing.lastSeenChapterCount = m.lastSeenChapterCount
                    existing.lastCheckedAt = m.lastCheckedAt
                } else {
                    let rec = SubscriptionRecord(key: s.key, kind: s.kind, displayName: s.displayName, authorName: s.authorName)
                    rec.lastSeenChapterCount = s.lastSeenChapterCount
                    rec.lastCheckedAt = s.lastCheckedAt
                    context.insert(rec)
                }
            }
            
            // 4. Restore SavedSearches
            for s in backup.searches where !tombstones.removes(.search, s.name, stamp: s.savedAt) {
                let descriptor = FetchDescriptor<SavedSearch>(predicate: #Predicate { $0.name == s.name })
                let existing = (try? context.fetch(descriptor))?.first
                if let existing {
                    let merged = Self.mergedSearch(local: SearchBackup(search: existing), other: s)
                    // A new prompt or a newer alert switch replaces the
                    // baseline, so the "New" count from the old one goes too.
                    if merged.prompt != existing.prompt || merged.alertsChangedAt != existing.alertsChangedAt {
                        existing.alertNewWorkIds = []
                    }
                    merged.apply(to: existing)
                } else {
                    let search = SavedSearch(name: s.name, prompt: s.prompt, sortColumn: s.sortColumn, sortDirection: s.sortDirection, savedAt: s.savedAt)
                    s.apply(to: search)
                    context.insert(search)
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
            for f in backup.filters where !tombstones.removes(.filter, f.name, stamp: f.savedAt) {
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
            for h in backup.hidden where !tombstones.removes(.hidden, String(h.ao3Id), stamp: h.hiddenAt) {
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

            // 10. Deletions made on other devices: remove this device's copy
            // of a record a marker covers, unless the file holds a newer
            // copy (saved again since), which the steps above applied.
            Self.applyDeletions(tombstones, backup: backup, context: context)

            try context.save()
            RestoreDownloadCenter.shared.noteRestoredText(workIds: textRestored)
            // Restored works skip upsertMetadata, so they reach Spotlight here.
            WorkPersistence.indexLibrary(context: context)
        }
    }
    
    /// Deletes this device's records that a deletion marker covers: ones
    /// stamped no later than the marker, when the backup has no newer copy.
    private static func applyDeletions(_ tombstones: DeletionIndex, backup: LibraryBackup, context: ModelContext) {
        let liveWorks = Set(backup.works.filter { !tombstones.removes(.work, String($0.ao3Id), stamp: $0.savedAt) }.map(\.ao3Id))
        for work in (try? context.fetch(FetchDescriptor<Work>())) ?? []
        where !liveWorks.contains(work.ao3Id) && tombstones.removes(.work, String(work.ao3Id), stamp: work.savedAt) {
            WorkPersistence.delete(work, in: context)
        }
        let liveHidden = Set(backup.hidden.filter { !tombstones.removes(.hidden, String($0.ao3Id), stamp: $0.hiddenAt) }.map(\.ao3Id))
        for hidden in (try? context.fetch(FetchDescriptor<HiddenWork>())) ?? []
        where !liveHidden.contains(hidden.ao3Id) && tombstones.removes(.hidden, String(hidden.ao3Id), stamp: hidden.hiddenAt) {
            context.delete(hidden)
        }
        let liveFolders = Set((backup.folders ?? []).filter { !tombstones.removes(.folder, $0.name, stamp: $0.createdAt) }.map(\.name))
        for folder in (try? context.fetch(FetchDescriptor<CustomFolder>())) ?? []
        where !liveFolders.contains(folder.name) && tombstones.removes(.folder, folder.name, stamp: folder.createdAt) {
            context.delete(folder)
        }
        let liveSearches = Set(backup.searches.filter { !tombstones.removes(.search, $0.name, stamp: $0.savedAt) }.map(\.name))
        for search in (try? context.fetch(FetchDescriptor<SavedSearch>())) ?? []
        where !liveSearches.contains(search.name) && tombstones.removes(.search, search.name, stamp: search.savedAt) {
            context.delete(search)
        }
        let liveFilters = Set(backup.filters.filter { !tombstones.removes(.filter, $0.name, stamp: $0.savedAt) }.map(\.name))
        for filter in (try? context.fetch(FetchDescriptor<SavedFilter>())) ?? []
        where !liveFilters.contains(filter.name) && tombstones.removes(.filter, filter.name, stamp: filter.savedAt) {
            context.delete(filter)
        }
    }

    /// Deletes the backup file (and the copy of the previous one) from
    /// iCloud, and says what really happened.
    @discardableResult
    func clearFromiCloud() -> ClearOutcome {
        clear(at: Self.backupURL)
    }

    /// `clearFromiCloud` with the file passed in (nil: iCloud isn't
    /// available), so tests can cover a signed-out device.
    @discardableResult
    func clear(at url: URL?) -> ClearOutcome {
        guard let url else { return .iCloudUnavailable }
        let fileManager = FileManager.default
        let previousURL = Self.previousBackupURL(for: url)
        if fileManager.fileExists(atPath: previousURL.path) {
            try? fileManager.removeItem(at: previousURL)
        }
        // Only a placeholder here: there's nothing on this device to delete
        // yet. Start the download so trying again can delete it.
        if !fileManager.fileExists(atPath: url.path) {
            guard Self.isUndownloaded(url) else { return .nothingToClear }
            try? fileManager.startDownloadingUbiquitousItem(at: url)
            return .waitingForDownload
        }

        do {
            // A backup queued before the clear would write the file straight
            // back. (Only cancelled here: when nothing is deleted, this
            // device's last change still needs backing up.)
            backupTask?.cancel()
            try fileManager.removeItem(at: url)
            // Whatever stopped the last backup was about the file just deleted.
            lastBackupOutcome = nil
            return .cleared
        } catch {
            print("Failed to clear iCloud backup: \(error)")
            return .failed(error.localizedDescription)
        }
    }


    // MARK: - Library file export and import

    /// The backup file's encoding: property names as keys, ISO 8601 dates.
    nonisolated static func encodeBackup(_ backup: LibraryBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    nonisolated static func decodeBackup(_ data: Data) throws -> LibraryBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibraryBackup.self, from: data)
    }

    /// The exported file's name, e.g. "Fanficly Library 2026-10-18.json".
    nonisolated static func exportFileName(on date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Fanficly Library \(formatter.string(from: date)).json"
    }

    /// Writes the library as a backup file (the same JSON as the iCloud
    /// backup) into a temporary folder and returns its URL for the share
    /// sheet. Works whether or not iCloud sync is on.
    func exportLibraryFile(context: ModelContext) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryExport", isDirectory: true)
        // Each export holds every saved chapter's text, so replace the last
        // one rather than letting copies pile up in tmp.
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Self.exportFileName())
        try Self.encodeBackup(makeLocalBackup(context: context)).write(to: url, options: .atomic)
        return url
    }

    /// Merges a library file (exported here, by another device, or by the
    /// Windows app) into the library through the same forward-only rules as
    /// an iCloud restore. Throws when the file can't be read or isn't a
    /// library file; nothing is changed then.
    func importLibraryFile(at url: URL, context: ModelContext) throws {
        // Files picked from outside the sandbox need security-scoped access.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let backup = try Self.decodeBackup(Data(contentsOf: url))
        do {
            try applyBackup(backup, context: context)
        } catch {
            context.rollback()
            throw error
        }
        // Refresh widgets, and carry the imported records into the iCloud
        // backup when sync is on.
        queueBackup(context: context)
    }
}

// MARK: - Outcomes

/// What a backup did (the Windows app's `BackupOutcome`).
enum BackupOutcome: Equatable, Sendable {
    case written
    /// The backup in iCloud already held this library, so it was left as it
    /// is (#137).
    case unchanged
    /// The backup in iCloud isn't on this device yet; its download was started.
    case waitingForDownload
    /// The device isn't signed in to iCloud, or iCloud Drive is off for Fanficly.
    case iCloudUnavailable
    /// The backup in iCloud couldn't be decoded (damaged, or a newer app's
    /// format), so it was left alone rather than overwritten.
    case unreadable
    case failed(String)

    /// Whether the file in iCloud holds this library now (written, or
    /// already up to date).
    var succeeded: Bool { failureMessage == nil }

    /// Why the file wasn't written, or nil when it was (or didn't need to be).
    var failureMessage: String? {
        switch self {
        case .written, .unchanged:
            nil
        case .waitingForDownload:
            String(localized: "The backup in iCloud is still downloading. Fanficly will back up once it's on this device.")
        case .iCloudUnavailable:
            String(localized: "iCloud isn't available. Make sure you're signed in to iCloud and iCloud Drive is on for Fanficly.")
        case .unreadable:
            String(localized: "The backup in iCloud couldn't be read, so it was left as it is. It may be damaged or from a newer version of Fanficly. Update Fanficly, or use Clear iCloud Data to start a new backup from this device.")
        case .failed(let reason):
            reason
        }
    }
}

/// What Sync Now did: whether it brought other devices' changes into this
/// library (or tried and couldn't), and how the backup after it went.
struct SyncNowResult: Equatable, Sendable {
    var restored: Bool
    var restoreFailed: Bool
    var backup: BackupOutcome
}

/// What Clear iCloud Data did.
enum ClearOutcome: Equatable, Sendable {
    case cleared
    /// There was no backup in iCloud to delete.
    case nothingToClear
    /// The backup is in iCloud but not on this device yet, so it couldn't be
    /// deleted from here; its download was started.
    case waitingForDownload
    case iCloudUnavailable
    case failed(String)
}

// MARK: - Backup Codable Structs

/// A library snapshot `backupInBackground` hands to the background write.
struct PendingBackup: Sendable {
    let url: URL
    let backup: LibraryBackup
    /// This device's settings suffix, read on the main actor.
    let deviceSuffix: String
}

/// How `iCloudSyncManager.writeBackup` went, and the file date to stamp
/// as applied here (nil: leave the stamp alone).
typealias BackupWrite = (outcome: BackupOutcome, appliedStamp: Date?)

/// Asks iOS for time to finish a backup after the app leaves the screen,
/// and gives it back when the backup ends or the time runs out.
@MainActor
private final class BackgroundAssertion {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

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
    /// Deletion markers (#135). Optional so older backups still decode, and
    /// older app versions keep the key as one they don't know.
    var deleted: [DeletionBackup]? = nil
    let timestamp: Date
}

/// What a deletion marker removes. The raw values are the backup's `kind`
/// strings, shared with the Windows app.
enum DeletionKind: String, CaseIterable, Sendable {
    case work, hidden, folder, search, filter
}

/// A record some device deleted: a library work, a hidden work, a folder, a
/// saved search or a saved filter, by its identity key (the AO3 id, or the
/// name). The union merge would otherwise bring it back from any other
/// device's copy (#135). A record whose own stamp is newer than the marker
/// (saved, hidden or created again since) wins over it, and markers are
/// dropped after 90 days, like reader profile tombstones.
struct DeletionBackup: Codable, Equatable, Sendable {
    let kind: String
    let key: String
    let deletedAt: Date
}

/// The newest deletion marker per record, for looking records up against.
struct DeletionIndex: Sendable {
    private var markers: [String: Date] = [:]

    init(_ deletions: [DeletionBackup]) {
        for d in deletions {
            let id = Self.id(d.kind, d.key)
            if let existing = markers[id], existing >= d.deletedAt { continue }
            markers[id] = d.deletedAt
        }
    }

    private static func id(_ kind: String, _ key: String) -> String { "\(kind)\u{1F}\(key)" }

    func deletedAt(_ kind: DeletionKind, _ key: String) -> Date? {
        markers[Self.id(kind.rawValue, key)]
    }

    /// Whether a marker removes a record stamped `stamp` (saved, hidden or
    /// created then). Compared in whole seconds, the backup file's precision,
    /// and a tie goes to the marker: on one device a delete always comes
    /// after the save it removes.
    func removes(_ kind: DeletionKind, _ key: String, stamp: Date) -> Bool {
        guard let deletedAt = deletedAt(kind, key) else { return false }
        return stamp.timeIntervalSince1970.rounded(.down) <= deletedAt.timeIntervalSince1970.rounded(.down)
    }
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

extension SettingsBackup {
    /// The suffixes of per-device keys, the Windows app's included.
    static let deviceSuffixes = ["Phone", "Pad", "Mac", "Windows"]

    /// The device a backup key belongs to (`fontSizePtPad` → `Pad`), or nil
    /// for a shared key.
    static func deviceSuffix(of key: String) -> String? {
        deviceSuffixes.first { key.hasSuffix($0) && key.count > $0.count }
    }

    /// The UserDefaults key of a shared backup key (`fontSizePt` →
    /// `reader.fontSizePt`).
    static func defaultsKey(for name: String) -> String {
        switch name {
        case "filterMatureExplicit", "ageConfirmed": "content.\(name)"
        default: "reader.\(name)"
        }
    }
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
    var isFollowed: Bool
    var followedAt: Date?
    let lastSeenChapterCount: Int?
    var isStarred: Bool?
    var isPinned: Bool?
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

extension WorkBackup {
    /// This record with `other`'s follow, star and pin.
    func withFlags(of other: WorkBackup) -> WorkBackup {
        var copy = self
        copy.isFollowed = other.isFollowed
        copy.followedAt = other.followedAt
        copy.isStarred = other.isStarred
        copy.isPinned = other.isPinned
        return copy
    }
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
    /// The AO3 login name signed in when it was backed up (#159); restore
    /// skips another account's. Nil in older backups and in the Windows app's.
    var account: String? = nil
}

struct SearchBackup: Codable {
    let name: String
    let prompt: String
    let sortColumn: String
    let sortDirection: String
    let savedAt: Date
    // New-fic alerts (#309). Optional so older backups (and the Windows
    // app's, before it had alerts) still decode; merged by `mergedSearch`.
    var alertsEnabled: Bool? = nil
    var alertsChangedAt: Date? = nil
    var alertKnownWorkIds: [Int]? = nil
    var alertsBaselineAt: Date? = nil
    var alertsLastCheckedAt: Date? = nil
}

extension SearchBackup {
    @MainActor
    init(search: SavedSearch) {
        self.init(
            name: search.name, prompt: search.prompt, sortColumn: search.sortColumn,
            sortDirection: search.sortDirection, savedAt: search.savedAt,
            alertsEnabled: search.alertsEnabled ? true : nil,
            alertsChangedAt: search.alertsChangedAt,
            alertKnownWorkIds: search.alertKnownWorkIds.isEmpty ? nil : search.alertKnownWorkIds,
            alertsBaselineAt: search.alertsBaselineAt,
            alertsLastCheckedAt: search.alertsLastCheckedAt
        )
    }

    @MainActor
    func apply(to search: SavedSearch) {
        search.prompt = prompt
        search.sortColumn = sortColumn
        search.sortDirection = sortDirection
        search.savedAt = savedAt
        search.alertsEnabled = alertsEnabled ?? false
        search.alertsChangedAt = alertsChangedAt
        search.alertKnownWorkIds = alertKnownWorkIds ?? []
        search.alertsBaselineAt = alertsBaselineAt
        search.alertsLastCheckedAt = alertsLastCheckedAt
    }
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
