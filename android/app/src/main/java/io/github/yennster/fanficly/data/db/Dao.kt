package io.github.yennster.fanficly.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

@Dao
interface SavedWorkDao {
    @Query("SELECT * FROM saved_works ORDER BY savedAtMillis DESC")
    fun observeAll(): Flow<List<SavedWorkEntity>>

    @Query("SELECT * FROM saved_works WHERE isStarred = 1 ORDER BY savedAtMillis DESC")
    fun observeStarred(): Flow<List<SavedWorkEntity>>

    @Query("SELECT * FROM saved_works WHERE isDownloaded = 1 ORDER BY savedAtMillis DESC")
    fun observeDownloaded(): Flow<List<SavedWorkEntity>>

    @Query("SELECT * FROM saved_works WHERE ao3Id = :id LIMIT 1")
    suspend fun find(id: Int): SavedWorkEntity?

    @Query("SELECT ao3Id FROM saved_works WHERE isFollowed = 1")
    suspend fun followedIds(): List<Int>

    @Query("SELECT * FROM saved_works WHERE isFollowed = 1")
    suspend fun followedWorks(): List<SavedWorkEntity>

    @Query("UPDATE saved_works SET lastSeenChapterCount = :count WHERE ao3Id = :id")
    suspend fun setLastSeenChapterCount(id: Int, count: Int)

    @Upsert
    suspend fun upsert(work: SavedWorkEntity)

    @Query("DELETE FROM saved_works WHERE ao3Id = :id")
    suspend fun delete(id: Int)

    @Query("UPDATE saved_works SET isStarred = :starred WHERE ao3Id = :id")
    suspend fun setStarred(id: Int, starred: Boolean)

    @Query("UPDATE saved_works SET folder = :folder WHERE ao3Id = :id")
    suspend fun setFolder(id: Int, folder: String?)

    @Query("""UPDATE saved_works
              SET lastReadChapter = :chapter, lastReadParagraph = :paragraph, lastReadAtMillis = :at
              WHERE ao3Id = :id""")
    suspend fun stampLastRead(id: Int, chapter: Int, paragraph: Int, at: Long)
}

@Dao
interface FollowedAuthorDao {
    @Query("SELECT * FROM followed_authors ORDER BY displayName COLLATE NOCASE ASC")
    fun observeAll(): Flow<List<FollowedAuthorEntity>>

    @Query("SELECT * FROM followed_authors")
    suspend fun all(): List<FollowedAuthorEntity>

    @Query("SELECT * FROM followed_authors WHERE username = :username LIMIT 1")
    suspend fun find(username: String): FollowedAuthorEntity?

    @Upsert
    suspend fun upsert(author: FollowedAuthorEntity)

    @Query("DELETE FROM followed_authors WHERE username = :username")
    suspend fun delete(username: String)

    @Query("UPDATE followed_authors SET knownWorkIds = :ids, lastCheckedAtMillis = :checkedAt WHERE username = :username")
    suspend fun updateChecked(username: String, ids: String, checkedAt: Long)
}

@Dao
interface ReadingProgressDao {
    @Query("SELECT * FROM reading_progress WHERE ao3Id = :id LIMIT 1")
    suspend fun find(id: Int): ReadingProgressEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun save(progress: ReadingProgressEntity)
}
