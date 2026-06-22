package io.github.yennster.fanficly.ui.comments

import android.app.Application
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.yennster.fanficly.FanficlyApplication
import io.github.yennster.fanficly.model.AO3Comment
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.jsoup.Jsoup

data class CommentsUiState(
    val comments: List<AO3Comment> = emptyList(),
    val isLoading: Boolean = false,
    val error: String? = null,
    val isLoggedIn: Boolean = false,
    val draft: String = "",
    val isPosting: Boolean = false,
    val postError: String? = null,
)

/**
 * Reads a work's comment thread and, when logged in, lets you post a comment.
 * The Android counterpart of the iOS `CommentsView`. v1 is work-level (the work
 * page's first thread); per-chapter association is a follow-up. Posting reuses
 * the scraped-form CSRF flow; AO3 may hold new comments for moderation, so it
 * re-fetches after posting.
 */
class CommentsViewModel(app: Application) : AndroidViewModel(app) {
    private val client = (app as FanficlyApplication).container.ao3Client
    private val _state = MutableStateFlow(CommentsUiState())
    val state: StateFlow<CommentsUiState> = _state.asStateFlow()
    private var workId: Int = 0
    private var started = false

    fun start(workId: Int) {
        if (started) return
        started = true
        this.workId = workId
        _state.value = _state.value.copy(isLoggedIn = client.isLoggedIn())
        load()
    }

    fun load() {
        _state.value = _state.value.copy(isLoading = true, error = null)
        viewModelScope.launch {
            runCatching { client.fetchComments(workId, null) }
                .onSuccess { _state.value = _state.value.copy(comments = it, isLoading = false) }
                .onFailure { e -> _state.value = _state.value.copy(isLoading = false, error = e.message ?: "Couldn't load comments") }
        }
    }

    fun onDraftChange(text: String) { _state.value = _state.value.copy(draft = text) }

    fun post() {
        val text = _state.value.draft.trim()
        if (text.isEmpty() || _state.value.isPosting) return
        _state.value = _state.value.copy(isPosting = true, postError = null)
        viewModelScope.launch {
            runCatching { client.postComment(workId, null, text) }
                .onSuccess {
                    _state.value = _state.value.copy(draft = "", isPosting = false)
                    load() // re-fetch; AO3 may hold the comment for moderation
                }
                .onFailure { e ->
                    _state.value = _state.value.copy(
                        isPosting = false,
                        postError = "Couldn't post: ${e.message}. It may be awaiting moderation, or try again.",
                    )
                }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CommentsScreen(
    workId: Int,
    onBack: () -> Unit,
    viewModel: CommentsViewModel = viewModel(),
) {
    LaunchedEffect(workId) { viewModel.start(workId) }
    val state by viewModel.state.collectAsStateWithLifecycle()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Comments") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    IconButton(onClick = { viewModel.load() }, enabled = !state.isLoading) {
                        Icon(Icons.Filled.Refresh, contentDescription = "Refresh")
                    }
                },
            )
        },
        bottomBar = { Composer(state, viewModel) },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                state.isLoading && state.comments.isEmpty() ->
                    Box(Modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator() }
                state.error != null && state.comments.isEmpty() ->
                    Centered(state.error!!)
                state.comments.isEmpty() ->
                    Centered(if (state.isLoggedIn) "No comments yet. Be the first to comment." else "No comments yet. Log in to AO3 (Settings) to post.")
                else -> LazyColumn(Modifier.fillMaxSize()) {
                    items(state.comments, key = { it.id }) { comment ->
                        CommentRow(comment)
                        HorizontalDivider(Modifier.padding(start = 16.dp))
                    }
                }
            }
        }
    }
}

@Composable
private fun Composer(state: CommentsUiState, viewModel: CommentsViewModel) {
    Surface(tonalElevation = 3.dp) {
        Column(Modifier.fillMaxWidth().imePadding()) {
            HorizontalDivider()
            if (!state.isLoggedIn) {
                Text(
                    "Log in to AO3 (Settings) to post a comment.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(16.dp),
                )
            } else {
                state.postError?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
                }
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.Bottom,
                ) {
                    OutlinedTextField(
                        value = state.draft,
                        onValueChange = viewModel::onDraftChange,
                        modifier = Modifier.weight(1f),
                        placeholder = { Text("Add a comment…") },
                        enabled = !state.isPosting,
                        maxLines = 5,
                    )
                    IconButton(
                        onClick = { viewModel.post() },
                        enabled = !state.isPosting && state.draft.isNotBlank(),
                    ) {
                        if (state.isPosting) CircularProgressIndicator(Modifier.padding(4.dp), strokeWidth = 2.dp)
                        else Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "Post comment")
                    }
                }
            }
        }
    }
}

@Composable
private fun CommentRow(comment: AO3Comment) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(start = (16 + minOf(comment.depth, 6) * 16).dp, end = 16.dp, top = 10.dp, bottom = 10.dp),
    ) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(comment.commenterName, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            if (comment.dateText.isNotEmpty()) {
                Text(comment.dateText, style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Text(
            commentPlainText(comment.bodyHtml),
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.padding(top = 4.dp),
        )
    }
}

@Composable
private fun Centered(message: String) {
    Box(Modifier.fillMaxSize().padding(32.dp), Alignment.Center) {
        Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Flattens a comment's HTML body to readable plain text (paragraph-aware). */
private fun commentPlainText(html: String): String {
    val doc = Jsoup.parse(html)
    val ps = doc.select("p")
    return if (ps.isNotEmpty()) ps.joinToString("\n\n") { it.text() } else doc.text()
}
