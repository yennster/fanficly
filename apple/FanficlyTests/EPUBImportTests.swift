import XCTest
import SwiftData
@testable import Fanficly

/// EPUB import (the Windows app's `EpubImportTests` reads the same two
/// books): an AO3 download (calibre-style EPUB 2, deflated, an NCX whose
/// chapters share a file) and a plain EPUB 3 book (stored, a nav document,
/// a cover page).
@MainActor
final class EPUBImportTests: XCTestCase {
    func testAO3BookKeepsItsWorkIdTagsAndChapters() throws {
        let payload = try EPUBImport.parse(data: Self.ao3EPUB)
        let s = payload.summary
        XCTAssertEqual(s.id, 12345)
        XCTAssertEqual(s.title, "The Long Way Home")
        XCTAssertEqual(s.author, "Quill Writer")
        XCTAssertEqual(s.authorUsername, "quill")
        XCTAssertEqual(s.rating, "General Audiences")
        XCTAssertEqual(s.warnings, ["No Archive Warnings Apply"])
        XCTAssertEqual(s.fandoms, ["Original Work", "Some Fandom"])
        XCTAssertEqual(s.relationships, ["A/B"])
        XCTAssertEqual(s.characters, ["A", "B"])
        XCTAssertEqual(s.freeforms, ["Fluff", "Road Trips"])
        XCTAssertEqual(s.language, "English")
        XCTAssertEqual(s.wordCount, 1234)
        XCTAssertEqual(s.totalChapters, 3)
        XCTAssertFalse(s.isComplete)
        XCTAssertEqual(s.updatedAt, Date(timeIntervalSince1970: 1_709_510_400)) // 2024-03-04 UTC
        XCTAssertTrue(s.summary.contains("Two friends drive home."))

        // The preface is the Library entry, not a chapter; the afterword's end
        // notes close the last chapter.
        XCTAssertEqual(payload.chapters.count, 2)
        XCTAssertEqual(s.chapterCount, 2)
        let one = payload.chapters[0]
        XCTAssertEqual(one.index, 1)
        XCTAssertEqual(one.title, "Chapter 1: Hello")
        XCTAssertEqual(one.aoId, 678)
        XCTAssertTrue(one.bodyHTML.contains("It was a dark and stormy night."))
        XCTAssertTrue(one.bodyHTML.contains("They left at dawn."))
        XCTAssertFalse(one.bodyHTML.contains("<img"))
        XCTAssertFalse(one.bodyHTML.contains("car broke down"))
        let two = payload.chapters[1]
        XCTAssertEqual(two.index, 2)
        XCTAssertEqual(two.title, "Chapter 2")
        // The self-closed anchor didn't swallow the rest of the sentence into a link.
        XCTAssertTrue(two.bodyHTML.contains("somewhere in Ohio.</p>"))
        XCTAssertFalse(two.bodyHTML.contains(">Chapter 2</h2>"))
        XCTAssertTrue(two.bodyHTML.contains("End notes: thanks for reading!"))
    }

    func testPlainBookGetsAStableLocalIdAndOneChapterPerTOCEntry() throws {
        let payload = try EPUBImport.parse(data: Self.plainEPUB)
        let s = payload.summary
        XCTAssertTrue(EPUBImport.isLocalWork(s.id))
        XCTAssertEqual(s.id, EPUBImport.localWorkId(identifier: "urn:isbn:9780000000001", title: "", author: ""))
        XCTAssertEqual(s.title, "A Plain Book")
        XCTAssertEqual(s.author, "Jane Doe")
        XCTAssertEqual(s.language, "fr")
        XCTAssertEqual(s.freeforms, ["Essays"])
        XCTAssertEqual(s.summary, "<p>A short book.</p><p>In two parts.</p>")
        XCTAssertTrue(s.isComplete)

        // The cover page comes before the first contents entry, so it's left out.
        XCTAssertEqual(payload.chapters.map(\.title), ["Part One", "Part Two"])
        XCTAssertTrue(payload.chapters[0].bodyHTML.contains("First words here."))
        XCTAssertFalse(payload.chapters[0].bodyHTML.contains("x()"))
        XCTAssertTrue(payload.chapters[1].bodyHTML.contains("Second &amp; last."))
        XCTAssertTrue(payload.chapters.allSatisfy { $0.aoId == nil })
        XCTAssertEqual(s.wordCount, 10)
    }

