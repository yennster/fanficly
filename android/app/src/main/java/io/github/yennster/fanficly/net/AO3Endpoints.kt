package io.github.yennster.fanficly.net

import io.github.yennster.fanficly.model.AO3SearchFilters
import io.github.yennster.fanficly.model.AutocompleteField
import io.github.yennster.fanficly.model.ExportFormat
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl

/**
 * Builds the AO3 URLs the client hits — the Kotlin port of iOS `AO3Endpoints`.
 * OkHttp's [HttpUrl] handles ordinary query encoding; the autocomplete and
 * media-path helpers reproduce the two AO3 encoding quirks the iOS app calls
 * out (slash-in-`term` must be `%2F`; media category path uses AO3's `*a*`/`*s*`
 * scheme).
 */
object AO3Endpoints {
    val BASE: HttpUrl = "https://archiveofourown.org".toHttpUrl()

    fun search(filters: AO3SearchFilters, page: Int): HttpUrl =
        BASE.newBuilder().addPathSegments("works/search").apply {
            filters.queryItems().forEach { (k, v) -> addQueryParameter(k, v) }
            if (page > 1) addQueryParameter("page", page.toString())
        }.build()

    fun work(id: Int): HttpUrl =
        BASE.newBuilder().addPathSegments("works/$id")
            .addQueryParameter("view_full_work", "true")
            .addQueryParameter("view_adult", "true")
            .build()

    fun epub(workId: Int): HttpUrl =
        BASE.newBuilder().addPathSegments("downloads/$workId/work.epub").build()

    fun download(workId: Int, format: ExportFormat): HttpUrl =
        BASE.newBuilder().addPathSegments("downloads/$workId/work.${format.ext}").build()

    fun authorWorks(name: String, page: Int): HttpUrl =
        BASE.newBuilder().addPathSegments("users/$name/works").apply {
            if (page > 1) addQueryParameter("page", page.toString())
        }.build()

    fun userBookmarks(name: String, page: Int = 1): HttpUrl =
        BASE.newBuilder().addPathSegments("users/$name/bookmarks").apply {
            if (page > 1) addQueryParameter("page", page.toString())
        }.build()

    fun login(): HttpUrl = BASE.newBuilder().addPathSegments("users/login").build()

    /** The work page with its comment thread shown (`?show_comments=true`). */
    fun workComments(id: Int): HttpUrl =
        BASE.newBuilder().addPathSegments("works/$id")
            .addQueryParameter("view_adult", "true")
            .addQueryParameter("show_comments", "true")
            .fragment("comments").build()

    /** A specific chapter's page with its comment thread shown (AO3 threads per chapter). */
    fun chapterComments(workId: Int, chapterId: Int): HttpUrl =
        BASE.newBuilder().addPathSegments("works/$workId/chapters/$chapterId")
            .addQueryParameter("view_adult", "true")
            .addQueryParameter("show_comments", "true")
            .fragment("comments").build()

    fun workSubscriptions(id: Int): HttpUrl =
        BASE.newBuilder().addPathSegments("works/$id/subscriptions").build()

    /** The logged-in user's AO3 subscriptions list (works/series/users). */
    fun userSubscriptions(name: String): HttpUrl =
        BASE.newBuilder().addPathSegments("users/$name/subscriptions").build()

    fun mediaFandoms(categoryName: String): HttpUrl =
        "${BASE}media/${ao3PathEncode(categoryName)}/fandoms".toHttpUrl()

    fun tagWorks(tagName: String): HttpUrl =
        "${BASE}tags/${ao3PathEncode(tagName)}/works".toHttpUrl()

    /**
     * Autocomplete is JSON-only and 404s on a raw slash in `term`, so the term
     * is percent-encoded here (including `/` → `%2F`) and set as the raw query.
     */
    fun autocomplete(field: AutocompleteField, term: String): HttpUrl {
        val encoded = percentEncodeTerm(term)
        return "${BASE}autocomplete/${field.path}?term=$encoded".toHttpUrl()
    }

    private fun percentEncodeTerm(term: String): String =
        buildString {
            for (b in term.toByteArray(Charsets.UTF_8)) {
                val c = b.toInt() and 0xFF
                val ch = c.toChar()
                if (ch in 'A'..'Z' || ch in 'a'..'z' || ch in '0'..'9' ||
                    ch == '-' || ch == '_' || ch == '.' || ch == '~'
                ) {
                    append(ch)
                } else {
                    append('%').append("%02X".format(c))
                }
            }
        }

    /** AO3's media-category path encoding (`&`→`*a*`, `/`→`*s*`, `.`→`*d*`, …). */
    private fun ao3PathEncode(s: String): String = buildString {
        for (ch in s) {
            when (ch) {
                '&' -> append("*a*")
                '/' -> append("*s*")
                '.' -> append("*d*")
                '?' -> append("*q*")
                '\'' -> append("*at*")
                ' ' -> append("%20")
                else -> append(ch)
            }
        }
    }
}
