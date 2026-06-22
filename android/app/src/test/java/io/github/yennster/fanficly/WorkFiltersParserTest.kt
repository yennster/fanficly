package io.github.yennster.fanficly

import io.github.yennster.fanficly.net.parse.WorkFiltersParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of the iOS `WorkFiltersParser` facet-sidebar tests. */
class WorkFiltersParserTest {

    private val html = """
        <form id="work-filters">
          <fieldset>
            <label for="include_relationship_ids_136">Draco Malfoy/Harry Potter <span class="count">(12,345)</span></label>
            <label for="include_relationship_ids_99">Hermione Granger/Draco Malfoy <span class="count">(6,789)</span></label>
          </fieldset>
          <fieldset>
            <label for="include_character_ids_5">Harry Potter <span class="count">(54,321)</span></label>
            <label for="include_character_ids_8">Draco Malfoy <span class="count">(43,210)</span></label>
          </fieldset>
          <fieldset>
            <label for="include_freeform_ids_1">Fluff <span class="count">(9,000)</span></label>
          </fieldset>
        </form>
    """.trimIndent()

    @Test fun parsesRelationshipsWithCounts() {
        val filters = WorkFiltersParser.parse(html)
        assertEquals(2, filters.relationships.size)
        val top = filters.relationships.first()
        assertEquals("Draco Malfoy/Harry Potter", top.name)
        assertEquals(12345, top.count)
    }

    @Test fun parsesCharactersAndFreeforms() {
        val filters = WorkFiltersParser.parse(html)
        assertEquals(2, filters.characters.size)
        assertTrue(filters.characters.any { it.name == "Harry Potter" && it.count == 54321 })
        assertEquals(1, filters.freeforms.size)
        assertEquals("Fluff", filters.freeforms.first().name)
    }

    @Test fun nameStripsTheCountText() {
        val filters = WorkFiltersParser.parse(html)
        // The "(12,345)" count must not bleed into the tag name.
        assertTrue(filters.relationships.none { it.name.contains("(") })
    }
}