    /// The same ids as the Windows app, so a library shared through one sync
    /// folder keeps one entry per book.
    func testLocalIdsMatchTheWindowsApp() {
        XCTAssertEqual(EPUBImport.localWorkId(identifier: "urn:isbn:9780000000001", title: "", author: ""), -1596378688)
    }

    func testNotAnEPUBIsRefused() {
        XCTAssertThrowsError(try EPUBImport.parse(data: Data("not a zip".utf8))) { error in
            XCTAssertEqual(error as? EPUBImport.ImportError, .notAnEPUB)
        }
    }

    func testSelfClosingTagsAreSpelledOutExceptVoidOnes() {
        XCTAssertEqual(
            EPUBImport.expandSelfClosingTags(#"<title/><br/><p>a<a id="x"/>b</p><img src="y" />"#),
            #"<title></title><br/><p>a<a id="x"></a>b</p><img src="y" />"#)
    }

    func testSavingAddsANewWorkWithItsFileAndKeepsAnExistingWorksDetails() throws {
        let schema = Schema([
            Work.self, Chapter.self, TagRecord.self, BookmarkRecord.self,
            SubscriptionRecord.self, SavedSearch.self, ReadingProgress.self,
            RecentlyViewed.self, CustomFolder.self, FollowedAuthor.self,
            ReadingStat.self, BlockedTerm.self, HiddenWork.self, SavedFilter.self,
        ])
        let container = try ModelContainer(for: schema, configurations: [
            ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none),
        ])
        let context = ModelContext(container)
        let payload = try EPUBImport.parse(data: Self.plainEPUB)
        let id = payload.summary.id
        defer {
            if let url = WorkPersistence.epubURL(workId: id) { try? FileManager.default.removeItem(at: url) }
        }

        let work = try EPUBImportCenter.save(payload, epub: Self.plainEPUB, into: context)
        XCTAssertEqual(work.ao3Id, id)
        XCTAssertEqual(work.chapters.count, 2)
        XCTAssertNotNil(WorkPersistence.epubURL(workId: id))

        // Imported again after the reader renamed nothing but AO3 might have:
        // the Library entry's details stay, the text is replaced.
        work.title = "Kept Title"
        let again = try EPUBImportCenter.save(payload, epub: Self.plainEPUB, into: context)
        XCTAssertEqual(again.title, "Kept Title")
        XCTAssertEqual(again.chapters.count, 2)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Work>()).count, 1)

