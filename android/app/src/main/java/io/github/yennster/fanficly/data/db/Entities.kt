package io.github.yennster.fanficly.data.db

import androidx.room.Entity
import androidx.room.PrimaryKey
import io.github.yennster.fanficly.model.WorkSummary

/**
 * A work saved to the on-device Library — the Room analogue of the iOS
 * SwiftData `Work` model. Tag lists are stored as a single `", "`-joined string
 * (AO3 tags don't contain commas in a way that breaks this for display).
 */
@Entity(tableName = "saved_works")
data class SavedWorkEntity(
    @PrimaryKey val ao3Id: Int,
    val title: String,
    val author: String,
    val authorUsername: String,
    val summary: String,
    val rating: String,
    val fandoms: String,
    val relationships: String,
    val characters: String,
    val freeforms: String,
    val wordCount: Int,
    val chapterCount: Int,
    val totalChapters: Int?,
    val language: String,
    val kudos: Int,
    val hits: Int,
    val isComplete: Boolean,
    val isFollowed: Boolean,
    val isStarred: Boolean,
    val isDownloaded: Boolean,
    val folder: String?,
    val savedAtMillis: Long,
    val updatedAtMillis: Long?,
    // Last reading position, mirrored from ReadingProgress for quick row display.
    val lastReadChapter: Int?,
    val lastReadParagraph: Int?,
    val lastReadAtMillis: Long?,
) {
    fun toSummary() = WorkSummary(
        id = ao3Id, title = title, author = author, authorUsername = authorUsername,
        summary = summary, rating = rating, warnings = emptyList(), categories = emptyList(),
        fandoms = fandoms.splitTags(), characters = characters.splitTags(),
        relationships = relationships.splitTags(), freeforms = freeforms.splitTags(),
        wordCount = wordCount, chapterCount = chapterCount, totalChapters = totalChapters,
        language = language, kudos = kudos, hits = hits, isComplete = isComplete,
        updatedAtMillis = updatedAtMillis,
    )

    companion object {
        fun from(s: WorkSummary, isFollowed: Boolean = true): SavedWorkEntity = SavedWorkEntity(
            ao3Id = s.id, title = s.title, author = s.author, authorUsername = s.authorUsername,
            summary = s.summary, rating = s.rating,
            fandoms = s.fandoms.joinTags(), relationships = s.relationships.joinTags(),
            characters = s.characters.joinTags(), freeforms = s.freeforms.joinTags(),
            wordCount = s.wordCount, chapterCount = s.chapterCount, totalChapters = s.totalChapters,
            language = s.language, kudos = s.kudos, hits = s.hits, isComplete = s.isComplete,
            isFollowed = isFollowed, isStarred = false, isDownloaded = false, folder = null,
            savedAtMillis = System.currentTimeMillis(), updatedAtMillis = s.updatedAtMillis,
            lastReadChapter = null, lastReadParagraph = null, lastReadAtMillis = null,
        )
    }
}

/** Per-work reading position — the Room analogue of SwiftData `ReadingProgress`. */
@Entity(tableName = "reading_progress")
data class ReadingProgressEntity(
    @PrimaryKey val ao3Id: Int,
    val chapterIndex: Int,
    val paragraphIndex: Int,
    val updatedAtMillis: Long,
)

private fun List<String>.joinTags() = joinToString("  ") // unlikely delimiter
private fun String.splitTags(): List<String> =
    if (isEmpty()) emptyList() else split("  ")
