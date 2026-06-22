package io.github.yennster.fanficly.widget

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * The last-read story shown by [FanficlyWidgetProvider]. The Android port of the
 * iOS `WidgetStoryProgress` — but Android home-screen widgets share the app's
 * own storage and run on-device only, so this drops the iOS app-group + iCloud
 * KVS mirroring and just persists to a plain SharedPreferences.
 */
@Serializable
data class WidgetStorySnapshot(
    val id: Int,
    val title: String,
    val author: String,
    /** 0–1 reading fraction. */
    val progress: Float,
    val chapter: Int? = null,
    val paragraph: Int? = null,
    val updatedAt: Long = 0L,
)

/**
 * Persists the last-read story snapshot and refreshes any placed widgets — the
 * Android counterpart of iOS `WidgetProgressStore`. Fed from
 * `WorkViewModel.saveProgress` on every reading-position update.
 */
class WidgetProgressStore(context: Context) {
    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences("widget", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }

    fun save(id: Int, title: String, author: String, progress: Float, chapter: Int?, paragraph: Int?) {
        val snap = WidgetStorySnapshot(
            id = id, title = title, author = author,
            progress = progress.coerceIn(0f, 1f),
            chapter = chapter, paragraph = paragraph,
            updatedAt = System.currentTimeMillis(),
        )
        runCatching { prefs.edit().putString(KEY, json.encodeToString(snap)).apply() }
        FanficlyWidgetProvider.updateAll(appContext)
    }

    fun load(): WidgetStorySnapshot? {
        val s = prefs.getString(KEY, null) ?: return null
        return runCatching { json.decodeFromString<WidgetStorySnapshot>(s) }.getOrNull()
    }

    private companion object {
        const val KEY = "lastReadProgress"
    }
}