        // A book that isn't on AO3 is never offered for download.
        try FileManager.default.removeItem(at: XCTUnwrap(WorkPersistence.epubURL(workId: id)))
        XCTAssertEqual(RestoreDownloadCenter.redownloadCandidates(in: context), [])
        XCTAssertEqual(RestoreDownloadCenter.folderDownloadCandidates([again], isDownloaded: { _ in false }), [])
    }

    func testOutcomeMessages() {
        XCTAssertEqual(EPUBImportCenter.outcome(saved: ["A"], failures: []).title, "Imported")
        XCTAssertEqual(EPUBImportCenter.outcome(saved: [], failures: ["b: bad"]).message, "b: bad")
        XCTAssertEqual(EPUBImportCenter.outcome(saved: ["A"], failures: ["b: bad"]).title, "Imported 1 of 2")
    }

    private static let ao3EPUB = Data(base64Encoded: """
        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
        AAA=
        """, options: .ignoreUnknownCharacters)!

    private static let plainEPUB = Data(base64Encoded: """
        UEsDBBQAAAAAAAAAIQBvYassFAAAABQAAAAIAAAAbWltZXR5cGVhcHBsaWNhdGlvbi9lcHViK3ppcFBLAwQUAAAAAAChtF5dHgvX
        yd0AAADdAAAAFgAAAE1FVEEtSU5GL2NvbnRhaW5lci54bWw8P3htbCB2ZXJzaW9uPSIxLjAiPz48Y29udGFpbmVyIHZlcnNpb249
        IjEuMCIgeG1sbnM9InVybjpvYXNpczpuYW1lczp0YzpvcGVuZG9jdW1lbnQ6eG1sbnM6Y29udGFpbmVyIj48cm9vdGZpbGVzPjxy
        b290ZmlsZSBmdWxsLXBhdGg9Ik9FQlBTL2NvbnRlbnQub3BmIiBtZWRpYS10eXBlPSJhcHBsaWNhdGlvbi9vZWJwcy1wYWNrYWdl
        K3htbCIvPjwvcm9vdGZpbGVzPjwvY29udGFpbmVyPlBLAwQUAAAAAAChtF5d24NrymgDAABoAwAAEQAAAE9FQlBTL2NvbnRlbnQu
        b3BmPD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiPz4KPHBhY2thZ2UgeG1sbnM9Imh0dHA6Ly93d3cuaWRwZi5v
        cmcvMjAwNy9vcGYiIHZlcnNpb249IjMuMCIgdW5pcXVlLWlkZW50aWZpZXI9ImJvb2tpZCI+CjxtZXRhZGF0YSB4bWxuczpkYz0i
        aHR0cDovL3B1cmwub3JnL2RjL2VsZW1lbnRzLzEuMS8iPjxkYzppZGVudGlmaWVyIGlkPSJib29raWQiPnVybjppc2JuOjk3ODAw
        MDAwMDAwMDE8L2RjOmlkZW50aWZpZXI+CjxkYzp0aXRsZT5BIFBsYWluIEJvb2s8L2RjOnRpdGxlPjxkYzpjcmVhdG9yPkphbmUg
        RG9lPC9kYzpjcmVhdG9yPjxkYzpsYW5ndWFnZT5mcjwvZGM6bGFuZ3VhZ2U+CjxkYzpkZXNjcmlwdGlvbj5BIHNob3J0IGJvb2su
        CkluIHR3byBwYXJ0cy48L2RjOmRlc2NyaXB0aW9uPjxkYzpzdWJqZWN0PkVzc2F5czwvZGM6c3ViamVjdD48L21ldGFkYXRhPgo8
        bWFuaWZlc3Q+PGl0ZW0gaWQ9Im5hdiIgaHJlZj0ibmF2LnhodG1sIiBtZWRpYS10eXBlPSJhcHBsaWNhdGlvbi94aHRtbCt4bWwi
        IHByb3BlcnRpZXM9Im5hdiIvPgo8aXRlbSBpZD0iY292ZXIiIGhyZWY9InRleHQvY292ZXIueGh0bWwiIG1lZGlhLXR5cGU9ImFw
        cGxpY2F0aW9uL3hodG1sK3htbCIvPgo8aXRlbSBpZD0iYzEiIGhyZWY9InRleHQvb25lJTIwYS54aHRtbCIgbWVkaWEtdHlwZT0i
        YXBwbGljYXRpb24veGh0bWwreG1sIi8+CjxpdGVtIGlkPSJjMiIgaHJlZj0idGV4dC90d28ueGh0bWwiIG1lZGlhLXR5cGU9ImFw
        cGxpY2F0aW9uL3hodG1sK3htbCIvPjwvbWFuaWZlc3Q+CjxzcGluZT48aXRlbXJlZiBpZHJlZj0iY292ZXIiLz48aXRlbXJlZiBp
        ZHJlZj0iYzEiLz48aXRlbXJlZiBpZHJlZj0iYzIiLz48L3NwaW5lPjwvcGFja2FnZT5QSwMEFAAAAAAAobReXTyFfgyQAQAAkAEA
        AA8AAABPRUJQUy9uYXYueGh0bWw8P3htbCB2ZXJzaW9uPSIxLjAiIGVuY29kaW5nPSJVVEYtOCI/PjxodG1sIHhtbG5zPSJodHRw
        Oi8vd3d3LnczLm9yZy8xOTk5L3hodG1sIiB4bWxuczplcHViPSJodHRwOi8vd3d3LmlkcGYub3JnLzIwMDcvb3BzIj48aGVhZD48
        dGl0bGU+Q29udGVudHM8L3RpdGxlPjwvaGVhZD48Ym9keT4KPG5hdiBlcHViOnR5cGU9ImxhbmRtYXJrcyI+PG9sPjxsaT48YSBo
        cmVmPSJ0ZXh0L2NvdmVyLnhodG1sIj5Db3ZlcjwvYT48L2xpPjwvb2w+PC9uYXY+CjxuYXYgZXB1Yjp0eXBlPSJ0b2MiPjxvbD48
        bGk+PGEgaHJlZj0idGV4dC9vbmUlMjBhLnhodG1sIj5QYXJ0IE9uZTwvYT48L2xpPjxsaT48YSBocmVmPSJ0ZXh0L3R3by54aHRt
        bCI+UGFydCBUd288L2E+PC9saT48L29sPjwvbmF2PjwvYm9keT48L2h0bWw+UEsDBBQAAAAAAKG0Xl3tvMorgAAAAIAAAAAWAAAA
        T0VCUFMvdGV4dC9jb3Zlci54aHRtbDxodG1sIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8xOTk5L3hodG1sIj48aGVhZD48dGl0
        bGU+Q292ZXI8L3RpdGxlPjwvaGVhZD48Ym9keT48aW1nIHNyYz0iLi4vaW1hZ2VzL2NvdmVyLnBuZyIvPjwvYm9keT48L2h0bWw+
        UEsDBBQAAAAAAKG0Xl0QV33lrQAAAK0AAAAWAAAAT0VCUFMvdGV4dC9vbmUgYS54aHRtbDxodG1sIHhtbG5zPSJodHRwOi8vd3d3
        LnczLm9yZy8xOTk5L3hodG1sIj48aGVhZD48dGl0bGU+T25lPC90aXRsZT48c3R5bGU+cHt9PC9zdHlsZT48L2hlYWQ+PGJvZHk+
        PGgxPlBhcnQgT25lPC9oMT48cD5GaXJzdCB3b3JkcyBoZXJlLjwvcD48c2NyaXB0PngoKTwvc2NyaXB0PjwvYm9keT48L2h0bWw+
        UEsDBBQAAAAAAKG0Xl3D0t95mwAAAJsAAAAUAAAAT0VCUFMvdGV4dC90d28ueGh0bWw8aHRtbCB4bWxucz0iaHR0cDovL3d3dy53
        My5vcmcvMTk5OS94aHRtbCI+PGhlYWQ+PHRpdGxlPlR3bzwvdGl0bGU+PC9oZWFkPjxib2R5PjxzZWN0aW9uPjxoMT5QYXJ0IFR3
        bzwvaDE+PHA+U2Vjb25kICZhbXA7IGxhc3QuPC9wPjwvc2VjdGlvbj48L2JvZHk+PC9odG1sPlBLAQIUAxQAAAAAAAAAIQBvYass
        FAAAABQAAAAIAAAAAAAAAAAAAACAAQAAAABtaW1ldHlwZVBLAQIUAxQAAAAAAKG0Xl0eC9fJ3QAAAN0AAAAWAAAAAAAAAAAAAACA
        AToAAABNRVRBLUlORi9jb250YWluZXIueG1sUEsBAhQDFAAAAAAAobReXduDa8poAwAAaAMAABEAAAAAAAAAAAAAAIABSwEAAE9F
        QlBTL2NvbnRlbnQub3BmUEsBAhQDFAAAAAAAobReXTyFfgyQAQAAkAEAAA8AAAAAAAAAAAAAAIAB4gQAAE9FQlBTL25hdi54aHRt
        bFBLAQIUAxQAAAAAAKG0Xl3tvMorgAAAAIAAAAAWAAAAAAAAAAAAAACAAZ8GAABPRUJQUy90ZXh0L2NvdmVyLnhodG1sUEsBAhQD
        FAAAAAAAobReXRBXfeWtAAAArQAAABYAAAAAAAAAAAAAAIABUwcAAE9FQlBTL3RleHQvb25lIGEueGh0bWxQSwECFAMUAAAAAACh
        tF5dw9LfeZsAAACbAAAAFAAAAAAAAAAAAAAAgAE0CAAAT0VCUFMvdGV4dC90d28ueGh0bWxQSwUGAAAAAAcABwDAAQAAAQkAAAAA
        """, options: .ignoreUnknownCharacters)!
}
