package io.github.yennster.fanficly.model

/**
 * Typed values returned by [io.github.yennster.fanficly.net.AO3Client] — the
 * Kotlin counterparts of the iOS app's `AO3WorkSummary` / `AO3WorkPayload` /
 * `AO3ChapterPayload`. Plain immutable data classes; parsers are pure and
 * return these (see SearchResultsParser / WorkPageParser).
 */

data class WorkSummary(
    val id: Int,
    val title: String,
    val author: String,
    /** The author's AO3 login (the `/users/<login>` segment); "" when anonymous. */
    val authorUsername: String = "",
    val summary: String,
    val rating: String,
    val warnings: List<String>,
    val categories: List<String>,
    val fandoms: List<String>,
    val characters: List<String>,
    val relationships: List<String>,
    val freeforms: List<String>,
    val wordCount: Int,
    val chapterCount: Int,
    val totalChapters: Int?,
    val language: String,
    val kudos: Int,
    val hits: Int,
    val isComplete: Boolean,
    /** Epoch millis of the work's last update, or null if unparsed. */
    val updatedAtMillis: Long?,
)

data class SearchResults(
    val works: List<WorkSummary>,
    val totalPages: Int,
    val currentPage: Int,
)

data class ChapterPayload(
    val index: Int,
    val title: String,
    val bodyHtml: String,
    /** AO3's chapter database id, for per-chapter comments; null if not exposed. */
    val aoId: Int? = null,
)

data class WorkPayload(
    val summary: WorkSummary,
    val chapters: List<ChapterPayload>,
)

data class WorkMetadata(
    val id: Int,
    val chapterCount: Int,
    val totalChapters: Int?,
    val updatedAtMillis: Long?,
)

enum class AutocompleteField(val path: String) {
    RELATIONSHIP("relationship"),
    CHARACTER("character"),
    FREEFORM("freeform"),
    FANDOM("fandom"),
}

enum class ExportFormat(val ext: String, val displayName: String) {
    AZW3("azw3", "AZW3"),
    EPUB("epub", "EPUB"),
    MOBI("mobi", "MOBI"),
    PDF("pdf", "PDF"),
    HTML("html", "HTML"),
}

/** Errors surfaced by the client, mirroring iOS `AO3Error`. */
sealed class AO3Exception(message: String) : Exception(message) {
    class LoginFailed(reason: String) : AO3Exception(reason)
    object RateLimited : AO3Exception("Rate limited by AO3 (429). Slow down.")
    object Unauthorized : AO3Exception("Not authorized — login may be required.")
    class ParseFailed(reason: String) : AO3Exception(reason)
    class Http(val status: Int) : AO3Exception("HTTP $status")
    class Network(reason: String) : AO3Exception(reason)
}
