package io.github.yennster.fanficly.ui.work

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Comment
import androidx.compose.material.icons.filled.Headphones
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material.icons.outlined.Bookmark
import androidx.compose.material.icons.outlined.BookmarkAdd
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.yennster.fanficly.data.ReaderSettings
import io.github.yennster.fanficly.model.ChapterPayload
import io.github.yennster.fanficly.tts.SpeechState
import io.github.yennster.fanficly.ui.reader.HtmlRender
import io.github.yennster.fanficly.ui.reader.ReaderTheme
import io.github.yennster.fanficly.ui.reader.ReadingMode
import io.github.yennster.fanficly.ui.settings.SettingsViewModel
import androidx.compose.ui.text.font.FontFamily

/**
 * Work detail + continuous reader — the Android counterpart of the iOS
 * `WorkDetailView` + `ReaderView` (continuous mode). Renders metadata then each
 * chapter's paragraphs, applies the saved reader typography/theme, and saves the
 * topmost-visible paragraph as the reading position (mirroring iOS
 * `ScrollAnchorKey` + `ReadingProgressStore`).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WorkScreen(
    workId: Int,
    onBack: () -> Unit,
    onShowSettings: () -> Unit,
    onShowComments: (Int) -> Unit = {},
    onOpenAuthor: (username: String, displayName: String) -> Unit = { _, _ -> },
    viewModel: WorkViewModel = viewModel(),
    settingsViewModel: SettingsViewModel = viewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val settings by settingsViewModel.settings.collectAsStateWithLifecycle()
    val speech by viewModel.speechState.collectAsStateWithLifecycle()

    LaunchedEffect(workId) { viewModel.load(workId) }
    // Keep the live narrator in sync with the speed setting.
    LaunchedEffect(settings.ttsRate) { viewModel.setListenRate(settings.ttsRate) }

    val theme = settings.theme
    val systemDark = androidx.compose.foundation.isSystemInDarkTheme()
    val bg = theme.background(if (systemDark) Color(0xFF141416) else Color(0xFFFFFBFB))
    val fg = theme.foreground(if (systemDark) Color(0xFFEDEDED) else Color(0xFF14141A))
    val fontFamily = settings.fontFamily.toFontFamily()

    Scaffold(
        containerColor = bg,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        state.summary?.title ?: "Loading…",
                        maxLines = 1,
                        style = MaterialTheme.typography.titleMedium,
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = {
                        if (speech.isActive) viewModel.stopListen() else viewModel.startListening(settings.ttsRate)
                    }) {
                        Icon(
                            Icons.Filled.Headphones,
                            contentDescription = if (speech.isActive) "Stop listening" else "Listen",
                            tint = if (speech.isActive) MaterialTheme.colorScheme.primary else fg,
                        )
                    }
                    IconButton(onClick = { onShowComments(workId) }) {
                        Icon(Icons.AutoMirrored.Outlined.Comment, contentDescription = "Comments")
                    }
                    IconButton(onClick = onShowSettings) {
                        Icon(Icons.Filled.TextFields, contentDescription = "Reader settings")
                    }
                    IconButton(onClick = { viewModel.toggleSave() }) {
                        Icon(
                            if (state.isSaved) Icons.Outlined.Bookmark else Icons.Outlined.BookmarkAdd,
                            contentDescription = if (state.isSaved) "Saved" else "Save",
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = bg, titleContentColor = fg),
            )
        },
        bottomBar = {
            if (speech.isActive) {
                ListenBar(
                    speech = speech,
                    bg = bg,
                    fg = fg,
                    onToggle = { viewModel.toggleListen() },
                    onStop = { viewModel.stopListen() },
                )
            }
        },
    ) { padding ->
        when {
            state.isLoading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
            state.error != null -> Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
                Text(state.error!!, color = fg)
            }
            else -> {
                val contentModifier = Modifier.fillMaxSize().padding(padding).background(bg)
                // Highlight the spoken paragraph only in continuous mode.
                val highlightChapter = if (speech.isActive) speech.chapterIndex else null
                val highlightParagraph = if (speech.isActive) speech.currentParagraph else null
                when (settings.mode) {
                    ReadingMode.CONTINUOUS -> ContinuousReader(
                        state, settings, fg, fontFamily, contentModifier, viewModel,
                        highlightChapter, highlightParagraph, onOpenAuthor,
                    )
                    ReadingMode.PAGINATED -> PaginatedReader(state, settings, fg, fontFamily, contentModifier, viewModel)
                }
            }
        }
    }
}

/** Bottom "Listen" control bar: play/pause, stop, chapter + paragraph readout. */
@Composable
private fun ListenBar(
    speech: SpeechState,
    bg: Color,
    fg: Color,
    onToggle: () -> Unit,
    onStop: () -> Unit,
) {
    androidx.compose.material3.Surface(color = bg, contentColor = fg, tonalElevation = 3.dp) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onToggle) {
                Icon(
                    if (speech.isPlaying) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    contentDescription = if (speech.isPlaying) "Pause" else "Play",
                    tint = MaterialTheme.colorScheme.primary,
                )
            }
            Column(Modifier.weight(1f)) {
                Text(
                    speech.chapterLabel.ifEmpty { speech.workTitle.ifEmpty { "Listening" } },
                    style = MaterialTheme.typography.bodyMedium,
                    maxLines = 1,
                    color = fg,
                )
                if (speech.spokenCount > 0) {
                    Text(
                        "¶ ${speech.spokenPosition} / ${speech.spokenCount}",
                        style = MaterialTheme.typography.labelSmall,
                        color = fg.copy(alpha = 0.6f),
                    )
                }
            }
            IconButton(onClick = onStop) {
                Icon(Icons.Filled.Stop, contentDescription = "Stop", tint = fg)
            }
        }
    }
}

