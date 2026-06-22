package io.github.yennster.fanficly.ui.reader

import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily

/**
 * Reader palettes — the Kotlin port of iOS `ReaderTheme`. Each theme provides a
 * background + foreground; `SYSTEM` defers to the Material color scheme.
 */
enum class ReaderTheme(val displayName: String) {
    SYSTEM("Match System"),
    LIGHT("Light"),
    SEPIA("Sepia"),
    DARK("Dark"),
    OLED_BLACK("OLED Black"),
    DRACULA("Dracula Navy");

    fun background(systemBackground: Color): Color = when (this) {
        SYSTEM -> systemBackground
        LIGHT -> Color(0xFFFCFCF7)
        SEPIA -> Color(0xFFF7EDD9)
        DARK -> Color(0xFF1F1F21)
        OLED_BLACK -> Color.Black
        DRACULA -> Color(0xFF282A36)
    }

    fun foreground(systemForeground: Color): Color = when (this) {
        SYSTEM -> systemForeground
        LIGHT -> Color(0xFF14141A)
        SEPIA -> Color(0xFF4D3319)
        DARK -> Color(0xFFEBEBE6)
        OLED_BLACK -> Color(0xFFE0E0D9)
        DRACULA -> Color(0xFFF8F8F2)
    }

    /** null = follow system; else force light/dark for the reader chrome. */
    val isDark: Boolean?
        get() = when (this) {
            SYSTEM -> null
            LIGHT, SEPIA -> false
            DARK, OLED_BLACK, DRACULA -> true
        }
}

/**
 * Reader layout mode — a subset of the iOS `ReadingMode`. `PAGINATED` is iOS's
 * "Swipe by chapter" (a horizontal chapter pager); iOS's measured page-by-page
 * mode is a follow-up.
 */
enum class ReadingMode(val displayName: String) {
    CONTINUOUS("Continuous scroll"),
    PAGINATED("Swipe by chapter"),
}

enum class ReaderFontFamily(val displayName: String) {
    SERIF("Serif"),
    SANS("Sans"),
    MONO("Monospace");

    @Composable
    fun toFontFamily(): FontFamily = when (this) {
        SERIF -> FontFamily.Serif
        SANS -> FontFamily.SansSerif
        MONO -> FontFamily.Monospace
    }
}

object ReaderMetrics {
    val fontSizeRange = 12f..30f
    val lineSpacingRange = 0f..20f
    val paragraphSpacingRange = 2f..80f
}
