package io.github.yennster.fanficly.data

import io.github.yennster.fanficly.data.db.ReadingProgressEntity
import io.github.yennster.fanficly.data.db.ReadingProgressDao
import io.github.yennster.fanficly.data.db.SavedWorkDao
import io.github.yennster.fanficly.data.db.SavedWorkEntity
import io.github.yennster.fanficly.model.WorkSummary
import kotlinx.coroutines.flow.Flow

/**
 * Library persistence — the Android counterpart of iOS `WorkPersistence` +
 * `ReadingProgressStore`. "Follow" is local-only (no login), mirroring the iOS
 * `toggleFollow`: saving a work's metadata to the DB with `isFollowed = true`.
 */
class LibraryRepository(
    private val savedWorkDao: SavedWorkDao,
    private val progressDao: ReadingProgressDao,
) {
    fun observeAll(): Flow<List<SavedWorkEntity>> = savedWorkDao.observeAll()
    fun observeStarred(): Flow<List<SavedWorkEntity>> = savedWorkDao.observeStarred()
    fun observeDownloaded(): Flow<List<SavedWorkEntity>> = savedWorkDao.observeDownloaded()

    suspend fun isSaved(id: Int): Boolean = savedWorkDao.find(id) != null
    suspend fun find(id: Int): SavedWorkEntity? = savedWorkDao.find(id)

    /** Save (follow) a work, preserving any existing read state / flags. */
    suspend fun follow(summary: WorkSummary) {
        val existing = savedWorkDao.find(summary.id)
        val entity = SavedWorkEntity.from(summary, isFollowed = true).let {
            if (existing != null) it.copy(
                isStarred = existing.isStarred,
                isDownloaded = existing.isDownloaded,
                folder = existing.folder,
                savedAtMillis = existing.savedAtMillis,
                lastReadChapter = existing.lastReadChapter,
                lastReadParagraph = existing.lastReadParagraph,
                lastReadAtMillis = existing.lastReadAtMillis,
                lastSeenChapterCount = existing.lastSeenChapterCount,
            ) else it
        }
        savedWorkDao.upsert(entity)
    }

    suspend fun toggleFollow(summary: WorkSummary): Boolean {
        return if (savedWorkDao.find(summary.id) != null) {
            savedWorkDao.delete(summary.id); false
        } else {
            follow(summary); true
        }
    }

    suspend fun setStarred(id: Int, starred: Boolean) = savedWorkDao.setStarred(id, starred)
    suspend fun setFolder(id: Int, folder: String?) = savedWorkDao.setFolder(id, folder)
    suspend fun followedIds(): List<Int> = savedWorkDao.followedIds()

    /** Locally-followed works + their last-seen chapter counts, for the poller. */
    suspend fun followedWorks() = savedWorkDao.followedWorks()
    suspend fun setLastSeenChapterCount(id: Int, count: Int) = savedWorkDao.setLastSeenChapterCount(id, count)

    suspend fun loadProgress(id: Int): ReadingProgressEntity? = progressDao.find(id)

    /** Save reading position and mirror it onto the saved-work row for the library list. */
    suspend fun saveProgress(id: Int, chapter: Int, paragraph: Int) {
        val now = System.currentTimeMillis()
        progressDao.save(ReadingProgressEntity(id, chapter, paragraph, now))
        if (savedWorkDao.find(id) != null) {
            savedWorkDao.stampLastRead(id, chapter, paragraph, now)
        }
    }
}