/** Continuous scroll: the whole work flattened into one LazyColumn. */
@Composable
private fun ContinuousReader(
    state: WorkUiState,
    settings: ReaderSettings,
    fg: Color,
    fontFamily: FontFamily,
    modifier: Modifier,
    viewModel: WorkViewModel,
    highlightChapter: Int? = null,
    highlightParagraph: Int? = null,
    onOpenAuthor: (username: String, displayName: String) -> Unit = { _, _ -> },
) {
    val rows = remember(state.chapters) { flattenChapters(state.chapters) }
    val listState = rememberLazyListState()
    // The summary/metadata header is item 0 when present, so a LazyColumn index
    // maps to rows[index - headerOffset] and vice versa.
    val headerOffset = if (state.summary != null) 1 else 0

    LaunchedEffect(rows, state.startChapter) {
        if (rows.isNotEmpty()) {
            val target = rows.indexOfFirst {
                it is Row.Paragraph && it.chapterIndex == state.startChapter && it.paragraphIndex == state.startParagraph
            }
            if (target >= 0) listState.scrollToItem(target + headerOffset)
        }
    }
    LaunchedEffect(rows) {
        snapshotFlow { listState.firstVisibleItemIndex }.collect { idx ->
            val rowIdx = idx - headerOffset
            (rows.getOrNull(rowIdx) as? Row.Paragraph)?.let {
                val fraction = if (rows.size > 1) (rowIdx.toFloat() / (rows.size - 1)).coerceIn(0f, 1f) else 0f
                viewModel.saveProgress(it.chapterIndex, it.paragraphIndex, fraction)
            }
        }
    }
    // Karaoke: scroll the spoken paragraph into view as narration moves.
    LaunchedEffect(highlightChapter, highlightParagraph) {
        if (highlightChapter != null && highlightParagraph != null) {
            val target = rows.indexOfFirst {
                it is Row.Paragraph && it.chapterIndex == highlightChapter && it.paragraphIndex == highlightParagraph
            }
            if (target >= 0) listState.animateScrollToItem((target + headerOffset).coerceAtLeast(0))
        }
    }

    LazyColumn(state = listState, modifier = modifier) {
        state.summary?.let { summary -> item { SummaryHeader(summary, fg, onOpenAuthor) } }
        itemsIndexed(rows) { _, row ->
            val highlighted = row is Row.Paragraph &&
                row.chapterIndex == highlightChapter && row.paragraphIndex == highlightParagraph
            ReaderRow(row, settings, fg, fontFamily, highlighted)
        }
    }
}

/** Swipe-by-chapter pagination: one horizontally-paged chapter at a time, each
 *  vertically scrollable. The Android port of the iOS "Swipe by chapter" mode. */
@Composable
private fun PaginatedReader(
    state: WorkUiState,
    settings: ReaderSettings,
    fg: Color,
    fontFamily: FontFamily,
    modifier: Modifier,
    viewModel: WorkViewModel,
) {
    val pages = remember(state.chapters) { chapterPages(state.chapters) }
    if (pages.isEmpty()) return
    val startPage = state.startChapter.coerceIn(0, pages.size - 1)
    val pagerState = rememberPagerState(initialPage = startPage) { pages.size }

    HorizontalPager(state = pagerState, modifier = modifier) { page ->
        val pageRows = pages[page]
        val headerOffset = if (pageRows.firstOrNull() is Row.ChapterHeader) 1 else 0
        val paragraphCount = remember(pageRows) { pageRows.count { it is Row.Paragraph } }
        val initialIndex = if (page == startPage) {
            (state.startParagraph + headerOffset).coerceIn(0, (pageRows.size - 1).coerceAtLeast(0))
        } else 0
        val listState = rememberLazyListState(initialFirstVisibleItemIndex = initialIndex)

        // Save chapter + within-chapter paragraph + widget fraction for the
        // currently-shown page only (re-fires on swipe as currentPage changes).
        LaunchedEffect(page, pagerState.currentPage) {
            if (page == pagerState.currentPage) {
                snapshotFlow { listState.firstVisibleItemIndex }.collect { idx ->
                    val paragraph = (pageRows.getOrNull(idx) as? Row.Paragraph)?.paragraphIndex ?: 0
                    // Blend within-chapter scroll into the fraction and divide by
                    // chapter count (matching iOS readingProgressFraction), so a
                    // one-shot still advances 0→1 and the last chapter isn't
                    // reported "finished" the instant it's reached.
                    val paraProgress = if (paragraphCount > 1) (paragraph.toFloat() / (paragraphCount - 1)).coerceIn(0f, 1f) else 0f
                    val fraction = ((page + paraProgress) / pages.size).coerceIn(0f, 1f)
                    viewModel.saveProgress(page, paragraph, fraction)
                }
            }
        }

        LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
            items(pageRows) { row -> ReaderRow(row, settings, fg, fontFamily) }
        }
    }
}

