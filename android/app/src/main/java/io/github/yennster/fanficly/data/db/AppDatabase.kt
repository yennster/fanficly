package io.github.yennster.fanficly.data.db

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase

@Database(
    entities = [SavedWorkEntity::class, ReadingProgressEntity::class],
    version = 1,
    exportSchema = false,
)
abstract class AppDatabase : RoomDatabase() {
    abstract fun savedWorkDao(): SavedWorkDao
    abstract fun readingProgressDao(): ReadingProgressDao

    companion object {
        @Volatile private var instance: AppDatabase? = null

        fun get(context: Context): AppDatabase = instance ?: synchronized(this) {
            instance ?: Room.databaseBuilder(
                context.applicationContext,
                AppDatabase::class.java,
                "fanficly.db",
            ).fallbackToDestructiveMigration().build().also { instance = it }
        }
    }
}
