package io.github.yennster.fanficly.net

import io.github.yennster.fanficly.model.AO3SearchFilters
import io.github.yennster.fanficly.model.AutocompleteField
import io.github.yennster.fanficly.model.ChapterPayload
import io.github.yennster.fanficly.model.ExportFormat
import io.github.yennster.fanficly.model.SearchResults
import io.github.yennster.fanficly.model.WorkMetadata
import io.github.yennster.fanficly.model.WorkPayload
import io.github.yennster.fanficly.model.WorkSummary
import java.io.File

/**
 * Offline stand-in for [AO3Client] used by Compose previews and unit tests —
 * the Kotlin port of iOS `MockAO3Client`. Returns deterministic fixtures and
 * never touches the network.
 */
class MockAO3Client : AO3Client {
    private val sample = WorkSummary(
        id = 1, title = "A Study in Emerald", author = "Demo Author", authorUsername = "demo",
        summary = "A sample work used for previews and demo mode.",
        rating = "Teen And Up Audiences", warnings = listOf("No Archive Warnings Apply"),
        categories = listOf("Gen"), fandoms = listOf("Sherlock Holmes"),
        characters = listOf("Sherlock Holmes"), relationships = emptyList(),
        freeforms = listOf("Mystery"), wordCount = 12_345, chapterCount = 3, totalChapters = 3,
        language = "English", kudos = 9_876, hits = 123_456, isComplete = true, updatedAtMillis = null,
    )

    override suspend fun login(username: String, password: String) {}
    override fun logout() {}
    override fun currentUsername(): String? = null
    override fun isLoggedIn(): Boolean = false

    override suspend fun search(filters: AO3SearchFilters, page: Int) =
        SearchResults(works = List(8) { sample.copy(id = it + 1, title = "${sample.title} #${it + 1}") }, totalPages = 1, currentPage = page)

    override suspend fun fetchAuthorWorks(username: String, page: Int) =
        SearchResults(works = listOf(sample), totalPages = 1, currentPage = page)

    override suspend fun fetchBookmarks(username: String, page: Int) =
        SearchResults(works = listOf(sample), totalPages = 1, currentPage = page)

    override suspend fun fetchWork(id: Int) = WorkPayload(
        summary = sample.copy(id = id),
        chapters = listOf(
            ChapterPayload(1, "Chapter One", "<p>It was a dark and stormy night.</p><p>The detective lit his pipe.</p>"),
            ChapterPayload(2, "Chapter Two", "<p>The plot thickened considerably.</p>"),
            ChapterPayload(3, "", "<p>And all was revealed in the end.</p>"),
        ),
    )

    override suspend fun fetchWorkMetadata(id: Int) = WorkMetadata(id, 3, 3, null)
    override suspend fun fetchFandomsInCategory(categoryName: String) =
        io.github.yennster.fanficly.browse.FandomCatalog.all.firstOrNull { it.name == categoryName }?.fandoms ?: emptyList()
    override suspend fun fetchPopularSnapshot() = io.github.yennster.fanficly.model.PopularSnapshot(
        fandoms = io.github.yennster.fanficly.browse.PopularTags.fandoms,
        ships = io.github.yennster.fanficly.browse.PopularTags.ships,
        characters = io.github.yennster.fanficly.browse.PopularTags.characters,
        fetchedAt = 0L,
    )
    override suspend fun fetchComments(workId: Int, chapterId: Int?) = listOf(
        io.github.yennster.fanficly.model.AO3Comment(
            id = "1", commenterName = "Demo Reader", commenterUsername = "demo",
            dateText = "01 Jan 2026", bodyHtml = "<p>A sample comment used for previews.</p>", depth = 0,
        ),
    )
    override suspend fun postComment(workId: Int, chapterId: Int?, text: String) {}
    override suspend fun fetchSubscriptions(username: String) = listOf(
        io.github.yennster.fanficly.model.AO3Subscription(
            kind = io.github.yennster.fanficly.model.AO3Subscription.Kind.WORK,
            resourceId = "1", title = sample.title, author = sample.author,
        ),
    )
    override suspend fun autocomplete(field: AutocompleteField, term: String) = listOf(term)
    override suspend fun downloadEpub(workId: Int, cacheDir: File) = File(cacheDir, "$workId.epub")
    override suspend fun exportWork(workId: Int, format: ExportFormat, filename: String, cacheDir: File) =
        File(cacheDir, "$filename.${format.ext}")
    override suspend fun subscribeToWork(workId: Int) {}
}
