package io.github.yennster.fanficly.ui.authors

import android.app.Application
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.PersonAddAlt
import androidx.compose.material.icons.filled.PersonRemove
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.yennster.fanficly.FanficlyApplication
import io.github.yennster.fanficly.model.WorkSummary
import io.github.yennster.fanficly.ui.components.WorkRow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class AuthorWorksUiState(
    val username: String = "",
    val displayName: String = "",
    val works: List<WorkSummary> = emptyList(),
    val isLoading: Boolean = false,
    val isLoadingMore: Boolean = false,
    val error: String? = null,
    val page: Int = 1,
    val totalPages: Int = 1,
    val isFollowing: Boolean = false,
)

/**
 * One author's works (infinite scroll) with a Follow / unfollow action — the
 * Android port of the iOS `AuthorWorksView`. Follows are local-only (no login):
 * the background poller notifies when a followed author posts a new work. The
 * Follow seeds the currently-visible work ids so the first poll doesn't alert
 * for the existing back catalogue.
 */
class AuthorWorksViewModel(app: Application) : AndroidViewModel(app) {
    private val container = (app as FanficlyApplication).container
    private val client = container.ao3Client
    private val repo = container.libraryRepository

    private val _state = MutableStateFlow(AuthorWorksUiState())
    val state: StateFlow<AuthorWorksUiState> = _state.asStateFlow()

    private val savedIds = MutableStateFlow<Set<Int>>(emptySet())
    val savedWorkIds: StateFlow<Set<Int>> = savedIds.asStateFlow()
    private var started = false

    fun start(username: String, displayName: String) {
        if (started) return
        started = true
        _state.value = _state.value.copy(username = username, displayName = displayName)
        viewModelScope.launch { _state.value = _state.value.copy(isFollowing = repo.isAuthorFollowed(username)) }
        load(1)
    }

    private fun load(page: Int) {
        val username = _state.value.username
        if (username.isEmpty()) return
        _state.value = _state.value.copy(isLoading = true, error = null)
        viewModelScope.launch {
            runCatching { client.fetchAuthorWorks(username, page) }
                .onSuccess { r ->
                    _state.value = _state.value.copy(
                        works = r.works, isLoading = false, page = r.currentPage, totalPages = r.totalPages,
                    )
                }
                .onFailure { e -> _state.value = _state.value.copy(isLoading = false, error = e.message ?: "Couldn't load works") }
            savedIds.value = repo.followedIds().toSet()
        }
    }

    fun loadMore() {
        val s = _state.value
        if (s.isLoadingMore || s.isLoading || s.page >= s.totalPages) return
        _state.value = s.copy(isLoadingMore = true)
        viewModelScope.launch {
            runCatching { client.fetchAuthorWorks(s.username, s.page + 1) }
                .onSuccess { r ->
                    val existing = _state.value.works.map { it.id }.toSet()
                    _state.value = _state.value.copy(
                        works = _state.value.works + r.works.filter { it.id !in existing },
                        isLoadingMore = false, page = r.currentPage, totalPages = r.totalPages,
                    )
                }
                .onFailure { e -> _state.value = _state.value.copy(isLoadingMore = false, error = e.message) }
        }
    }

    fun toggleFollow() {
        val s = _state.value
        if (s.username.isEmpty()) return
        viewModelScope.launch {
            val now = repo.toggleFollowAuthor(s.username, s.displayName, s.works.map { it.id })
            _state.value = _state.value.copy(isFollowing = now)
        }
    }

    fun toggleSave(work: WorkSummary) {
        viewModelScope.launch { repo.toggleFollow(work); savedIds.value = repo.followedIds().toSet() }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AuthorWorksScreen(
    username: String,
    displayName: String,
    onBack: () -> Unit,
    onOpenWork: (Int) -> Unit,
    viewModel: AuthorWorksViewModel = viewModel(),
) {
    LaunchedEffect(username) { viewModel.start(username, displayName) }
    val state by viewModel.state.collectAsStateWithLifecycle()
    val savedIds by viewModel.savedWorkIds.collectAsStateWithLifecycle()
    val listState = rememberLazyListState()

    val shouldLoadMore by remember {
        derivedStateOf {
            val last = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            last >= state.works.size - 3 && state.works.isNotEmpty()
        }
    }
    LaunchedEffect(shouldLoadMore) { if (shouldLoadMore) viewModel.loadMore() }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(state.displayName.ifEmpty { displayName }, maxLines = 1) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    if (username.isNotEmpty()) {
                        IconButton(onClick = { viewModel.toggleFollow() }) {
                            Icon(
                                if (state.isFollowing) Icons.Filled.PersonRemove else Icons.Filled.PersonAddAlt,
                                contentDescription = if (state.isFollowing) "Unfollow author" else "Follow author",
                                tint = if (state.isFollowing) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                            )
                        }
                    }
                },
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                state.isLoading && state.works.isEmpty() ->
                    Box(Modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator() }
                state.error != null && state.works.isEmpty() -> Centered(state.error!!)
                state.works.isEmpty() -> Centered("This author has no works to show.")
                else -> LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
                    items(state.works, key = { it.id }) { work ->
                        WorkRow(
                            work = work,
                            isSaved = work.id in savedIds,
                            onClick = { onOpenWork(work.id) },
                            onToggleSave = { viewModel.toggleSave(work) },
                        )
                        HorizontalDivider(Modifier.padding(start = 16.dp))
                    }
                    if (state.isLoadingMore) {
                        item {
                            Box(Modifier.fillMaxWidth().padding(16.dp), Alignment.Center) {
                                CircularProgressIndicator(strokeWidth = 2.dp)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun Centered(message: String) {
    Box(Modifier.fillMaxSize().padding(32.dp), Alignment.Center) {
        Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
