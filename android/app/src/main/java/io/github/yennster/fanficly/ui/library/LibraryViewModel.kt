package io.github.yennster.fanficly.ui.library

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.yennster.fanficly.FanficlyApplication
import io.github.yennster.fanficly.data.db.SavedWorkEntity
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

enum class LibraryFilter(val label: String) {
    ALL("All"), STARRED("Starred"), DOWNLOADED("Downloaded")
}

class LibraryViewModel(app: Application) : AndroidViewModel(app) {
    private val repo = (app as FanficlyApplication).container.libraryRepository

    private val _filter = MutableStateFlow(LibraryFilter.ALL)
    val filter: StateFlow<LibraryFilter> = _filter.asStateFlow()

    val works: StateFlow<List<SavedWorkEntity>> = repo.observeAll()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val starred: StateFlow<List<SavedWorkEntity>> = repo.observeStarred()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val downloaded: StateFlow<List<SavedWorkEntity>> = repo.observeDownloaded()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    fun setFilter(f: LibraryFilter) { _filter.value = f }

    fun toggleStar(work: SavedWorkEntity) {
        viewModelScope.launch { repo.setStarred(work.ao3Id, !work.isStarred) }
    }

    fun remove(work: SavedWorkEntity) {
        viewModelScope.launch { repo.toggleFollow(work.toSummary()) }
    }
}
