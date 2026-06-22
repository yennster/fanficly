package io.github.yennster.fanficly.ui.search

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.InputChip
import androidx.compose.material3.InputChipDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.yennster.fanficly.model.AO3SearchFilters
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
    var showHelp by remember { mutableStateOf(false) }

    // Infinite scroll: load the next page when near the end.
    val shouldLoadMore by remember {
        derivedStateOf {
            val last = listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            last >= state.works.size - 3 && state.works.isNotEmpty()
        }
    }
    LaunchedEffect(shouldLoadMore) { if (shouldLoadMore) viewModel.loadMore() }

    Column(Modifier.fillMaxSize()) {
        SearchHeader(
            state = state,
            onQueryChange = viewModel::onQueryChange,
            onSubmit = viewModel::submit,
            onSetSort = viewModel::setSortColumn,
            onToggleDirection = viewModel::toggleSortDirection,
            onRemoveChip = viewModel::removeChip,
            onShowHelp = { showHelp = true },
        )

        when {
            state.isLoading -> CenteredProgress()
            state.error != null -> CenteredMessage(state.error!!)
            state.works.isEmpty() && !state.hasSearched ->
                CenteredMessage("e.g. “edward/bella romance all human complete”\n\nTap the ? for the full syntax guide.")
            state.works.isEmpty() ->
                CenteredMessage("No results found. Try adjusting your filters or search terms.")
            else -> LazyColumn(state = listState, modifier = Modifier.fillMaxSize()) {
                items(state.works, key = { it.id }) { work ->
                    WorkRow(
                        work = work,
                        isSaved = work.id in savedIds,
                        onClick = { onOpenWork(work.id) },
                        onToggleSave = { viewModel.toggleSave(work) },
                    )
                    HorizontalDivider(Modifier.padding(start = 16.dp))
                }
                if (state.isLoadingMore) {
                    item { CenteredProgress(small = true) }
                }
            }
        }
    }

    if (showHelp) {
        ModalBottomSheet(onDismissRequest = { showHelp = false }) {
            SearchHelpContent()
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun SearchHeader(
    state: SearchUiState,
    onQueryChange: (String) -> Unit,
    onSubmit: () -> Unit,
    onSetSort: (AO3SearchFilters.SortColumn) -> Unit,
    onToggleDirection: () -> Unit,
    onRemoveChip: ((AO3SearchFilters) -> Unit) -> Unit,
    onShowHelp: () -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(
                value = state.queryText,
                onValueChange = onQueryChange,
                modifier = Modifier.weight(1f),
                placeholder = { Text("e.g. edward/bella romance all human complete") },
                leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
                singleLine = true,
                keyboardActions = androidx.compose.foundation.text.KeyboardActions(onSearch = { onSubmit() }),
                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = ImeAction.Search),
            )
            IconButton(onClick = onShowHelp) {
                Icon(Icons.AutoMirrored.Filled.HelpOutline, contentDescription = "Search help")
            }
        }

        SortBar(
            sortColumn = state.sortColumn,
            sortDirection = state.sortDirection,
            onSetSort = onSetSort,
            onToggleDirection = onToggleDirection,
        )

        val chips = filterChips(state.parsed, onRemoveChip)
        if (chips.isNotEmpty()) {
            FlowRow(
                modifier = Modifier.fillMaxWidth().padding(top = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                chips.forEach { chip ->
                    // A filled, borderless capsule tinted by kind — the iOS
                    // ChipView look: include chips are accent-tinted, exclude
                    // chips red-tinted (both background + text).
                    val tint = if (chip.isExclude) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary
                    InputChip(
                        selected = false,
                        onClick = chip.onRemove,
                        label = { Text(chip.label) },
                        trailingIcon = {
                            Icon(Icons.Filled.Close, contentDescription = "Remove", modifier = Modifier.size(16.dp))
                        },
                        border = null,
                        colors = InputChipDefaults.inputChipColors(
                            containerColor = tint.copy(alpha = 0.18f),
                            labelColor = tint,
                            trailingIconColor = tint,
                        ),
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SortBar(
    sortColumn: AO3SearchFilters.SortColumn,
    sortDirection: AO3SearchFilters.SortDirection,
    onSetSort: (AO3SearchFilters.SortColumn) -> Unit,
    onToggleDirection: () -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box {
            TextButton(onClick = { expanded = true }) {
                Icon(Icons.Filled.SwapVert, contentDescription = null, modifier = Modifier.size(18.dp))
                Text("  ${sortColumn.displayName}", style = MaterialTheme.typography.labelLarge)
            }
            DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                AO3SearchFilters.SortColumn.entries.forEach { column ->
                    DropdownMenuItem(
                        text = { Text(column.displayName) },
                        onClick = { expanded = false; onSetSort(column) },
                    )
                }
            }
        }
        IconButton(onClick = onToggleDirection) {
            val ascending = sortDirection == AO3SearchFilters.SortDirection.ASC
            Icon(
                if (ascending) Icons.Filled.ArrowUpward else Icons.Filled.ArrowDownward,
                contentDescription = if (ascending) "Ascending" else "Descending",
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

private data class FilterChip(val label: String, val isExclude: Boolean, val onRemove: () -> Unit)

/** Builds the removable chips from the parsed filters — port of iOS `filterChips()`. */
private fun filterChips(
    f: AO3SearchFilters,
    onRemoveChip: ((AO3SearchFilters) -> Unit) -> Unit,
): List<FilterChip> {
    val chips = mutableListOf<FilterChip>()

    f.relationshipNames.forEach { ship ->
        chips += FilterChip("♥ $ship", false) { onRemoveChip { it.relationshipNames = it.relationshipNames - ship } }
    }
    f.characterNames.forEach { character ->
        chips += FilterChip("👤 $character", false) { onRemoveChip { it.characterNames = it.characterNames - character } }
    }
    f.fandomNames.forEach { fandom ->
        chips += FilterChip("📚 $fandom", false) { onRemoveChip { it.fandomNames = it.fandomNames - fandom } }
    }
    f.freeformNames.forEach { tag ->
        chips += FilterChip(tag, false) { onRemoveChip { it.freeformNames = it.freeformNames - tag } }
    }
    f.ratings.sortedBy { it.id }.forEach { rating ->
        chips += FilterChip(rating.displayName, false) { onRemoveChip { it.ratings = it.ratings - rating } }
    }
    f.warnings.sortedBy { it.id }.forEach { warning ->
        chips += FilterChip(warning.displayName, false) { onRemoveChip { it.warnings = it.warnings - warning } }
    }
    f.categories.sortedBy { it.id }.forEach { category ->
        chips += FilterChip(category.displayName, false) { onRemoveChip { it.categories = it.categories - category } }
    }
    if (f.wordCount.isNotEmpty()) {
        chips += FilterChip("words ${f.wordCount}", false) { onRemoveChip { it.wordCount = "" } }
    }
    if (f.languageId.isNotEmpty()) {
        chips += FilterChip("lang ${f.languageId}", false) { onRemoveChip { it.languageId = "" } }
    }
    if (f.singleChapter) {
        chips += FilterChip("oneshot", false) { onRemoveChip { it.singleChapter = false } }
    }
    when (f.complete) {
        AO3SearchFilters.TriState.YES -> chips += FilterChip("complete", false) { onRemoveChip { it.complete = AO3SearchFilters.TriState.ANY } }
        AO3SearchFilters.TriState.NO -> chips += FilterChip("WIP", false) { onRemoveChip { it.complete = AO3SearchFilters.TriState.ANY } }
        AO3SearchFilters.TriState.ANY -> {}
    }
    when (f.crossover) {
        AO3SearchFilters.TriState.YES -> chips += FilterChip("crossover", false) { onRemoveChip { it.crossover = AO3SearchFilters.TriState.ANY } }
        AO3SearchFilters.TriState.NO -> chips += FilterChip("no crossover", false) { onRemoveChip { it.crossover = AO3SearchFilters.TriState.ANY } }
        AO3SearchFilters.TriState.ANY -> {}
    }
    if (f.title.isNotEmpty()) {
        chips += FilterChip("title “${f.title}”", false) { onRemoveChip { it.title = "" } }
    }
    if (f.creators.isNotEmpty()) {
        chips += FilterChip("author “${f.creators}”", false) { onRemoveChip { it.creators = "" } }
    }
    if (f.query.isNotEmpty()) {
        chips += FilterChip("“${f.query}”", false) { onRemoveChip { it.query = "" } }
    }
    f.excludedFreeforms.forEach { excluded ->
        chips += FilterChip(excluded, true) { onRemoveChip { it.excludedFreeforms = it.excludedFreeforms - excluded } }
    }
    return chips
}

@Composable
private fun SearchHelpContent() {
    Column(
        Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 20.dp)
            .padding(bottom = 32.dp),
    ) {
        Text("Search Syntax Guide", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
        Text(
            "Type a natural-language prompt and Fanficly turns it into AO3 filters. Mix and match any of these:",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(top = 4.dp, bottom = 12.dp),
        )
        HelpSection("Relationships (ships)", listOf(
            "harry/draco" to "Search a ship using a slash.",
            "\"Hermione Granger/Draco Malfoy\"" to "Quote a full canonical relationship.",
        ))
        HelpSection("Story title & author", listOf(
            "title:Gatsby" to "Works with 'Gatsby' in the title.",
            "title:\"The Great Gatsby\"" to "Quote a multi-word title.",
            "author:astolat" to "Works by a creator.",
        ))
        HelpSection("Excluding terms/tags", listOf(
            "-angst" to "Exclude works tagged 'angst'.",
            "not \"happy ending\"" to "Exclude a quoted phrase.",
        ))
        HelpSection("Word count", listOf(
            "under 10k" to "Fewer than 10,000 words.",
            "over 50k" to "More than 50,000 words.",
            "between 10k and 50k" to "A word-count range.",
        ))
        HelpSection("Completion & format", listOf(
            "complete" to "Only completed works.",
            "wip" to "Works in progress.",
            "oneshot" to "Single-chapter works.",
        ))
        HelpSection("Engagement & sorting", listOf(
            "popular" to "Works with >1,000 kudos.",
            "most kudos" to "Sort by kudos.",
            "most hits" to "Sort by hits.",
            "recently updated" to "Sort by update date.",
        ))
        HelpSection("Ratings, warnings, categories & language", listOf(
            "explicit / teen / mature" to "Filter by rating.",
            "major character death" to "Filter by archive warning.",
            "f/f, m/m, gen" to "Filter by category.",
            "in spanish" to "Filter by language.",
        ))
    }
}

@Composable
private fun HelpSection(title: String, examples: List<Pair<String, String>>) {
    Column(Modifier.padding(vertical = 8.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        examples.forEach { (query, description) ->
            Column(Modifier.padding(top = 8.dp, start = 4.dp)) {
                Surface(
                    color = MaterialTheme.colorScheme.surfaceVariant,
                    shape = MaterialTheme.shapes.small,
                ) {
                    Text(
                        query,
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.SemiBold,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
                    )
                }
                Text(
                    description,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 2.dp),
                )
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
