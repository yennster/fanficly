package io.github.yennster.fanficly.model

import kotlinx.serialization.Serializable

/**
 * A 1:1 mapping of AO3's `/works/search` form fields — the Kotlin port of the
 * iOS `AO3SearchFilters`. [queryItems] emits the `work_search[*]` key/value
 * pairs the search endpoint expects, preserving the same AO3 quirks the iOS app
 * documents (single-select rating folded into the query field for 2+ ratings,
 * NOT-exclusion composition, array-form warnings/categories).
 */
@Serializable
data class AO3SearchFilters(
    var query: String = "",
    var title: String = "",
    var creators: String = "",
    var revisedAt: String = "",
    var complete: TriState = TriState.ANY,
    var crossover: TriState = TriState.ANY,
    var singleChapter: Boolean = false,
    var wordCount: String = "",
    var languageId: String = "",
    var fandomNames: List<String> = emptyList(),
    var characterNames: List<String> = emptyList(),
    var relationshipNames: List<String> = emptyList(),
    var freeformNames: List<String> = emptyList(),
    var excludedFreeforms: List<String> = emptyList(),
    var ratings: Set<Rating> = emptySet(),
    var warnings: Set<ArchiveWarning> = emptySet(),
    var categories: Set<Category> = emptySet(),
    var hits: String = "",
    var kudosCount: String = "",
    var commentsCount: String = "",
    var bookmarksCount: String = "",
    var sortColumn: SortColumn = SortColumn.BEST_MATCH,
    var sortDirection: SortDirection = SortDirection.DESC,
) {
    @Serializable
    enum class TriState { ANY, YES, NO }

    @Serializable
    enum class Rating(val id: String, val displayName: String) {
        GENERAL("10", "General Audiences"),
        TEEN("11", "Teen And Up Audiences"),
        MATURE("12", "Mature"),
        EXPLICIT("13", "Explicit"),
        NOT_RATED("9", "Not Rated"),
    }

    @Serializable
    enum class ArchiveWarning(val id: String, val displayName: String) {
        CHOOSE_NOT_TO_USE("14", "Creator Chose Not To Use Archive Warnings"),
        NO_WARNINGS_APPLY("16", "No Archive Warnings Apply"),
        GRAPHIC_VIOLENCE("17", "Graphic Depictions Of Violence"),
        MAJOR_CHARACTER_DEATH("18", "Major Character Death"),
        RAPE_NON_CON("19", "Rape/Non-Con"),
        UNDERAGE("20", "Underage"),
    }

    @Serializable
    enum class Category(val id: String, val displayName: String) {
        FF("116", "F/F"),
        FM("22", "F/M"),
        GEN("21", "Gen"),
        MM("23", "M/M"),
        MULTI("2246", "Multi"),
        OTHER("24", "Other"),
    }

    @Serializable
    enum class SortColumn(val id: String, val displayName: String) {
        BEST_MATCH("_score", "Best Match"),
        AUTHOR("authors_to_sort_on", "Author"),
        TITLE("title_to_sort_on", "Title"),
        CREATED_AT("created_at", "Date Posted"),
        REVISED_AT("revised_at", "Date Updated"),
        WORD_COUNT("word_count", "Word Count"),
        HITS("hits", "Hits"),
        KUDOS_COUNT("kudos_count", "Kudos"),
        COMMENTS_COUNT("comments_count", "Comments"),
        BOOKMARKS_COUNT("bookmarks_count", "Bookmarks"),
    }

    @Serializable
    enum class SortDirection(val id: String, val displayName: String) {
        ASC("asc", "Ascending"),
        DESC("desc", "Descending"),
    }

    val isEmpty: Boolean
        get() = query.isEmpty() && title.isEmpty() && creators.isEmpty() &&
            revisedAt.isEmpty() && complete == TriState.ANY && crossover == TriState.ANY &&
            !singleChapter && wordCount.isEmpty() && languageId.isEmpty() &&
            fandomNames.isEmpty() && characterNames.isEmpty() && relationshipNames.isEmpty() &&
            freeformNames.isEmpty() && excludedFreeforms.isEmpty() && ratings.isEmpty() &&
            warnings.isEmpty() && categories.isEmpty() && hits.isEmpty() &&
            kudosCount.isEmpty() && commentsCount.isEmpty() && bookmarksCount.isEmpty()

    /**
     * The `work_search[*]` key/value pairs for the search URL. AO3's rating is a
     * single-select `<select>`: one rating uses the dedicated field; 2+ are OR-ed
     * via the free-text query field by [composedQueryString], because the array
     * form AND-matches and returns nothing. Warnings/categories legitimately stay
     * arrays. Returned as an ordered list since duplicate keys (the `[]` arrays)
     * are required.
     */
    fun queryItems(): List<Pair<String, String>> {
        val items = mutableListOf<Pair<String, String>>()
        val composed = composedQueryString()
        if (composed.isNotEmpty()) items += "work_search[query]" to composed
        if (title.isNotEmpty()) items += "work_search[title]" to title
        if (creators.isNotEmpty()) items += "work_search[creators]" to creators
        if (revisedAt.isNotEmpty()) items += "work_search[revised_at]" to revisedAt
        when (complete) {
            TriState.YES -> items += "work_search[complete]" to "true"
            TriState.NO -> items += "work_search[complete]" to "false"
            TriState.ANY -> {}
        }
        when (crossover) {
            TriState.YES -> items += "work_search[crossover]" to "T"
            TriState.NO -> items += "work_search[crossover]" to "F"
            TriState.ANY -> {}
        }
        if (singleChapter) items += "work_search[single_chapter]" to "1"
        if (wordCount.isNotEmpty()) items += "work_search[word_count]" to wordCount
        if (languageId.isNotEmpty()) items += "work_search[language_id]" to languageId
        if (fandomNames.isNotEmpty()) items += "work_search[fandom_names]" to fandomNames.joinToString(", ")
        if (characterNames.isNotEmpty()) items += "work_search[character_names]" to characterNames.joinToString(", ")
        if (relationshipNames.isNotEmpty()) items += "work_search[relationship_names]" to relationshipNames.joinToString(", ")
        if (freeformNames.isNotEmpty()) items += "work_search[freeform_names]" to freeformNames.joinToString(", ")
        if (ratings.size == 1) items += "work_search[rating_ids]" to ratings.first().id
        warnings.sortedBy { it.id }.forEach { items += "work_search[archive_warning_ids][]" to it.id }
        categories.sortedBy { it.id }.forEach { items += "work_search[category_ids][]" to it.id }
        if (hits.isNotEmpty()) items += "work_search[hits]" to hits
        if (kudosCount.isNotEmpty()) items += "work_search[kudos_count]" to kudosCount
        if (commentsCount.isNotEmpty()) items += "work_search[comments_count]" to commentsCount
        if (bookmarksCount.isNotEmpty()) items += "work_search[bookmarks_count]" to bookmarksCount
        items += "work_search[sort_column]" to sortColumn.id
        items += "work_search[sort_direction]" to sortDirection.id
        return items
    }

    /** The free-text `work_search[query]`: user terms + NOT-exclusions + a 2+ rating OR clause. */
    fun composedQueryString(): String {
        val parts = mutableListOf<String>()
        if (query.isNotEmpty()) parts += query
        for (excluded in excludedFreeforms) {
            val quoted = if (excluded.contains(" ")) "\"$excluded\"" else excluded
            parts += "NOT $quoted"
        }
        if (ratings.size > 1) {
            val clause = ratings.sortedBy { it.id }.joinToString(" OR ") { "rating_ids:${it.id}" }
            parts += "($clause)"
        }
        return parts.joinToString(" ")
    }

    /**
     * A normalized prompt-style string of the active filters — the Kotlin port
     * of iOS `promptText()`. Used to keep the search box in sync when a chip is
     * removed (so the matching text disappears too).
     */
    fun promptText(): String {
        val parts = mutableListOf<String>()
        parts += relationshipNames
        parts += characterNames
        parts += fandomNames
        parts += freeformNames
        parts += ratings.sortedBy { it.id }.map { it.displayName }
        parts += warnings.sortedBy { it.id }.map { it.displayName }
        parts += categories.sortedBy { it.id }.map { it.displayName }
        if (singleChapter) parts += "oneshot"
        when (complete) {
            TriState.YES -> parts += "complete"
            TriState.NO -> parts += "wip"
            TriState.ANY -> {}
        }
        when (crossover) {
            TriState.YES -> parts += "crossover"
            TriState.NO -> parts += "no crossovers"
            TriState.ANY -> {}
        }
        if (wordCount.isNotEmpty()) parts += wordCountPhrase(wordCount)
        if (languageId.isNotEmpty()) parts += "in $languageId"
        if (title.isNotEmpty()) {
            val quoted = if (title.contains(" ")) "\"$title\"" else title
            parts += "title:$quoted"
        }
        if (creators.isNotEmpty()) {
            val quoted = if (creators.contains(" ")) "\"$creators\"" else creators
            parts += "author:$quoted"
        }
        if (query.isNotEmpty()) parts += query
        parts += excludedFreeforms.map { "-$it" }
        return parts.joinToString(" ")
    }

    companion object {
        /** Renders a `work_search[word_count]` value back to an English phrase. */
        fun wordCountPhrase(wc: String): String {
            if (wc.startsWith(">")) return "over ${wc.drop(1)}"
            if (wc.startsWith("<")) return "under ${wc.drop(1)}"
            if (wc.contains("-")) {
                val p = wc.split("-")
                if (p.size == 2) return "between ${p[0]} and ${p[1]}"
            }
            return "$wc words"
        }
    }
}
