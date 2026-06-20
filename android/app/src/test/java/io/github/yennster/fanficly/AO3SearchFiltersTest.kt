package io.github.yennster.fanficly

import io.github.yennster.fanficly.model.AO3SearchFilters
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of the iOS `AO3SearchFiltersTests` — every quirky mapping documented in AGENTS.md. */
class AO3SearchFiltersTest {

    @Test
    fun singleRatingUsesDedicatedField() {
        val f = AO3SearchFilters().apply { ratings = setOf(AO3SearchFilters.Rating.MATURE) }
        val items = f.queryItems()
        assertTrue(items.any { it.first == "work_search[rating_ids]" && it.second == "12" })
        assertFalse(f.composedQueryString().contains("rating_ids"))
    }

    @Test
    fun multipleRatingsOrInQueryField() {
        val f = AO3SearchFilters().apply {
            ratings = setOf(AO3SearchFilters.Rating.MATURE, AO3SearchFilters.Rating.EXPLICIT)
        }
        val query = f.composedQueryString()
        assertEquals("(rating_ids:12 OR rating_ids:13)", query)
        // The dedicated single-rating field must NOT be emitted for 2+ ratings.
        assertFalse(f.queryItems().any { it.first == "work_search[rating_ids]" })
    }

    @Test
    fun warningsStayArrays() {
        val f = AO3SearchFilters().apply {
            warnings = setOf(
                AO3SearchFilters.ArchiveWarning.UNDERAGE,
                AO3SearchFilters.ArchiveWarning.GRAPHIC_VIOLENCE,
            )
        }
        val warningItems = f.queryItems().filter { it.first == "work_search[archive_warning_ids][]" }
        assertEquals(2, warningItems.size)
    }

    @Test
    fun excludedFreeformsBecomeNotClauses() {
        val f = AO3SearchFilters().apply {
            query = "coffee shop"
            excludedFreeforms = listOf("Angst", "Major Character Death")
        }
        val q = f.composedQueryString()
        assertTrue(q.contains("NOT Angst"))
        assertTrue(q.contains("NOT \"Major Character Death\""))
    }

    @Test
    fun emptyFiltersAreEmpty() {
        assertTrue(AO3SearchFilters().isEmpty)
        assertFalse(AO3SearchFilters().apply { query = "x" }.isEmpty)
    }
}
