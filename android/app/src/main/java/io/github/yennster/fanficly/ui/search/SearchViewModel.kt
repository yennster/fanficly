package io.github.yennster.fanficly.ui.search

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.yennster.fanficly.FanficlyApplication
import io.github.yennster.fanficly.model.AO3SearchFilters
import io.github.yennster.fanficly.model.WorkSummary
import io.github.yennster.fanficly.search.SearchPromptParser
import io.github.yennster.fanficly.search.TagResolver
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class SearchUiState(
    val queryText: String = "",
    /** The structured filters the prompt parsed into — drives the filter chips. */
    val parsed: AO3SearchFilters = AO3SearchFilters(),
    val works: List<WorkSummary> = emptyList(),
    val isLoading: Boolean = false,
    val isLoadingMore: Boolean = false,
    val hasSearched: Boolean = false,
    val error: String? = null,
    val page: Int = 1,
    val totalPages: Int = 1,
    val sortColumn: AO3SearchFilters.SortColumn = AO3SearchFilters.SortColumn.BEST_MATCH,
    val sortDirection: AO3SearchFilters.SortDirection = AO3SearchFilters.SortDirection.DESC,
)

/**
 * Drives the smart search screen — the Android counterpart of the iOS
 * `SearchView` logic. The prompt is parsed by [SearchPromptParser] into
 * structured [AO3SearchFilters] (shown as removable chips); tags are resolved to
 * AO3's canonical names by [TagResolver] before the first search of a prompt, so
 * results match the iOS app. Chip removals and sort changes re-search without
 * re-resolving (tags are already canonical).
 */
class SearchViewModel(app: Application) : AndroidViewModel(app) {
    private val container = (app as FanficlyApplication).container
    private val client = container.ao3Client
    private val repo = container.libraryRepository
    private val parser = SearchPromptParser()

    private val _state = MutableStateFlow(SearchUiState())
    val state: StateFlow<SearchUiState> = _state.asStateFlow()

    private val savedIds = MutableStateFlow<Set<Int>>(emptySet())
    val savedWorkIds: StateFlow<Set<Int>> = savedIds.asStateFlow()

    /** User typing: re-parse live so the chips reflect the prompt as it's edited. */
    fun onQueryChange(text: String) {
        _state.value = _state.value.copy(queryText = text, parsed = parser.parse(text))
    }

    fun setSortColumn(column: AO3SearchFilters.SortColumn) {
        if (column == _state.value.sortColumn) return
        _state.value = _state.value.copy(sortColumn = column)
        if (_state.value.works.isNotEmpty()) runSearch(resolve = false)
    }

    fun toggleSortDirection() {
        val next = if (_state.value.sortDirection == AO3SearchFilters.SortDirection.ASC) {
            AO3SearchFilters.SortDirection.DESC
        } else {
            AO3SearchFilters.SortDirection.ASC
        }
        _state.value = _state.value.copy(sortDirection = next)
        if (_state.value.works.isNotEmpty()) runSearch(resolve = false)
    }

    /** Submit the search box: parse, resolve tags, then search from page 1. */
    fun submit() {
        if (_state.value.queryText.trim().isEmpty()) return
        val parsed = parser.parse(_state.value.queryText)
        // A prompt-driven sort ("most kudos", "recently updated") seeds the sort
        // bar; otherwise the persistent sort selection carries across searches.
        val (col, dir) = if (parsed.sortColumn != AO3SearchFilters.SortColumn.BEST_MATCH) {
            parsed.sortColumn to parsed.sortDirection
        } else {
            _state.value.sortColumn to _state.value.sortDirection
        }
        _state.value = _state.value.copy(parsed = parsed, sortColumn = col, sortDirection = dir)
        runSearch(resolve = true)
    }

    /** Remove a filter chip: mutate the parsed filters, sync the box, re-search. */
    fun removeChip(mutate: (AO3SearchFilters) -> Unit) {
        val updated = _state.value.parsed.copy().apply(mutate)
        _state.value = _state.value.copy(parsed = updated, queryText = updated.promptText())
        if (_state.value.works.isNotEmpty()) runSearch(resolve = false)
    }

    private fun runSearch(resolve: Boolean) {
        _state.value = _state.value.copy(isLoading = true, error = null, page = 1)
        viewModelScope.launch {
            var filters = _state.value.parsed.copy()
            if (resolve) {
                filters = runCatching { TagResolver.resolve(filters, client) }.getOrDefault(filters)
            }
            filters.sortColumn = _state.value.sortColumn
            filters.sortDirection = _state.value.sortDirection
            // Reflect canonical names (and any cleared query) back into the chips.
            _state.value = _state.value.copy(parsed = filters)
            runCatching { client.search(filters, 1) }
                .onSuccess { r ->
                    _state.value = _state.value.copy(
                        works = r.works, isLoading = false, hasSearched = true,
                        page = r.currentPage, totalPages = r.totalPages,
                    )
                }
                .onFailure { e ->
                    _state.value = _state.value.copy(
                        isLoading = false, hasSearched = true, works = emptyList(),
                        error = e.message ?: "Search failed",
                    )
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
            val filters = s.parsed.copy().apply {
                sortColumn = s.sortColumn
                sortDirection = s.sortDirection
            }
            runCatching { client.search(filters, next) }
                .onSuccess { r ->
                    val existing = _state.value.works.map { it.id }.toSet()
                    _state.value = _state.value.copy(
                        works = _state.value.works + r.works.filter { it.id !in existing },
                        isLoadingMore = false, page = r.currentPage, totalPages = r.totalPages,
                    )
                }
                .onFailure { e ->
                    _state.value = _state.value.copy(isLoadingMore = false, error = e.message)
                }
        }
    }

    fun toggleSave(work: WorkSummary) {
        viewModelScope.launch {
            repo.toggleFollow(work)
            refreshSavedIds()
        }
    }

    private suspend fun refreshSavedIds() {
        savedIds.value = repo.followedIds().toSet()
    }
}
