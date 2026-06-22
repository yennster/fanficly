package io.github.yennster.fanficly.ui.authors

import android.app.Application
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PersonRemove
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.yennster.fanficly.FanficlyApplication
import io.github.yennster.fanficly.data.db.FollowedAuthorEntity
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class FollowedAuthorsViewModel(app: Application) : AndroidViewModel(app) {
    private val repo = (app as FanficlyApplication).container.libraryRepository

    val authors: StateFlow<List<FollowedAuthorEntity>> = repo.observeFollowedAuthors()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    fun unfollow(username: String) = viewModelScope.launch { repo.unfollowAuthor(username) }
}

/**
 * The "Authors" tab — the list of authors the user follows (local-only). Tapping
 * one opens their works; the background poller notifies when a followed author
 * posts a new work. Port of the iOS `FollowedAuthorsView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FollowedAuthorsScreen(
    onBack: () -> Unit,
    onOpenAuthor: (username: String, displayName: String) -> Unit,
    viewModel: FollowedAuthorsViewModel = viewModel(),
) {
    val authors by viewModel.authors.collectAsStateWithLifecycle()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Followed Authors") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            if (authors.isEmpty()) {
                Box(Modifier.fillMaxSize().padding(32.dp), Alignment.Center) {
                    Text(
                        "No followed authors yet. Open an author's page (from a work's byline) and tap Follow. New works they post will notify you here.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                LazyColumn(Modifier.fillMaxSize()) {
                    items(authors, key = { it.username }) { author ->
                        ListItem(
                            headlineContent = { Text(author.displayName) },
                            supportingContent = { Text("Author", style = MaterialTheme.typography.labelSmall) },
                            leadingContent = { Icon(Icons.Filled.Person, contentDescription = null, tint = MaterialTheme.colorScheme.primary) },
                            trailingContent = {
                                IconButton(onClick = { viewModel.unfollow(author.username) }) {
                                    Icon(Icons.Filled.PersonRemove, contentDescription = "Unfollow ${author.displayName}")
                                }
                            },
                            modifier = Modifier.clickable { onOpenAuthor(author.username, author.displayName) },
                        )
                        HorizontalDivider(Modifier.padding(start = 16.dp))
                    }
                }
            }
        }
    }
}
