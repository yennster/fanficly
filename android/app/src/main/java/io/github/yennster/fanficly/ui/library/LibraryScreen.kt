package io.github.yennster.fanficly.ui.library

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Divider
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.yennster.fanficly.ui.components.WorkRow

@Composable
fun LibraryScreen(
    onOpenWork: (Int) -> Unit,
    viewModel: LibraryViewModel = viewModel(),
) {
    val filter by viewModel.filter.collectAsStateWithLifecycle()
    val all by viewModel.works.collectAsStateWithLifecycle()
    val starred by viewModel.starred.collectAsStateWithLifecycle()
    val downloaded by viewModel.downloaded.collectAsStateWithLifecycle()

    val works = when (filter) {
        LibraryFilter.ALL -> all
        LibraryFilter.STARRED -> starred
        LibraryFilter.DOWNLOADED -> downloaded
    }

    Column(Modifier.fillMaxSize()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            LibraryFilter.entries.forEach { f ->
                FilterChip(
                    selected = filter == f,
                    onClick = { viewModel.setFilter(f) },
                    label = { Text(f.label) },
                )
            }
        }

        if (works.isEmpty()) {
            Box(Modifier.fillMaxSize().padding(32.dp), contentAlignment = Alignment.Center) {
                Text(
                    "Works you save appear here. Tap the bookmark on any search result to add it.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        } else {
            LazyColumn(Modifier.fillMaxSize()) {
                items(works, key = { it.ao3Id }) { entity ->
                    Column {
                        WorkRow(
                            work = entity.toSummary(),
                            isSaved = true,
                            onClick = { onOpenWork(entity.ao3Id) },
                            onToggleSave = { viewModel.remove(entity) },
                        )
                        val progress = entity.lastReadChapter?.let { ch ->
                            if (entity.isComplete && entity.totalChapters != null && ch >= entity.totalChapters) "Finished"
                            else "Reading · ch $ch"
                        }
                        if (progress != null) {
                            Text(
                                progress,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.primary,
                                modifier = Modifier.padding(start = 16.dp, bottom = 8.dp),
                            )
                        }
                        Divider(Modifier.padding(start = 16.dp))
                    }
                }
            }
        }
    }
}
