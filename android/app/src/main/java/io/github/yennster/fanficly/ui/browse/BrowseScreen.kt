package io.github.yennster.fanficly.ui.browse

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Brush
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Headphones
import androidx.compose.material.icons.filled.MenuBook
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.SportsEsports
import androidx.compose.material.icons.filled.TheaterComedy
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import io.github.yennster.fanficly.browse.FandomCatalog
import io.github.yennster.fanficly.model.FandomIcon

/**
 * The Browse tab: AO3's 10 media categories. Tapping one opens its (live, with
 * curated fallback) fandom list. Port of the iOS `BrowseView` landing list.
 */
@Composable
fun BrowseScreen(onOpenCategory: (String) -> Unit) {
    LazyColumn(Modifier.fillMaxSize()) {
        items(FandomCatalog.all, key = { it.id }) { category ->
            ListItem(
                headlineContent = { Text(category.name) },
                leadingContent = {
                    Icon(
                        fandomIconVector(category.icon),
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.primary,
                    )
                },
                colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surface),
                modifier = Modifier.clickable { onOpenCategory(category.id) },
            )
            HorizontalDivider()
        }
    }
}

/** Maps the model-layer [FandomIcon] to a Compose icon (the iOS SF Symbol twin). */
fun fandomIconVector(icon: FandomIcon): ImageVector = when (icon) {
    FandomIcon.ANIME -> Icons.Filled.AutoAwesome
    FandomIcon.BOOK -> Icons.Filled.MenuBook
    FandomIcon.CARTOON -> Icons.Filled.Brush
    FandomIcon.PERSON -> Icons.Filled.Person
    FandomIcon.FILM -> Icons.Filled.Movie
    FandomIcon.MUSIC -> Icons.Filled.MusicNote
    FandomIcon.AUDIO -> Icons.Filled.Headphones
    FandomIcon.THEATER -> Icons.Filled.TheaterComedy
    FandomIcon.TV -> Icons.Filled.Tv
    FandomIcon.GAME -> Icons.Filled.SportsEsports
}

/** Heart/person/book icons for the Popular tab's segments. */
val popularShipIcon: ImageVector get() = Icons.Filled.Favorite
val popularCharacterIcon: ImageVector get() = Icons.Filled.Person
val popularFandomIcon: ImageVector get() = Icons.Filled.MenuBook
