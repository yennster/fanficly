package io.github.yennster.fanficly.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import io.github.yennster.fanficly.ui.reader.ReaderFontFamily
import io.github.yennster.fanficly.ui.reader.ReaderTheme
import io.github.yennster.fanficly.ui.reader.ReadingMode
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.dataStore: DataStore<Preferences> by preferencesDataStore(name = "fanficly_settings")

/**
 * Reader typography + theme preferences, persisted via Jetpack DataStore — the
 * Android counterpart of the iOS `@AppStorage` reader keys. Exposed as a
 * [Flow] of an immutable [ReaderSettings] snapshot.
 */
data class ReaderSettings(
    val theme: ReaderTheme = ReaderTheme.SYSTEM,
    val fontFamily: ReaderFontFamily = ReaderFontFamily.SERIF,
    val fontSize: Float = 18f,
    val lineSpacing: Float = 6f,
    val paragraphSpacing: Float = 16f,
    val mode: ReadingMode = ReadingMode.CONTINUOUS,
)

class SettingsStore(private val context: Context) {
    private object Keys {
        val THEME = stringPreferencesKey("reader.theme")
        val FONT = stringPreferencesKey("reader.font")
        val FONT_SIZE = floatPreferencesKey("reader.fontSize")
        val LINE_SPACING = floatPreferencesKey("reader.lineSpacing")
        val PARA_SPACING = floatPreferencesKey("reader.paragraphSpacing")
        val MODE = stringPreferencesKey("reader.mode")
    }

    private fun read(p: Preferences) = ReaderSettings(
        theme = p[Keys.THEME]?.let { runCatching { ReaderTheme.valueOf(it) }.getOrNull() } ?: ReaderTheme.SYSTEM,
        fontFamily = p[Keys.FONT]?.let { runCatching { ReaderFontFamily.valueOf(it) }.getOrNull() } ?: ReaderFontFamily.SERIF,
        fontSize = p[Keys.FONT_SIZE] ?: 18f,
        lineSpacing = p[Keys.LINE_SPACING] ?: 6f,
        paragraphSpacing = p[Keys.PARA_SPACING] ?: 16f,
        mode = p[Keys.MODE]?.let { runCatching { ReadingMode.valueOf(it) }.getOrNull() } ?: ReadingMode.CONTINUOUS,
    )

    val settings: Flow<ReaderSettings> = context.dataStore.data.map { read(it) }

    suspend fun update(transform: (ReaderSettings) -> ReaderSettings) {
        context.dataStore.edit { p ->
            val next = transform(read(p))
            p[Keys.THEME] = next.theme.name
            p[Keys.FONT] = next.fontFamily.name
            p[Keys.FONT_SIZE] = next.fontSize
            p[Keys.LINE_SPACING] = next.lineSpacing
            p[Keys.PARA_SPACING] = next.paragraphSpacing
            p[Keys.MODE] = next.mode.name
        }
    }
}
