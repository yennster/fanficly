package io.github.yennster.fanficly

import android.content.Context
import io.github.yennster.fanficly.browse.PopularStore
import io.github.yennster.fanficly.data.LibraryRepository
import io.github.yennster.fanficly.data.SettingsStore
import io.github.yennster.fanficly.data.db.AppDatabase
import io.github.yennster.fanficly.net.AO3Client
import io.github.yennster.fanficly.net.LiveAO3Client
import io.github.yennster.fanficly.tts.SpeechController
import io.github.yennster.fanficly.widget.WidgetProgressStore

/**
 * Tiny manual dependency container — the Android counterpart of the iOS app's
 * environment wiring in `FanficlyApp`. A single [AO3Client] instance (shared
 * URLSession analogue: one OkHttp client behind the throttle), the Room-backed
 * [LibraryRepository], and the DataStore-backed [SettingsStore]. Held by
 * [FanficlyApplication] and reached by ViewModels via the application context.
 */
class AppContainer(context: Context, versionName: String) {
    val ao3Client: AO3Client = LiveAO3Client(context, versionName)

    private val db = AppDatabase.get(context)
    val libraryRepository = LibraryRepository(db.savedWorkDao(), db.readingProgressDao())
    val settingsStore = SettingsStore(context)
    val popularStore = PopularStore(context)
    val widgetProgressStore = WidgetProgressStore(context)
    val speechController = SpeechController(context)
}
