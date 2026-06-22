package io.github.yennster.fanficly.data.db

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

@Database(
    entities = [SavedWorkEntity::class, ReadingProgressEntity::class, FollowedAuthorEntity::class],
    version = 3,
    exportSchema = false,
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun savedWorkDao(): SavedWorkDao
    abstract fun readingProgressDao(): ReadingProgressDao
    abstract fun followedAuthorDao(): FollowedAuthorDao

    companion object {
        @Volatile private var instance: AppDatabase? = null

        // v2 adds saved_works.lastSeenChapterCount for the new-chapter poller.
        // An additive ALTER keeps the user's library intact across the upgrade.
        private val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE saved_works ADD COLUMN lastSeenChapterCount INTEGER")
            }
        }

        // v3 adds the followed_authors table (the Authors tab + poller).
        private val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL(
                    "CREATE TABLE IF NOT EXISTS followed_authors (" +
                        "username TEXT NOT NULL PRIMARY KEY, " +
                        "displayName TEXT NOT NULL, " +
                        "followedAtMillis INTEGER NOT NULL, " +
                        "lastCheckedAtMillis INTEGER, " +
                        "knownWorkIds TEXT NOT NULL)",
                )
            }
        }

        fun get(context: Context): AppDatabase = instance ?: synchronized(this) {
            instance ?: Room.databaseBuilder(
                context.applicationContext,
                AppDatabase::class.java,
                "fanficly.db",
            ).addMigrations(MIGRATION_1_2, MIGRATION_2_3).fallbackToDestructiveMigration().build().also { instance = it }
        }
    }
}
