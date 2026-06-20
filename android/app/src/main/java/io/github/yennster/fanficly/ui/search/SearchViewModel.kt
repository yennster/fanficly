package io.github.yennster.fanficly.ui.search

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.yennster.fanficly.FanficlyApplication
import io.github.yennster.fanficly.model.AO3SearchFilters
import io.github.yennster.fanficly.model.WorkSummary
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class SearchUiState(
    val queryText: String = "",
    val works: List<WorkSummary> = emptyList(),
    val isLoading: Boolean = false,
    val isLoadingMore: Boolean = false,
    val error: String? = null,
    val page: Int = 1,
    val totalPages: Int = 1,
    val sort: AO3SearchFilters.SortColumn = AO3SearchFilters.SortColumn.BEST_MATCH,
)

class SearchViewModel(app: Application) : AndroidViewModel(app) {
    private val container = (app as FanficlyApplication).container
    private val client = container.ao3Client
    private val repo = container.libraryRepository

    private val _state = MutableStateFlow(SearchUiState())
    val state: StateFlow<SearchUiState> = _state.asStateFlow()

    private val savedIds = MutableStateFlow<Set<Int>>(emptySet())
    val savedWorkIds: StateFlow<Set<Int>> = savedIds.asStateFlow()

    fun onQueryChange(text: String) {
        _state.value = _state.value.copy(queryText = text)
    }

    fun setSort(sort: AO3SearchFilters.SortColumn) {
        _state.value = _state.value.copy(sort = sort)
        if (_state.value.works.isNotEmpty()) submit()
    }

    /** Build filters from the search box. v1 treats the text as a free-text query
     *  (the iOS SearchPromptParser's smart parsing is a documented follow-up). */
    private fun buildFilters(page: Int): AO3SearchFilters =
        AO3SearchFilters().apply {
            query = _state.value.queryText.trim()
            sortColumn = _state.value.sort
        }

    fun submit() {
        val text = _state.value.queryText.trim()
        if (text.isEmpty()) return
        _state.value = _state.value.copy(isLoading = true, error = null, page = 1)
        viewModelScope.launch {
            runCatching { client.search(buildFilters(1), 1) }
                .onSuccess { r ->
                    _state.value = _state.value.copy(
                        works = r.works, isLoading = false, page = r.currentPage, totalPages = r.totalPages,
                    )
                }
                .onFailure { e ->
                    _state.value = _state.value.copy(isLoading = false, error = e.message ?: "Search failed")
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
            runCatching { client.search(buildFilters(next), next) }
                .onSuccess { r ->
                    _state.value = _state.value.copy(
                        works = _state.value.works + r.works,
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
