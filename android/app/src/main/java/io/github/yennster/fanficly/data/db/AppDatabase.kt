package io.github.yennster.fanficly.data.db

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

@Database(
    entities = [SavedWorkEntity::class, ReadingProgressEntity::class],
    version = 2,
    exportSchema = false,
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun savedWorkDao(): SavedWorkDao
    abstract fun readingProgressDao(): ReadingProgressDao

    companion object {
        @Volatile private var instance: AppDatabase? = null

        // v2 adds saved_works.lastSeenChapterCount for the new-chapter poller.
        // An additive ALTER keeps the user's library intact across the upgrade.
        private val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(db: SupportSQLiteDatabase) {
                db.execSQL("ALTER TABLE saved_works ADD COLUMN lastSeenChapterCount INTEGER")
            }
        }

        fun get(context: Context): AppDatabase = instance ?: synchronized(this) {
            instance ?: Room.databaseBuilder(
                context.applicationContext,
                AppDatabase::class.java,
                "fanficly.db",
            ).addMigrations(MIGRATION_1_2).fallbackToDestructiveMigration().build().also { instance = it }
        }
    }
}
