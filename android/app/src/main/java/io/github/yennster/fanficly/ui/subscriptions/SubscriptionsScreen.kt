package io.github.yennster.fanficly.ui.subscriptions

import android.app.Application
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Subscriptions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.yennster.fanficly.FanficlyApplication
import io.github.yennster.fanficly.model.AO3Subscription
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class SubscriptionsUiState(
    val subscriptions: List<AO3Subscription> = emptyList(),
    val isLoading: Boolean = false,
    val error: String? = null,
    val loggedIn: Boolean = true,
)

/**
 * The logged-in user's AO3 subscriptions (works/series/users) — live-fetched,
 * read-only. The Android port of the iOS `SubscriptionsView`. Work subscriptions
 * open the reader; series/user subscriptions are display-only for v1.
 */
class SubscriptionsViewModel(app: Application) : AndroidViewModel(app) {
    private val client = (app as FanficlyApplication).container.ao3Client
    private val _state = MutableStateFlow(SubscriptionsUiState())
    val state: StateFlow<SubscriptionsUiState> = _state.asStateFlow()
    private var username: String? = null
    private var started = false

    fun start() {
        if (started) return
        started = true
        username = client.currentUsername()
        if (username == null) {
            _state.value = _state.value.copy(loggedIn = false)
            return
        }
        load()
    }

    fun load() {
        val user = username ?: return
        _state.value = _state.value.copy(isLoading = true, error = null, loggedIn = true)
        viewModelScope.launch {
            runCatching { client.fetchSubscriptions(user) }
                .onSuccess { _state.value = _state.value.copy(subscriptions = it, isLoading = false) }
                .onFailure { e -> _state.value = _state.value.copy(isLoading = false, error = e.message ?: "Couldn't load subscriptions") }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SubscriptionsScreen(
    onBack: () -> Unit,
    onOpenWork: (Int) -> Unit,
    viewModel: SubscriptionsViewModel = viewModel(),
) {
    LaunchedEffect(Unit) { viewModel.start() }
    val state by viewModel.state.collectAsStateWithLifecycle()

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Subscriptions") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
                actions = {
                    if (state.loggedIn) {
                        IconButton(onClick = { viewModel.load() }, enabled = !state.isLoading) {
                            Icon(Icons.Filled.Refresh, contentDescription = "Refresh")
                        }
                    }
                },
            )
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                !state.loggedIn -> Centered("Log in to AO3 (Settings) to see your subscriptions.")
                state.isLoading && state.subscriptions.isEmpty() ->
                    Box(Modifier.fillMaxSize(), Alignment.Center) { CircularProgressIndicator() }
                state.error != null && state.subscriptions.isEmpty() -> Centered(state.error!!)
                state.subscriptions.isEmpty() -> Centered("No subscriptions yet.")
                else -> LazyColumn(Modifier.fillMaxSize()) {
                    items(state.subscriptions, key = { it.key }) { sub ->
                        val workId = sub.resourceId.toIntOrNull()?.takeIf { sub.kind == AO3Subscription.Kind.WORK }
                        ListItem(
                            headlineContent = { Text(sub.title) },
                            supportingContent = sub.author?.let { { Text("by $it") } },
                            leadingContent = { Icon(iconFor(sub.kind), contentDescription = null, tint = MaterialTheme.colorScheme.primary) },
                            modifier = if (workId != null) Modifier.clickable { onOpenWork(workId) } else Modifier,
                        )
                        HorizontalDivider(Modifier.padding(start = 16.dp))
                    }
                }
            }
        }
    }
}

private fun iconFor(kind: AO3Subscription.Kind): ImageVector = when (kind) {
    AO3Subscription.Kind.WORK -> Icons.AutoMirrored.Filled.MenuBook
    AO3Subscription.Kind.SERIES -> Icons.Filled.Subscriptions
    AO3Subscription.Kind.USER -> Icons.Filled.Person
}

@Composable
private fun Centered(message: String) {
    Box(Modifier.fillMaxSize().padding(32.dp), Alignment.Center) {
        Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
