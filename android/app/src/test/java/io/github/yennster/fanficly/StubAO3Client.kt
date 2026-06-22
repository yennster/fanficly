package io.github.yennster.fanficly

import io.github.yennster.fanficly.model.AO3SearchFilters
import io.github.yennster.fanficly.model.AutocompleteField
import io.github.yennster.fanficly.model.ExportFormat
import io.github.yennster.fanficly.model.SearchResults
import io.github.yennster.fanficly.model.WorkMetadata
import io.github.yennster.fanficly.model.WorkPayload
import io.github.yennster.fanficly.net.AO3Client
import java.io.File

/**
 * Scriptable [AO3Client] test double — the Kotlin port of the iOS
 * `StubAO3Client`. Only [autocomplete] is meaningful: it returns whatever the
 * [autocompleteResponses] map holds for the (case-insensitive) term, defaulting
 * to an empty list. Everything else throws so a test that accidentally hits the
 * network fails loudly.
 */
class StubAO3Client : AO3Client {
    var autocompleteResponses: Map<String, List<String>> = emptyMap()

    override suspend fun autocomplete(field: AutocompleteField, term: String): List<String> =
        autocompleteResponses[term.lowercase()] ?: emptyList()

    override suspend fun login(username: String, password: String) = throw NotImplementedError()
    override fun logout() = throw NotImplementedError()
    override fun currentUsername(): String? = null
    override fun isLoggedIn(): Boolean = false
    override suspend fun search(filters: AO3SearchFilters, page: Int): SearchResults = throw NotImplementedError()
    override suspend fun fetchAuthorWorks(username: String, page: Int): SearchResults = throw NotImplementedError()
    override suspend fun fetchBookmarks(username: String, page: Int): SearchResults = throw NotImplementedError()
    override suspend fun fetchWork(id: Int): WorkPayload = throw NotImplementedError()
    override suspend fun fetchWorkMetadata(id: Int): WorkMetadata = throw NotImplementedError()
    override suspend fun fetchFandomsInCategory(categoryName: String): List<io.github.yennster.fanficly.model.BrowseFandom> = throw NotImplementedError()
    override suspend fun fetchPopularSnapshot(): io.github.yennster.fanficly.model.PopularSnapshot = throw NotImplementedError()
    override suspend fun fetchComments(workId: Int, chapterId: Int?): List<io.github.yennster.fanficly.model.AO3Comment> = throw NotImplementedError()
    override suspend fun postComment(workId: Int, chapterId: Int?, text: String) = throw NotImplementedError()
    override suspend fun downloadEpub(workId: Int, cacheDir: File): File = throw NotImplementedError()
    override suspend fun exportWork(workId: Int, format: ExportFormat, filename: String, cacheDir: File): File = throw NotImplementedError()
    override suspend fun subscribeToWork(workId: Int) = throw NotImplementedError()
}
