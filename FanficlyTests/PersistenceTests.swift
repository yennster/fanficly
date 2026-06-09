import XCTest
import SwiftData
@testable import Fanficly

@MainActor
final class PersistenceTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Work.self, Chapter.self, TagRecord.self, BookmarkRecord.self,
            SubscriptionRecord.self, SavedSearch.self, ReadingProgress.self,
            RecentlyViewed.self, CustomFolder.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private func payload(id: Int, chapters: Int) -> AO3WorkPayload {
        let summary = AO3WorkSummary(
            id: id, title: "Test Work \(id)", author: "tester",
            summary: "A summary", rating: "Mature", warnings: ["No Archive Warnings Apply"],
            categories: ["M/M"], fandoms: ["Harry Potter - J. K. Rowling"],
            characters: ["Harry Potter"], relationships: ["Harry/Draco"],
            freeforms: ["Fluff"], wordCount: 5000, chapterCount: chapters,
            totalChapters: chapters, language: "English", kudos: 100, hits: 2000,
            isComplete: true, updatedAt: nil
        )
        let chs = (1...chapters).map { AO3ChapterPayload(index: $0, title: "Ch \($0)", bodyHTML: "<p>Body \($0)</p>") }
        return AO3WorkPayload(summary: summary, chapters: chs)
    }

    private func readerProfile(name: String, theme: String, fontSize: Double) -> ReaderProfile {
        let base = ReaderProfile.defaultProfiles[0]
        return ReaderProfile(
            name: name,
            themeRaw: theme,
            fontFamilyRaw: base.fontFamilyRaw,
            widthRaw: base.widthRaw,
            widthPercent: base.widthPercent,
            modeRaw: base.modeRaw,
            fontSizePt: fontSize,
            lineSpacingPt: base.lineSpacingPt,
            paragraphSpacingPt: base.paragraphSpacingPt,
            pageTurnHaptics: base.pageTurnHaptics,
            pageTurnAnimations: base.pageTurnAnimations,
            kerningPt: base.kerningPt,
            boldText: base.boldText
        )
    }

    func test_upsertInsertsThenUpdates() throws {
        let ctx = try makeContext()
        let w1 = WorkPersistence.upsert(payload: payload(id: 1, chapters: 3), into: ctx)
        XCTAssertEqual(w1.chapters.count, 3)
        XCTAssertEqual(w1.fandoms, ["Harry Potter - J. K. Rowling"])

        // Re-upsert with fewer chapters replaces them, no duplicate Work.
        let w2 = WorkPersistence.upsert(payload: payload(id: 1, chapters: 2), into: ctx)
        XCTAssertEqual(w2.chapters.count, 2)
        let all = try ctx.fetch(FetchDescriptor<Work>())
        XCTAssertEqual(all.count, 1)
    }

    func test_upsertMetadataDoesNotTouchChapters() throws {
        let ctx = try makeContext()
        _ = WorkPersistence.upsert(payload: payload(id: 7, chapters: 4), into: ctx)
        let summary = payload(id: 7, chapters: 4).summary
        let w = WorkPersistence.upsertMetadata(summary: summary, into: ctx)
        XCTAssertEqual(w.chapters.count, 4, "metadata upsert must keep existing chapters")
    }

    func test_toggleFollow() throws {
        let ctx = try makeContext()
        let summary = payload(id: 9, chapters: 1).summary
        XCTAssertFalse(WorkPersistence.isFollowed(workId: 9, in: ctx))

        let nowFollowed = WorkPersistence.toggleFollow(summary: summary, into: ctx)
        XCTAssertTrue(nowFollowed)
        XCTAssertTrue(WorkPersistence.isFollowed(workId: 9, in: ctx))

        let nowUnfollowed = WorkPersistence.toggleFollow(summary: summary, into: ctx)
        XCTAssertFalse(nowUnfollowed)
        XCTAssertFalse(WorkPersistence.isFollowed(workId: 9, in: ctx))
    }

    func test_recordViewInsertsBumpsAndTrims() throws {
        let ctx = try makeContext()
        // First view inserts.
        WorkPersistence.recordView(summary: payload(id: 1, chapters: 1).summary, into: ctx)
        WorkPersistence.recordView(summary: payload(id: 2, chapters: 1).summary, into: ctx)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<RecentlyViewed>()).count, 2)

        // Re-viewing id 1 bumps it to the front without duplicating.
        WorkPersistence.recordView(summary: payload(id: 1, chapters: 1).summary, into: ctx)
        let ordered = try ctx.fetch(FetchDescriptor<RecentlyViewed>(
            sortBy: [SortDescriptor(\.viewedAt, order: .reverse)]))
        XCTAssertEqual(ordered.count, 2)
        XCTAssertEqual(ordered.first?.ao3Id, 1)

        // Trims to the newest `limit`.
        for id in 100..<110 {
            WorkPersistence.recordView(summary: payload(id: id, chapters: 1).summary, into: ctx, limit: 3)
        }
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<RecentlyViewed>()).count, 3)
    }

    func test_readingProgressRoundTrips() throws {
        let ctx = try makeContext()
        XCTAssertNil(ReadingProgressStore.load(ao3Id: 42, in: ctx))

        ReadingProgressStore.save(ao3Id: 42, anchor: ReadingAnchor(chapter: 5, paragraph: 12),
                                  title: "T", author: "A", in: ctx)
        let a = ReadingProgressStore.load(ao3Id: 42, in: ctx)
        XCTAssertEqual(a?.chapter, 5)
        XCTAssertEqual(a?.paragraph, 12)

        // Saving again updates in place (no duplicate row).
        ReadingProgressStore.save(ao3Id: 42, anchor: ReadingAnchor(chapter: 6, paragraph: 0),
                                  title: "T", author: "A", in: ctx)
        XCTAssertEqual(ReadingProgressStore.load(ao3Id: 42, in: ctx)?.chapter, 6)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ReadingProgress>()).count, 1)
    }

    func test_iCloudSyncRestoresSettings() async throws {
        let ctx = try makeContext()
        
        // Setup temporary override URL for testing
        let tempDir = FileManager.default.temporaryDirectory
        let testBackupURL = tempDir.appendingPathComponent("test_library_backup.json")
        iCloudSyncManager.overrideBackupURL = testBackupURL
        
        defer {
            iCloudSyncManager.overrideBackupURL = nil
            try? FileManager.default.removeItem(at: testBackupURL)
        }
        
        // 1. Set some settings in UserDefaults
        let defaults = UserDefaults.standard
        defer {
            [
                "reader.theme",
                "reader.fontFamily",
                "reader.width",
                "reader.fontSizePt",
                "reader.profiles",
                "reader.theme.pad",
                "reader.activeProfile.pad",
                "reader.fontSizePt.pad",
                "content.filterMatureExplicit"
            ].forEach { defaults.removeObject(forKey: $0) }
        }
        defaults.set("sepia", forKey: "reader.theme")
        defaults.set("rounded", forKey: "reader.fontFamily")
        defaults.set("wide", forKey: "reader.width")
        defaults.set(22.0, forKey: "reader.fontSizePt")
        defaults.set(true, forKey: "content.filterMatureExplicit")
        
        // Device-specific settings
        defaults.set("dracula", forKey: "reader.theme.pad")
        defaults.set("compact", forKey: "reader.activeProfile.pad")
        defaults.set(18.0, forKey: "reader.fontSizePt.pad")

        let macProfile = readerProfile(name: "Mac", theme: "dracula", fontSize: 24.0)
        defaults.set(ReaderProfile.saveProfiles([ReaderProfile.defaultProfiles[0], macProfile]),
                     forKey: "reader.profiles")
        
        // 2. Perform backup
        let syncManager = iCloudSyncManager.shared
        syncManager.backupToiCloud(context: ctx)
        
        // 3. Reset settings in UserDefaults
        defaults.removeObject(forKey: "reader.theme")
        defaults.removeObject(forKey: "reader.fontFamily")
        defaults.removeObject(forKey: "reader.width")
        defaults.removeObject(forKey: "reader.fontSizePt")
        defaults.removeObject(forKey: "content.filterMatureExplicit")
        
        defaults.removeObject(forKey: "reader.theme.pad")
        defaults.removeObject(forKey: "reader.activeProfile.pad")
        defaults.removeObject(forKey: "reader.fontSizePt.pad")

        let phoneProfile = readerProfile(name: "iPhone", theme: "system", fontSize: 20.0)
        defaults.set(ReaderProfile.saveProfiles([ReaderProfile.defaultProfiles[0], phoneProfile]),
                     forKey: "reader.profiles")
        
        XCTAssertNil(defaults.string(forKey: "reader.theme"))
        XCTAssertNil(defaults.string(forKey: "reader.theme.pad"))
        
        // 4. Restore from backup
        let success = await syncManager.restoreFromiCloud(context: ctx)
        XCTAssertTrue(success)
        
        // 5. Verify they are restored
        XCTAssertEqual(defaults.string(forKey: "reader.theme"), "sepia")
        XCTAssertEqual(defaults.string(forKey: "reader.fontFamily"), "rounded")
        XCTAssertEqual(defaults.string(forKey: "reader.width"), "wide")
        XCTAssertEqual(defaults.double(forKey: "reader.fontSizePt"), 22.0)
        XCTAssertTrue(defaults.bool(forKey: "content.filterMatureExplicit"))
        
        XCTAssertEqual(defaults.string(forKey: "reader.theme.pad"), "dracula")
        XCTAssertEqual(defaults.string(forKey: "reader.activeProfile.pad"), "compact")
        XCTAssertEqual(defaults.double(forKey: "reader.fontSizePt.pad"), 18.0)

        let restoredProfiles = ReaderProfile.loadProfiles(from: defaults.string(forKey: "reader.profiles") ?? "")
        XCTAssertEqual(restoredProfiles.first(where: { $0.name == "Mac" })?.fontSizePt, 24.0)
        XCTAssertEqual(restoredProfiles.first(where: { $0.name == "iPhone" })?.fontSizePt, 20.0)
    }
}
