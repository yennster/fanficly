package io.github.yennster.fanficly.browse

import android.content.Context
import io.github.yennster.fanficly.model.PopularSnapshot
import io.github.yennster.fanficly.net.AO3Client
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/**
 * On-device cache for the live popular snapshot — the Kotlin port of iOS
 * `PopularStore`. Refreshed at most once a day (the data is AO3's cumulative
 * work counts, which barely move day to day). Never throws: on failure it keeps
 * the existing cache so the UI keeps showing what it had (or the curated seed).
 */
class PopularStore(context: Context) {
    private val prefs = context.applicationContext.getSharedPreferences("popular", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }

    fun cached(): PopularSnapshot? {
        val s = prefs.getString(KEY, null) ?: return null
        return runCatching { json.decodeFromString<PopularSnapshot>(s) }.getOrNull()
    }

    fun isStale(snapshot: PopularSnapshot?): Boolean {
        if (snapshot == null) return true
        return System.currentTimeMillis() - snapshot.fetchedAt > MAX_AGE_MS
    }

    /** Fetches + caches only when the cache is missing or older than a day. */
    suspend fun refreshIfStale(client: AO3Client): PopularSnapshot? {
        val current = cached()
        if (!isStale(current)) return current
        val fresh = runCatching { client.fetchPopularSnapshot() }.getOrNull() ?: return current
        runCatching { prefs.edit().putString(KEY, json.encodeToString(fresh)).apply() }
        return fresh
    }

    companion object {
        private const val KEY = "popular.snapshot.v1"
        private const val MAX_AGE_MS = 24L * 60 * 60 * 1000
    }
}
