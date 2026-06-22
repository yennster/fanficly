package io.github.yennster.fanficly.tts

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Immutable snapshot of the "Listen" narrator — the Android counterpart of the
 * observable state on the iOS `SpeechController`. [currentParagraph] is the
 * *rendered* paragraph index within [chapterIndex] (scene breaks are unspoken
 * slots) so the reader can karaoke-highlight it.
 */
data class SpeechState(
    val isActive: Boolean = false,
    val isPlaying: Boolean = false,
    val chapterIndex: Int = 0,
    val currentParagraph: Int = 0,
    val spokenPosition: Int = 0,
    val spokenCount: Int = 0,
    val workTitle: String = "",
    val chapterLabel: String = "",
)

/**
 * On-device text-to-speech narrator — the Android port of the iOS
 * `SpeechController`. Wraps the framework [TextToSpeech] (the device's local
 * engine, so no network and the privacy posture holds). It's given the *whole*
 * work up front and advances chapter-to-chapter itself, so narration (and
 * auto-advance) keeps going in the background via the foreground [SpeechService]
 * even after the reader screen is gone. Held as a singleton in `AppContainer`.
 *
 * TextToSpeech has no real pause, so "pause" stops the queue and "resume"
 * re-speaks from the current paragraph — same approach as iOS.
 */
class SpeechController(context: Context) {
    private val appContext = context.applicationContext

    private val _state = MutableStateFlow(SpeechState())
    val state: StateFlow<SpeechState> = _state.asStateFlow()

    private var tts: TextToSpeech? = null
    private var ready = false
    private var pending: (() -> Unit)? = null

    // The whole work: per-chapter rendered paragraphs ("" = unspeakable slot:
    // scene break / blank), index-aligned with the reader's rows.
    private var chapters: List<List<String>> = emptyList()
    private var labels: List<String> = emptyList()
    private var workTitle = ""

    // Current chapter's working set.
    private var paragraphs: List<String> = emptyList()
    private var speakable: List<Int> = emptyList()
    private var rateMultiplier = 1.0f

    private fun ensureEngine(then: () -> Unit) {
        if (ready) { then(); return }
        pending = then
        if (tts == null) {
            tts = TextToSpeech(appContext) { status ->
                if (status == TextToSpeech.SUCCESS) {
                    ready = true
                    tts?.setOnUtteranceProgressListener(listener)
                    tts?.setSpeechRate(rateMultiplier)
                    pending?.invoke()
                    pending = null
                }
            }
        }
    }

    private val listener = object : UtteranceProgressListener() {
        override fun onStart(utteranceId: String?) {
            val idx = utteranceId?.toIntOrNull() ?: return
            _state.value = _state.value.copy(
                isPlaying = true,
                currentParagraph = idx,
                spokenPosition = speakable.indexOf(idx) + 1,
            )
        }

        override fun onDone(utteranceId: String?) {
            val idx = utteranceId?.toIntOrNull() ?: return
            if (idx == speakable.lastOrNull()) advanceChapter(_state.value.chapterIndex)
        }

        @Deprecated("Deprecated in Java")
        override fun onError(utteranceId: String?) {}
    }

    /**
     * Begin narrating the whole work from [startChapter]/[startParagraph].
     * [chapters] is per-chapter rendered paragraphs (scene-break/blank kept as
     * empty strings so indices align with the reader's rows).
     */
    fun play(
        chapters: List<List<String>>,
        labels: List<String>,
        workTitle: String,
        startChapter: Int,
        startParagraph: Int,
    ) {
        this.chapters = chapters
        this.labels = labels
        this.workTitle = workTitle
        if (chapters.isEmpty()) return
        ContextCompat.startForegroundService(appContext, Intent(appContext, SpeechService::class.java))
        ensureEngine { startChapter(startChapter.coerceIn(0, chapters.size - 1), startParagraph) }
    }

    private fun startChapter(ci: Int, fromParagraph: Int) {
        if (ci !in chapters.indices) { stop(); return }
        paragraphs = chapters[ci]
        speakable = paragraphs.indices.filter { paragraphs[it].isNotBlank() }
        if (speakable.isEmpty()) { advanceChapter(ci); return }  // skip empty chapter
        val start = speakable.firstOrNull { it >= fromParagraph } ?: speakable.first()
        _state.value = _state.value.copy(
            isActive = true, isPlaying = true,
            chapterIndex = ci, currentParagraph = start,
            spokenPosition = speakable.indexOf(start) + 1, spokenCount = speakable.size,
            workTitle = workTitle, chapterLabel = labels.getOrElse(ci) { "" },
        )
        enqueue(start)
    }

    private fun advanceChapter(fromCi: Int) {
        if (fromCi + 1 < chapters.size) startChapter(fromCi + 1, 0) else stop()
    }

    private fun enqueue(fromRenderedIndex: Int) {
        val engine = tts ?: return
        speakable.filter { it >= fromRenderedIndex }.forEachIndexed { i, idx ->
            val mode = if (i == 0) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD
            engine.speak(paragraphs[idx], mode, Bundle(), idx.toString())
        }
    }

    fun togglePlayPause() {
        if (_state.value.isPlaying) pause() else resume()
    }

    fun pause() {
        tts?.stop()
        _state.value = _state.value.copy(isPlaying = false)
    }

    fun resume() {
        if (!_state.value.isActive) return
        _state.value = _state.value.copy(isPlaying = true)
        ensureEngine { enqueue(_state.value.currentParagraph) }
    }

    fun stop() {
        tts?.stop()
        // The foreground service observes isActive and stops itself.
        _state.value = _state.value.copy(isActive = false, isPlaying = false)
    }

    fun setRate(multiplier: Float) {
        rateMultiplier = multiplier.coerceIn(0.5f, 2.5f)
        tts?.setSpeechRate(rateMultiplier)
        if (_state.value.isActive && _state.value.isPlaying) {
            ensureEngine { enqueue(_state.value.currentParagraph) }
        }
    }
}
