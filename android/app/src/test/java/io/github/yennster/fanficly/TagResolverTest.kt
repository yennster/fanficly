package io.github.yennster.fanficly

import io.github.yennster.fanficly.model.AO3SearchFilters
import io.github.yennster.fanficly.model.AutocompleteField
import io.github.yennster.fanficly.net.MockAO3Client
import io.github.yennster.fanficly.search.TagResolver
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Port of the iOS `TagResolverTests` — canonical resolution + ship fallback. */
class TagResolverTest {

    @Before fun clearCache() = runBlocking {
        // The resolution cache is process-global; clear it so a memoized result
        // from one case can't leak into the next.
        TagResolver.clearCacheForTesting()
    }

    @Test fun bestMatchPrefersExactCaseInsensitive() {
        val matches = listOf("Hermione Granger/Draco Malfoy", "Draco Malfoy/Harry Potter")
        assertEquals(
            "Hermione Granger/Draco Malfoy",
            TagResolver.bestMatch("hermione granger/draco malfoy", matches),
        )
    }

    @Test fun bestMatchFallsBackToFirst() {
        val matches = listOf("Hermione Granger/Draco Malfoy", "Other Ship")
        assertEquals("Hermione Granger/Draco Malfoy", TagResolver.bestMatch("dramione", matches))
    }

    @Test fun bestMatchEmptyReturnsNull() {
        assertNull(TagResolver.bestMatch("x", emptyList()))
    }

    @Test fun candidatesRelationshipExpandsSlashVariants() {
        val c = TagResolver.candidates("hermione/draco", AutocompleteField.RELATIONSHIP)
        assertTrue(c.contains("hermione/draco"))
        assertTrue(c.contains("hermione draco"))   // slash -> space
        assertTrue(c.contains("draco hermione"))   // reversed
    }

    @Test fun candidatesNonRelationshipIsJustTheTerm() {
        assertEquals(listOf("Slow Burn"), TagResolver.candidates("Slow Burn", AutocompleteField.FREEFORM))
        assertEquals(listOf("Hermione Granger"), TagResolver.candidates("Hermione Granger", AutocompleteField.CHARACTER))
    }

    @Test fun resolveUsesMockAutocomplete() = runBlocking {
        // MockAO3Client echoes the term, so resolution returns the input.
        val filters = AO3SearchFilters().apply { relationshipNames = listOf("Edward/Bella") }
        val resolved = TagResolver.resolve(filters, MockAO3Client())
        assertEquals(listOf("Edward/Bella"), resolved.relationshipNames)
    }

    @Test fun resolveShipViaCharacterFallback() = runBlocking {
        val stub = StubAO3Client().apply {
            autocompleteResponses = mapOf(
                // Direct relationship lookups return nothing for the short forms…
                "hermione/draco" to emptyList(),
                "hermione draco" to emptyList(),
                "draco hermione" to emptyList(),
                // …character lookups succeed…
                "hermione" to listOf("Hermione Granger"),
                "draco" to listOf("Draco Malfoy"),
                // …and the ship from the canonical names resolves.
                "hermione granger/draco malfoy" to listOf("Hermione Granger/Draco Malfoy"),
            )
        }
        val filters = AO3SearchFilters().apply { relationshipNames = listOf("hermione/draco") }
        val resolved = TagResolver.resolve(filters, stub)
        assertEquals(listOf("Hermione Granger/Draco Malfoy"), resolved.relationshipNames)
    }

    @Test fun bestMatchRelationshipPrefersSameArityWholeWordMatch() {
        val matches = listOf(
            "Oswald Cobblepot/Isabella/Edward Nygma",
            "Bella Swan/Edward Cullen",
        )
        assertEquals(
            "Bella Swan/Edward Cullen",
            TagResolver.bestMatch("Bella/Edward", matches, AutocompleteField.RELATIONSHIP),
        )
    }

    @Test fun resolveDirectRelationshipMatch() = runBlocking {
        val stub = StubAO3Client().apply {
            autocompleteResponses = mapOf("edward/bella" to listOf("Edward Cullen/Bella Swan"))
        }
        val filters = AO3SearchFilters().apply { relationshipNames = listOf("edward/bella") }
        val resolved = TagResolver.resolve(filters, stub)
        assertEquals(listOf("Edward Cullen/Bella Swan"), resolved.relationshipNames)
    }
}
