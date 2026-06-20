package io.github.yennster.fanficly.ui.settings

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import io.github.yennster.fanficly.FanficlyApplication
import io.github.yennster.fanficly.data.ReaderSettings
import io.github.yennster.fanficly.ui.reader.ReaderFontFamily
import io.github.yennster.fanficly.ui.reader.ReaderTheme
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

class SettingsViewModel(app: Application) : AndroidViewModel(app) {
    private val store = (app as FanficlyApplication).container.settingsStore

    val settings: StateFlow<ReaderSettings> = store.settings
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), ReaderSettings())

    fun setTheme(theme: ReaderTheme) = viewModelScope.launch { store.update { it.copy(theme = theme) } }
    fun setFont(font: ReaderFontFamily) = viewModelScope.launch { store.update { it.copy(fontFamily = font) } }
    fun setFontSize(size: Float) = viewModelScope.launch { store.update { it.copy(fontSize = size) } }
    fun setLineSpacing(v: Float) = viewModelScope.launch { store.update { it.copy(lineSpacing = v) } }
    fun setParagraphSpacing(v: Float) = viewModelScope.launch { store.update { it.copy(paragraphSpacing = v) } }
}
