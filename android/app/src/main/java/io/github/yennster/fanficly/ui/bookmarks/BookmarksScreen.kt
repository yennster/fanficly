package io.github.yennster.fanficly.ui.bookmarks

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

data class BookmarksUiState(
    val works: List<WorkSummary> = emptyList(),
    val isLoading: Boolean = false,
    val isLoadingMore: Boolean = false,
    val error: String? = null,
    val page: Int = 1,
    val totalPages: Int = 1,
    val username: String? = null,
    val loggedIn: Boolean = true,
)

/**
 * The user's AO3 bookmarks — login-gated, live-fetched with infinite scroll.
 * The Android port of the iOS `BookmarksView`. Reuses the works-list parser
 * (`li.bookmark.blurb`) already wired into `AO3Client.fetchBookmarks`.
 */
class BookmarksViewModel(app: Application) : AndroidViewModel(app) {
    private val container = (app as FanficlyApplication).container
    private val client = container.ao3Client
    private val repo = container.libraryRepository

    private val _state = MutableStateFlow(BookmarksUiState())
    val state: StateFlow<BookmarksUiState> = _state.asStateFlow()

    private val savedIds = MutableStateFlow<Set<Int>>(emptySet())
    val savedWorkIds: StateFlow<Set<Int>> = savedIds.asStateFlow()
    private var started = false

    fun start() {
        if (started) return
        started = true
        val username = client.currentUsername()
        if (username == null) {
            _state.value = _state.value.copy(loggedIn = false)
            return
        }
        _state.value = _state.value.copy(username = username, loggedIn = true)
        load(1)
    }

    private fun load(page: Int) {
        val username = _state.value.username ?: return
        _state.value = _state.value.copy(isLoading = true, error = null)
        viewModelScope.launch {
            runCatching { client.fetchBookmarks(username, page) }
                .onSuccess { r ->
                    _state.value = _state.value.copy(
                        works = r.works, isLoading = false, page = r.currentPage, totalPages = r.totalPages,
                    )
                }
                .onFailure { e -> _state.value = _state.value.copy(isLoading = false, error = e.message ?: "Couldn't load bookmarks") }
            savedIds.value = repo.followedIds().toSet()
        }
    }

    fun loadMore() {
        val s = _state.value
        val username = s.username ?: return
        if (s.isLoadingMore || s.isLoading || s.page >= s.totalPages) return
        _state.value = s.copy(isLoadingMore = true)
        viewModelScope.launch {
            runCatching { client.fetchBookmarks(username, s.page + 1) }
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

    fun toggleSave(work: WorkSummary) {
        viewModelScope.launch { repo.toggleFollow(work); savedIds.value = repo.followedIds().toSet() }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BookmarksScreen(
    onBack: () -> Unit,
    onOpenWork: (Int) -> Unit,
    viewModel: BookmarksViewModel = viewModel(),
) {
    LaunchedEffect(Unit) { viewModel.start() }
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
                title = { Text("Bookmarks") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                !state.loggedIn -> Centered("Log in to AO3 (Settings) to see your private bookmarks.")
                state.isLoading && state.works.isEmpty() ->
                    Box(Modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator() }
                state.error != null && state.works.isEmpty() -> Centered(state.error!!)
                state.works.isEmpty() -> Centered("No bookmarks yet.")
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
