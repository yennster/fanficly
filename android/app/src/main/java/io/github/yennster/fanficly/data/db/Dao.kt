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
interface ReadingProgressDao {
    @Query("SELECT * FROM reading_progress WHERE ao3Id = :id LIMIT 1")
    suspend fun find(id: Int): ReadingProgressEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun save(progress: ReadingProgressEntity)
}