@Composable
private fun SummaryHeader(
    summary: io.github.yennster.fanficly.model.WorkSummary,
    fg: Color,
    onOpenAuthor: (username: String, displayName: String) -> Unit = { _, _ -> },
) {
    Column(Modifier.fillMaxWidth().padding(20.dp)) {
        Text(summary.title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, color = fg)
        // Tappable byline → "more by this author" (only when the AO3 login is known).
        val bylineModifier = if (summary.authorUsername.isNotEmpty()) {
            Modifier.clickable { onOpenAuthor(summary.authorUsername, summary.author) }
        } else Modifier
        Text(
            "by ${summary.author}",
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.primary,
            modifier = bylineModifier,
        )
        if (summary.fandoms.isNotEmpty()) {
            Text(summary.fandoms.joinToString(", "), style = MaterialTheme.typography.bodySmall, color = fg.copy(alpha = 0.7f), modifier = Modifier.padding(top = 6.dp))
        }
        if (summary.summary.isNotBlank()) {
            Text(
                HtmlRender.paragraphs(summary.summary).joinToString("\n") { it.text },
                style = MaterialTheme.typography.bodyMedium,
                color = fg.copy(alpha = 0.85f),
                modifier = Modifier.padding(top = 12.dp),
            )
        }
    }
}

@Composable
private fun ReaderRow(
    row: Row,
    settings: ReaderSettings,
    fg: Color,
    fontFamily: FontFamily,
    highlighted: Boolean = false,
) {
    when (row) {
        is Row.ChapterHeader -> Text(
            text = row.label,
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.Bold,
            color = fg,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 16.dp),
        )
        is Row.Paragraph -> {
            if (row.text == HtmlRender.SCENE_BREAK) {
                Text(
                    HtmlRender.SCENE_BREAK,
                    color = fg.copy(alpha = 0.6f),
                    textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(vertical = settings.paragraphSpacing.dp),
                )
            } else {
                val highlightModifier = if (highlighted) {
                    Modifier.background(
                        MaterialTheme.colorScheme.primary.copy(alpha = 0.14f),
                        RoundedCornerShape(6.dp),
                    )
                } else Modifier
                Text(
                    text = row.annotated,
                    color = fg,
                    fontFamily = fontFamily,
                    fontSize = settings.fontSize.sp,
                    lineHeight = (settings.fontSize + settings.lineSpacing).sp,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp)
                        .then(highlightModifier)
                        .padding(horizontal = 8.dp)
                        .padding(bottom = settings.paragraphSpacing.dp),
                )
            }
        }
    }
}

private sealed interface Row {
    data class ChapterHeader(val label: String) : Row
    data class Paragraph(
        val chapterIndex: Int,
        val paragraphIndex: Int,
        val text: String,
        val annotated: androidx.compose.ui.text.AnnotatedString,
    ) : Row
}

private fun flattenChapters(chapters: List<ChapterPayload>): List<Row> {
    val rows = mutableListOf<Row>()
    val multi = chapters.size > 1
    chapters.forEachIndexed { ci, chapter ->
        if (multi) {
            val label = if (chapter.title.isBlank()) "Chapter ${chapter.index}" else "Chapter ${chapter.index}: ${chapter.title}"
            rows += Row.ChapterHeader(label)
        }
        HtmlRender.paragraphs(chapter.bodyHtml).forEachIndexed { pi, para ->
            rows += Row.Paragraph(ci, pi, para.text, para)
        }
    }
    return rows
}

/** Per-chapter row lists for paginated mode (one inner list = one swipe page).
 *  chapterIndex stays the 0-based loop index `ci`, matching [flattenChapters],
 *  so saved positions map across both modes. */
private fun chapterPages(chapters: List<ChapterPayload>): List<List<Row>> {
    val multi = chapters.size > 1
    return chapters.mapIndexed { ci, chapter ->
        val rows = mutableListOf<Row>()
        if (multi) {
            val label = if (chapter.title.isBlank()) "Chapter ${chapter.index}" else "Chapter ${chapter.index}: ${chapter.title}"
            rows += Row.ChapterHeader(label)
        }
        HtmlRender.paragraphs(chapter.bodyHtml).forEachIndexed { pi, para ->
            rows += Row.Paragraph(ci, pi, para.text, para)
        }
        rows
    }
}
