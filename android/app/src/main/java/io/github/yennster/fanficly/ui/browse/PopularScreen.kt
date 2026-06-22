package io.github.yennster.fanficly.ui.browse

import android.app.Application
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.yennster.fanficly.FanficlyApplication
import io.github.yennster.fanficly.browse.FandomCatalog
import io.github.yennster.fanficly.browse.PopularTags
import io.github.yennster.fanficly.model.PopularKind
import io.github.yennster.fanficly.model.PopularSnapshot
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

data class PopularUiState(
    val segment: PopularKind = PopularKind.FANDOM,
    val snapshot: PopularSnapshot? = null,
)

class PopularViewModel(app: Application) : AndroidViewModel(app) {
    private val container = (app as FanficlyApplication).container
    private val client = container.ao3Client
    private val store = container.popularStore

    private val _state = MutableStateFlow(PopularUiState(snapshot = store.cached()))
    val state: StateFlow<PopularUiState> = _state.asStateFlow()

    init {
        // Refresh in the background (≤ once/day); the cached/curated lists show
        // immediately and swap to live data when the fetch lands.
        viewModelScope.launch {
            store.refreshIfStale(client)?.let { _state.value = _state.value.copy(snapshot = it) }
        }
    }

    fun setSegment(kind: PopularKind) { _state.value = _state.value.copy(segment = kind) }

    /** Live list when present + non-empty, otherwise the curated seed; top 30. */
    fun names(): List<String> {
        val s = _state.value.snapshot
        val (live, fallback) = when (_state.value.segment) {
            PopularKind.FANDOM -> s?.fandoms to PopularTags.fandoms
            PopularKind.SHIP -> s?.ships to PopularTags.ships
            PopularKind.CHARACTER -> s?.characters to PopularTags.characters
        }
        return (if (!live.isNullOrEmpty()) live else fallback).take(30)
    }
}

/**
 * The Popular tab: popular fandoms, ships, and characters (live-ranked from
 * AO3's work counts, cached ~daily, with the curated seed as fallback). Tap a
 * tag to see its works sorted by kudos. Port of the iOS `PopularView`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PopularScreen(
    onOpenTag: (PopularKind, String) -> Unit,
    viewModel: PopularViewModel = viewModel(),
) {
    val state by viewModel.state.collectAsStateWithLifecycle()
    val names = viewModel.names()

    Column(Modifier.fillMaxSize()) {
        SingleChoiceSegmentedButtonRow(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
        ) {
            PopularKind.entries.forEachIndexed { index, kind ->
                SegmentedButton(
                    selected = state.segment == kind,
                    onClick = { viewModel.setSegment(kind) },
                    shape = SegmentedButtonDefaults.itemShape(index, PopularKind.entries.size),
                ) { Text(segmentTitle(kind)) }
            }
        }

        LazyColumn(Modifier.fillMaxSize()) {
            items(names, key = { it }) { name ->
                ListItem(
                    headlineContent = { Text(displayName(state.segment, name)) },
                    leadingContent = {
                        Icon(
                            iconFor(state.segment, name),
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.primary,
                        )
                    },
                    modifier = Modifier.clickable { onOpenTag(state.segment, name) },
                )
                HorizontalDivider(Modifier.padding(start = 16.dp))
            }
        }
    }
}

private fun segmentTitle(kind: PopularKind) = when (kind) {
    PopularKind.FANDOM -> "Fandoms"
    PopularKind.SHIP -> "Ships"
    PopularKind.CHARACTER -> "Characters"
}

private fun iconFor(segment: PopularKind, name: String) = when (segment) {
    PopularKind.FANDOM -> fandomIconVector(FandomCatalog.iconFor(name))
    PopularKind.SHIP -> popularShipIcon
    PopularKind.CHARACTER -> popularCharacterIcon
}

/** Trim AO3's canonical disambiguation noise for display only (fandoms). */
private fun displayName(segment: PopularKind, name: String): String =
    if (segment == PopularKind.FANDOM) name.substringBefore(" - ") else name
