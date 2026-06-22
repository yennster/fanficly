package io.github.yennster.fanficly

import io.github.yennster.fanficly.model.AO3SearchFilters
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Covers `AO3SearchFilters.promptText()` — the normalized search-box text shown
 * after a chip is removed — and `wordCountPhrase`. Port of iOS `PromptTextTests`.
 */
class PromptTextTest {

    @Test fun includesActiveFilters() {
        val f = AO3SearchFilters().apply {
            relationshipNames = listOf("Hermione Granger/Draco Malfoy")
            ratings = setOf(AO3SearchFilters.Rating.EXPLICIT)
            complete = AO3SearchFilters.TriState.YES
            singleChapter = true
            excludedFreeforms = listOf("Angst")
        }
        val text = f.promptText()
        assertTrue(text.contains("Hermione Granger/Draco Malfoy"))
        assertTrue(text.contains("Explicit"))
        assertTrue(text.contains("complete"))
        assertTrue(text.contains("oneshot"))
        assertTrue(text.contains("-Angst"))
    }

    @Test fun removingAFilterDropsItFromText() {
        val f = AO3SearchFilters().apply {
            freeformNames = listOf("Fluff")
            complete = AO3SearchFilters.TriState.YES
        }
        assertTrue(f.promptText().contains("complete"))

        f.complete = AO3SearchFilters.TriState.ANY  // "removed the complete chip"
        val text = f.promptText()
        assertFalse(text.contains("complete"))
        assertTrue(text.contains("Fluff"))
    }

    @Test fun wordCountPhrasing() {
        assertEquals("over 10000", AO3SearchFilters.wordCountPhrase(">10000"))
        assertEquals("under 5000", AO3SearchFilters.wordCountPhrase("<5000"))
        assertEquals("between 1000 and 5000", AO3SearchFilters.wordCountPhrase("1000-5000"))
    }

    @Test fun emptyFiltersGiveEmptyText() {
        assertTrue(AO3SearchFilters().promptText().isEmpty())
    }
}
