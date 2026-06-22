package io.github.yennster.fanficly.ui.browse

import android.app.Application
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.yennster.fanficly.FanficlyApplication
import io.github.yennster.fanficly.browse.FandomCatalog
import io.github.yennster.fanficly.model.AO3Exception
import io.github.yennster.fanficly.model.BrowseFandom
import io.github.yennster.fanficly.model.FandomCategory
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class CategoryFandomsUiState(
    val category: FandomCategory? = null,
    val live: List<BrowseFandom> = emptyList(),
    val isLoading: Boolean = false,
    val error: String? = null,
    val query: String = "",
)

class CategoryFandomsViewModel(app: Application) : AndroidViewModel(app) {
    private val client = (app as FanficlyApplication).container.ao3Client
    private val _state = MutableStateFlow(CategoryFandomsUiState())
    val state: StateFlow<CategoryFandomsUiState> = _state.asStateFlow()

    /**
     * Guard on the loaded data (not a one-shot flag), mirroring iOS's
     * `guard liveFandoms.isEmpty else { return }`: a successful load won't
     * re-fetch on re-entry, but a transient failure (live still empty) retries
     * the next time the screen reappears. `isLoading` blocks concurrent fetches.
     */
    fun start(categoryId: String) {
        val s = _state.value
        if (s.live.isNotEmpty() || s.isLoading) return
        val category = FandomCatalog.all.firstOrNull { it.id == categoryId }
        if (category == null) {
            _state.value = s.copy(isLoading = false, error = "Unknown category.")
            return
        }
        _state.value = s.copy(category = category, isLoading = true, error = null)
        viewModelScope.launch {
            runCatching { client.fetchFandomsInCategory(category.ao3CanonicalName) }
                .onSuccess { _state.value = _state.value.copy(live = it, isLoading = false) }
                .onFailure { e ->
                    val msg = if (e is AO3Exception.Http && e.status == 404) {
                        "AO3 didn't recognise that category. Showing popular fandoms only."
                    } else {
                        "Couldn't load full list. Showing popular fandoms only."
                    }
                    _state.value = _state.value.copy(isLoading = false, error = msg)
                }
        }
    }

    fun onQueryChange(text: String) { _state.value = _state.value.copy(query = text) }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CategoryFandomsScreen(
    categoryId: String,
    onBack: () -> Unit,
    onOpenFandom: (canonical: String, display: String) -> Unit,
    viewModel: CategoryFandomsViewModel = viewModel(),
) {
    LaunchedEffect(categoryId) { viewModel.start(categoryId) }
    val state by viewModel.state.collectAsStateWithLifecycle()

    // Source: live data once loaded, else the curated seed only after a failure.
    val source = when {
        state.live.isNotEmpty() -> state.live
        state.error != null -> state.category?.fandoms ?: emptyList()
        else -> emptyList()
    }
    val q = state.query.trim()
    val displayed = if (q.isEmpty()) source else source.filter { it.displayName.contains(q, ignoreCase = true) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(state.category?.name ?: "Browse", maxLines = 1) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            OutlinedTextField(
                value = state.query,
                onValueChange = viewModel::onQueryChange,
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                placeholder = { Text("Search fandoms") },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                singleLine = true,
            )
            when {
                source.isEmpty() && state.isLoading -> Box(Modifier.fillMaxSize(), Alignment.Center) {
                    CircularProgressIndicator()
                }
                else -> LazyColumn(Modifier.fillMaxSize()) {
                    state.error?.let { err ->
                        item {
                            Text(
                                err,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.error,
                                modifier = Modifier.padding(16.dp),
                            )
                        }
                    }
                    items(displayed, key = { it.canonicalName }) { fandom ->
                        ListItem(
                            headlineContent = { Text(fandom.displayName) },
                            modifier = Modifier.clickable { onOpenFandom(fandom.canonicalName, fandom.displayName) },
                        )
                        HorizontalDivider(Modifier.padding(start = 16.dp))
                    }
                }
            }
        }
    }
}
