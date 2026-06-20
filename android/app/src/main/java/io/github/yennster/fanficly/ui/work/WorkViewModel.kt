package io.github.yennster.fanficly.ui.work

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.yennster.fanficly.FanficlyApplication
import io.github.yennster.fanficly.model.ChapterPayload
import io.github.yennster.fanficly.model.WorkSummary
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class WorkUiState(
    val isLoading: Boolean = true,
    val summary: WorkSummary? = null,
    val chapters: List<ChapterPayload> = emptyList(),
    val error: String? = null,
    val isSaved: Boolean = false,
    val startChapter: Int = 0,
    val startParagraph: Int = 0,
)

class WorkViewModel(app: Application) : AndroidViewModel(app) {
    private val container = (app as FanficlyApplication).container
    private val client = container.ao3Client
    private val repo = container.libraryRepository

    private val _state = MutableStateFlow(WorkUiState())
    val state: StateFlow<WorkUiState> = _state.asStateFlow()

    private var workId: Int = -1

    fun load(id: Int) {
        if (workId == id && _state.value.summary != null) return
        workId = id
        _state.value = WorkUiState(isLoading = true)
        viewModelScope.launch {
            val saved = repo.isSaved(id)
            val progress = repo.loadProgress(id)
            runCatching { client.fetchWork(id) }
                .onSuccess { payload ->
                    _state.value = WorkUiState(
                        isLoading = false,
                        summary = payload.summary,
                        chapters = payload.chapters,
                        isSaved = saved,
                        startChapter = progress?.chapterIndex ?: 0,
                        startParagraph = progress?.paragraphIndex ?: 0,
                    )
                }
                .onFailure { e ->
                    _state.value = WorkUiState(isLoading = false, error = e.message ?: "Couldn't load work")
                }
        }
    }

    fun toggleSave() {
        val summary = _state.value.summary ?: return
        viewModelScope.launch {
            val saved = repo.toggleFollow(summary)
            _state.value = _state.value.copy(isSaved = saved)
        }
    }

    /** Persist the live reading position (chapter + topmost paragraph). */
    fun saveProgress(chapter: Int, paragraph: Int) {
        if (workId < 0) return
        viewModelScope.launch { repo.saveProgress(workId, chapter, paragraph) }
    }
}
