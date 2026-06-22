package io.github.yennster.fanficly.ui.work

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.Comment
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
import io.github.yennster.fanficly.model.ChapterPayload
import io.github.yennster.fanficly.ui.reader.HtmlRender
import io.github.yennster.fanficly.ui.reader.ReaderTheme
import io.github.yennster.fanficly.ui.settings.SettingsViewModel

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
    viewModel: WorkViewModel = viewModel(),
    settingsViewModel: SettingsViewModel = viewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val settings by settingsViewModel.settings.collectAsStateWithLifecycle()

    LaunchedEffect(workId) { viewModel.load(workId) }

    // Flatten chapters into (chapterIndex, paragraph) rows so a single LazyColumn
    // scrolls the whole work and we can map a list index back to a position.
    val rows = remember(state.chapters) { flattenChapters(state.chapters) }
    val listState = rememberLazyListState()

    // Restore saved position once the rows are available.
    LaunchedEffect(rows, state.startChapter) {
        if (rows.isNotEmpty()) {
            val target = rows.indexOfFirst {
                it is Row.Paragraph && it.chapterIndex == state.startChapter && it.paragraphIndex == state.startParagraph
            }
            if (target > 0) listState.scrollToItem(target)
        }
    }

    // Persist the topmost visible paragraph as reading progress (snapshotFlow
    // emits only on index change). The fraction (row / last row) drives the
    // last-read widget's progress bar.
    LaunchedEffect(rows) {
        snapshotFlow { listState.firstVisibleItemIndex }
            .collect { idx ->
                (rows.getOrNull(idx) as? Row.Paragraph)?.let {
                    val fraction = if (rows.size > 1) idx.toFloat() / (rows.size - 1) else 0f
                    viewModel.saveProgress(it.chapterIndex, it.paragraphIndex, fraction)
                }
            }
    }

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
    ) { padding ->
        when {
            state.isLoading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
            state.error != null -> Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
                Text(state.error!!, color = fg)
            }
            else -> LazyColumn(
                state = listState,
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .background(bg),
            ) {
                state.summary?.let { summary ->
                    item {
                        Column(Modifier.fillMaxWidth().padding(20.dp)) {
                            Text(summary.title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, color = fg)
                            Text("by ${summary.author}", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
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
                }

                itemsIndexed(rows) { _, row ->
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
                                Text(
                                    text = row.annotated,
                                    color = fg,
                                    fontFamily = fontFamily,
                                    fontSize = settings.fontSize.sp,
                                    lineHeight = (settings.fontSize + settings.lineSpacing).sp,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(horizontal = 24.dp)
                                        .padding(bottom = settings.paragraphSpacing.dp),
                                )
                            }
                        }
                    }
                }
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
