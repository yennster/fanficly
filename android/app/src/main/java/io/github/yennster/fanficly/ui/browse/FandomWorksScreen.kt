package io.github.yennster.fanficly.ui.browse

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
import io.github.yennster.fanficly.model.AO3SearchFilters
import io.github.yennster.fanficly.model.WorkSummary
import io.github.yennster.fanficly.ui.components.WorkRow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class FandomWorksUiState(
    val title: String = "",
    val works: List<WorkSummary> = emptyList(),
    val isLoading: Boolean = false,
    val isLoadingMore: Boolean = false,
    val error: String? = null,
    val page: Int = 1,
    val totalPages: Int = 1,
)

/**
 * Works for a browse fandom or popular tag — the Android counterpart of the iOS
 * `FandomWorksView`. Built from a single tag (fandom / relationship / character)
 * + a sort; names arrive already AO3-canonical (live fandom list or curated
 * seed), so no tag resolution is needed before searching.
 */
class FandomWorksViewModel(app: Application) : AndroidViewModel(app) {
    private val container = (app as FanficlyApplication).container
    private val client = container.ao3Client
    private val repo = container.libraryRepository

    private val _state = MutableStateFlow(FandomWorksUiState())
    val state: StateFlow<FandomWorksUiState> = _state.asStateFlow()

    private val savedIds = MutableStateFlow<Set<Int>>(emptySet())
    val savedWorkIds: StateFlow<Set<Int>> = savedIds.asStateFlow()

    private var filters = AO3SearchFilters()

    /** Guards on the loaded works (not a one-shot flag): a successful load won't
     *  re-fetch on re-entry, but a failure (works still empty) retries. */
    fun start(field: String, name: String, title: String, sortColumnId: String) {
        val s = _state.value
        if (s.works.isNotEmpty() || s.isLoading) return
        filters = AO3SearchFilters().apply {
            when (field) {
                "relationship" -> relationshipNames = listOf(name)
                "character" -> characterNames = listOf(name)
                else -> fandomNames = listOf(name)
            }
            sortColumn = AO3SearchFilters.SortColumn.entries.firstOrNull { it.id == sortColumnId }
                ?: AO3SearchFilters.SortColumn.REVISED_AT
            sortDirection = AO3SearchFilters.SortDirection.DESC
        }
        _state.value = _state.value.copy(title = title)
        load(page = 1)
    }

    private fun load(page: Int) {
        _state.value = _state.value.copy(isLoading = true, error = null)
        viewModelScope.launch {
            runCatching { client.search(filters, page) }
                .onSuccess { r ->
                    _state.value = _state.value.copy(
                        works = r.works, isLoading = false, page = r.currentPage, totalPages = r.totalPages,
                    )
                }
                .onFailure { e ->
                    _state.value = _state.value.copy(isLoading = false, error = e.message ?: "Couldn't load works")
                }
            refreshSavedIds()
        }
    }

    fun loadMore() {
        val s = _state.value
        if (s.isLoadingMore || s.isLoading || s.page >= s.totalPages) return
        _state.value = s.copy(isLoadingMore = true)
        viewModelScope.launch {
            val next = s.page + 1
            runCatching { client.search(filters, next) }
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
        viewModelScope.launch { repo.toggleFollow(work); refreshSavedIds() }
    }

    private suspend fun refreshSavedIds() { savedIds.value = repo.followedIds().toSet() }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FandomWorksScreen(
    field: String,
    name: String,
    title: String,
    sort: String,
    onBack: () -> Unit,
    onOpenWork: (Int) -> Unit,
    viewModel: FandomWorksViewModel = viewModel(),
) {
    LaunchedEffect(field, name, sort) { viewModel.start(field, name, title, sort) }
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
                title = { Text(state.title.ifEmpty { title }, maxLines = 1) },
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
                state.isLoading && state.works.isEmpty() ->
                    Box(Modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator() }
                state.error != null && state.works.isEmpty() ->
                    CenteredText(state.error!!)
                state.works.isEmpty() ->
                    CenteredText("No works found.")
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
private fun CenteredText(message: String) {
    Box(Modifier.fillMaxSize().padding(32.dp), Alignment.Center) {
        Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
