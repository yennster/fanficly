package io.github.yennster.fanficly.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

// AO3 brand maroon, matching the iOS marketing canvas (#990000).
private val Maroon = Color(0xFF990000)
private val MaroonLight = Color(0xFFC62828)
private val MaroonDark = Color(0xFF7A0000)

private val LightColors = lightColorScheme(
    primary = Maroon,
    onPrimary = Color.White,
    secondary = MaroonLight,
    onSecondary = Color.White,
    background = Color(0xFFFFFBFB),
    surface = Color(0xFFFFFBFB),
)

private val DarkColors = darkColorScheme(
    primary = MaroonLight,
    onPrimary = Color.White,
    secondary = Maroon,
    onSecondary = Color.White,
    background = Color(0xFF141416),
    surface = Color(0xFF1C1C1E),
)

@Composable
fun FanficlyTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (darkTheme) DarkColors else LightColors,
        typography = Typography(),
        content = content,
    )
}
