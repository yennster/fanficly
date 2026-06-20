package io.github.yennster.fanficly.ui.search

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Divider
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.yennster.fanficly.ui.components.WorkRow

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SearchScreen(
    onOpenWork: (Int) -> Unit,
    viewModel: SearchViewModel = viewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val savedIds by viewModel.savedWorkIds.collectAsStateWithLifecycle()
    val listState = rememberLazyListState()

    // Infinite scroll: load the next page when near the end.
    val shouldLoadMore by remember {
        derivedStateOf {
            val last = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            last >= state.works.size - 3 && state.works.isNotEmpty()
        }
    }
    LaunchedEffect(shouldLoadMore) { if (shouldLoadMore) viewModel.loadMore() }

    Column(Modifier.fillMaxSize()) {
        OutlinedTextField(
            value = state.queryText,
            onValueChange = viewModel::onQueryChange,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            placeholder = { Text("Search works, fandoms, ships…") },
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            singleLine = true,
            keyboardActions = androidx.compose.foundation.text.KeyboardActions(onSearch = { viewModel.submit() }),
            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = ImeAction.Search),
        )

        when {
            state.isLoading -> CenteredProgress()
            state.error != null -> CenteredMessage(state.error!!)
            state.works.isEmpty() -> CenteredMessage("Search Archive of Our Own for works to read and save.")
            else -> LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
                items(state.works, key = { it.id }) { work ->
                    WorkRow(
                        work = work,
                        isSaved = work.id in savedIds,
                        onClick = { onOpenWork(work.id) },
                        onToggleSave = { viewModel.toggleSave(work) },
                    )
                    Divider(Modifier.padding(start = 16.dp))
                }
                if (state.isLoadingMore) {
                    item { CenteredProgress(small = true) }
                }
            }
        }
    }
}

@Composable
private fun CenteredProgress(small: Boolean = false) {
    Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(strokeWidth = if (small) 2.dp else 4.dp)
    }
}

@Composable
private fun CenteredMessage(message: String) {
    Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
        Text(message, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
