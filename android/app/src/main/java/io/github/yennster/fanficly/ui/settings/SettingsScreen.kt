package io.github.yennster.fanficly.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import io.github.yennster.fanficly.ui.reader.ReaderFontFamily
import io.github.yennster.fanficly.ui.reader.ReaderMetrics
import io.github.yennster.fanficly.ui.reader.ReaderTheme
import io.github.yennster.fanficly.ui.reader.ReadingMode

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun SettingsScreen(viewModel: SettingsViewModel = viewModel()) {
    val settings by viewModel.settings.collectAsStateWithLifecycle()

    Column(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(20.dp),
    ) {
        SectionHeader("Reader Theme")
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ReaderTheme.entries.forEach { t ->
                FilterChip(
                    selected = settings.theme == t,
                    onClick = { viewModel.setTheme(t) },
                    label = { Text(t.displayName) },
                )
            }
        }

        SectionHeader("Reading Mode")
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ReadingMode.entries.forEach { m ->
                FilterChip(
                    selected = settings.mode == m,
                    onClick = { viewModel.setMode(m) },
                    label = { Text(m.displayName) },
                )
            }
        }

        SectionHeader("Font")
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ReaderFontFamily.entries.forEach { f ->
                FilterChip(
                    selected = settings.fontFamily == f,
                    onClick = { viewModel.setFont(f) },
                    label = { Text(f.displayName) },
                )
            }
        }

        LabeledSlider(
            label = "Text size",
            value = settings.fontSize,
            range = ReaderMetrics.fontSizeRange,
            onChange = viewModel::setFontSize,
            display = "${settings.fontSize.toInt()} pt",
        )
        LabeledSlider(
            label = "Line spacing",
            value = settings.lineSpacing,
            range = ReaderMetrics.lineSpacingRange,
            onChange = viewModel::setLineSpacing,
            display = "${settings.lineSpacing.toInt()}",
        )
        LabeledSlider(
            label = "Paragraph spacing",
            value = settings.paragraphSpacing,
            range = ReaderMetrics.paragraphSpacingRange,
            onChange = viewModel::setParagraphSpacing,
            display = "${settings.paragraphSpacing.toInt()}",
        )

        SectionHeader("Privacy")
        Text(
            "Fanficly stores nothing off-device. There are no analytics, ad IDs, or trackers. " +
                "Your only saved secret is the AO3 session cookie, kept in encrypted on-device storage.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun SectionHeader(text: String) {
    Text(text, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
}

@Composable
private fun LabeledSlider(
    label: String,
    value: Float,
    range: ClosedFloatingPointRange<Float>,
    onChange: (Float) -> Unit,
    display: String,
) {
    Column(Modifier.fillMaxWidth()) {
        Text("$label — $display", style = MaterialTheme.typography.bodyMedium)
        Slider(value = value, onValueChange = onChange, valueRange = range)
    }
}
