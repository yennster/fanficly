package io.github.yennster.fanficly.ui.work

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.yennster.fanficly.FanficlyApplication
import io.github.yennster.fanficly.model.ChapterPayload
import io.github.yennster.fanficly.model.WorkSummary
import io.github.yennster.fanficly.tts.SpeechState
import io.github.yennster.fanficly.ui.reader.HtmlRender
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

    private val speech = container.speechController
    /** Observable "Listen" narrator state for the reader's highlight + bar. */
    val speechState: StateFlow<SpeechState> = speech.state

    private var workId: Int = -1
    // Live reading position, so "Listen" starts from where the reader is.
    private var lastChapter = 0
    private var lastParagraph = 0

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

    /** Persist the live reading position (chapter + topmost paragraph) and feed
     *  the last-read home-screen widget with the work's title/author/progress. */
    fun saveProgress(chapter: Int, paragraph: Int, progress: Float) {
        if (workId < 0) return
        lastChapter = chapter
        lastParagraph = paragraph
        val summary = _state.value.summary
        viewModelScope.launch {
            repo.saveProgress(workId, chapter, paragraph)
            if (summary != null) {
                container.widgetProgressStore.save(
                    id = workId, title = summary.title, author = summary.author,
                    progress = progress, chapter = chapter, paragraph = paragraph,
                )
            }
        }
    }

    // MARK: - Listen (text-to-speech)

    /** Start narrating the whole work from the reader's current position. */
    fun startListening(rate: Float) {
        val chapters = _state.value.chapters
        if (chapters.isEmpty()) return
        val multi = chapters.size > 1
        val paragraphLists = chapters.map { ch ->
            HtmlRender.paragraphs(ch.bodyHtml).map { if (it.text == HtmlRender.SCENE_BREAK) "" else it.text }
        }
        val labels = chapters.map { ch ->
            if (!multi) "" else if (ch.title.isBlank()) "Chapter ${ch.index}" else "Chapter ${ch.index}: ${ch.title}"
        }
        speech.setRate(rate)
        speech.play(paragraphLists, labels, _state.value.summary?.title ?: "", lastChapter, lastParagraph)
    }

    fun toggleListen() = speech.togglePlayPause()
    fun stopListen() = speech.stop()
    fun setListenRate(rate: Float) = speech.setRate(rate)
}
