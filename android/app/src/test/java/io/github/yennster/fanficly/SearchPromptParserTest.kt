package io.github.yennster.fanficly

import io.github.yennster.fanficly.model.AO3SearchFilters
import io.github.yennster.fanficly.search.SearchPromptParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Port of the iOS `SearchPromptParserTests` — the same prompts in, the same
 * structured [AO3SearchFilters] out. Pure, no network.
 */
class SearchPromptParserTest {
    private val parser = SearchPromptParser()

    @Test fun shipsBecomeRelationships() {
        val f = parser.parse("edward/bella")
        assertEquals(listOf("Edward/Bella"), f.relationshipNames)
        assertEquals("", f.query)
    }

    @Test fun quotedRelationshipStaysWholeNotResplitOnSlash() {
        val f = parser.parse("\"Hermione Granger/Draco Malfoy\" slow burn")
        assertEquals(listOf("Hermione Granger/Draco Malfoy"), f.relationshipNames)
        assertFalse(f.relationshipNames.contains("Granger/Draco"))
        assertTrue(f.freeformNames.contains("Slow Burn"))
        assertEquals("", f.query)
    }

    @Test fun quotedPhraseWithoutSlashIsFreeform() {
        val f = parser.parse("\"Coffee Shop AU\"")
        assertTrue(f.freeformNames.contains("Coffee Shop Au"))
        assertTrue(f.relationshipNames.isEmpty())
        assertEquals("", f.query)
    }

    @Test fun categorySlashIsNotMistakenForShip() {
        val f = parser.parse("f/f romance")
        assertTrue(f.categories.contains(AO3SearchFilters.Category.FF))
        assertTrue(f.relationshipNames.isEmpty())
    }

    @Test fun ratingExplicit() {
        assertTrue(parser.parse("edward/bella explicit").ratings.contains(AO3SearchFilters.Rating.EXPLICIT))
    }

    @Test fun ratingShortForm() {
        assertTrue(parser.parse("e-rated harry/draco").ratings.contains(AO3SearchFilters.Rating.EXPLICIT))
    }

    @Test fun warningMajorCharacterDeath() {
        assertTrue(parser.parse("major character death angst").warnings.contains(AO3SearchFilters.ArchiveWarning.MAJOR_CHARACTER_DEATH))
    }

    @Test fun warningNoWarnings() {
        assertTrue(parser.parse("no archive warnings apply fluff").warnings.contains(AO3SearchFilters.ArchiveWarning.NO_WARNINGS_APPLY))
    }

    @Test fun freeformTagAllHuman() {
        assertTrue(parser.parse("edward/bella all human").freeformNames.contains("All Human"))
    }

    @Test fun freeformTagSlowBurn() {
        val f = parser.parse("harry/draco slow burn enemies to lovers")
        assertTrue(f.freeformNames.contains("Slow Burn"))
        assertTrue(f.freeformNames.contains("Enemies to Lovers"))
    }

    @Test fun wordCountUnder() {
        val f = parser.parse("oneshot under 5k")
        assertEquals("<5000", f.wordCount)
        assertTrue(f.singleChapter)
    }

    @Test fun wordCountOver() {
        assertEquals(">50000", parser.parse("over 50k slow burn").wordCount)
    }

    @Test fun wordCountBetween() {
        assertEquals("5000-20000", parser.parse("between 5k and 20k").wordCount)
    }

    @Test fun statusComplete() {
        assertEquals(AO3SearchFilters.TriState.YES, parser.parse("complete edward/bella").complete)
    }

    @Test fun statusWIP() {
        assertEquals(AO3SearchFilters.TriState.NO, parser.parse("wip slow burn").complete)
    }

    @Test fun engagementPopular() {
        assertEquals(">1000", parser.parse("popular harry/draco").kudosCount)
    }

    @Test fun engagementMostKudos() {
        val f = parser.parse("most kudos")
        assertEquals(AO3SearchFilters.SortColumn.KUDOS_COUNT, f.sortColumn)
        assertEquals(AO3SearchFilters.SortDirection.DESC, f.sortDirection)
    }

    @Test fun language() {
        assertEquals("es", parser.parse("edward/bella in spanish").languageId)
    }

    @Test fun crossover() {
        assertEquals(AO3SearchFilters.TriState.YES, parser.parse("crossover edward/bella").crossover)
    }

    @Test fun noCrossover() {
        assertEquals(AO3SearchFilters.TriState.NO, parser.parse("no crossovers edward/bella").crossover)
    }

    @Test fun exclusionMinus() {
        assertEquals(listOf("omegaverse"), parser.parse("edward/bella -omegaverse").excludedFreeforms)
    }

    @Test fun exclusionMultiple() {
        val f = parser.parse("harry/draco -mpreg -omegaverse")
        assertTrue(f.excludedFreeforms.contains("mpreg"))
        assertTrue(f.excludedFreeforms.contains("omegaverse"))
    }

    @Test fun exclusionAngstAtEnd() {
        val f = parser.parse("draco/hermione explicit complete -angst")
        assertEquals(listOf("Draco/Hermione"), f.relationshipNames)
        assertTrue(f.ratings.contains(AO3SearchFilters.Rating.EXPLICIT))
        assertEquals(AO3SearchFilters.TriState.YES, f.complete)
        assertEquals(listOf("angst"), f.excludedFreeforms)
    }

    @Test fun exclusionAngstInMiddle() {
        val f = parser.parse("draco/hermione -angst complete")
        assertTrue(f.excludedFreeforms.contains("angst"))
        assertEquals(AO3SearchFilters.TriState.YES, f.complete)
    }

    @Test fun exclusionStopsAtNextWordDoesNotEatTrailingFandom() {
        val f = parser.parse("draco/hermione complete -omegaverse harry potter")
        assertEquals(listOf("omegaverse"), f.excludedFreeforms)
        assertTrue(f.fandomNames.contains("Harry Potter - J. K. Rowling"))
        assertEquals(listOf("Draco/Hermione"), f.relationshipNames)
        assertEquals(AO3SearchFilters.TriState.YES, f.complete)
    }

    @Test fun exclusionQuotedPhrase() {
        val f = parser.parse("harry/draco -\"slow burn\" complete")
        assertTrue(f.excludedFreeforms.contains("slow burn"))
        assertEquals(AO3SearchFilters.TriState.YES, f.complete)
    }

    @Test fun fandomHarryPotter() {
        val f = parser.parse("harry potter slow burn")
        assertEquals(listOf("Harry Potter - J. K. Rowling"), f.fandomNames)
        assertTrue(f.freeformNames.contains("Slow Burn"))
    }

    @Test fun fandomMcuAlias() {
        assertTrue(parser.parse("mcu fluff").fandomNames.contains("Marvel Cinematic Universe"))
    }

    @Test fun exampleEdwardBellaRomanceAllHumanExplicit() {
        val f = parser.parse("edward/bella romance all human explicit")
        assertEquals(listOf("Edward/Bella"), f.relationshipNames)
        assertTrue(f.ratings.contains(AO3SearchFilters.Rating.EXPLICIT))
        assertTrue(f.freeformNames.contains("All Human"))
        assertTrue(f.freeformNames.contains("Romance"))
        assertEquals("", f.query)
    }

    @Test fun romanceIsAFreeformTag() {
        val f = parser.parse("romance fluff")
        assertTrue(f.freeformNames.contains("Romance"))
        assertTrue(f.freeformNames.contains("Fluff"))
        assertEquals("", f.query)
    }

    @Test fun emptyPromptYieldsEmptyFilters() {
        assertTrue(parser.parse("").isEmpty)
    }

    @Test fun queryRemainderIsPreserved() {
        assertEquals("space pirates with feelings", parser.parse("space pirates with feelings").query)
    }

    @Test fun titleExtraction() {
        val f = parser.parse("title:\"The Great Gatsby\" edward/bella")
        assertEquals("The Great Gatsby", f.title)
        assertEquals(listOf("Edward/Bella"), f.relationshipNames)
        assertEquals("", f.query)
    }

    @Test fun unquotedTitleExtraction() {
        val f = parser.parse("title:Gatsby edward/bella")
        assertEquals("Gatsby", f.title)
        assertEquals(listOf("Edward/Bella"), f.relationshipNames)
        assertEquals("", f.query)
    }

    @Test fun smartQuotesTitleExtraction() {
        val f = parser.parse("title:“The Great Gatsby” edward/bella")
        assertEquals("The Great Gatsby", f.title)
        assertEquals(listOf("Edward/Bella"), f.relationshipNames)
        assertEquals("", f.query)
    }

    @Test fun smartQuotesQuotedPhraseWithoutSlashIsFreeform() {
        val f = parser.parse("“Coffee Shop AU”")
        assertTrue(f.freeformNames.contains("Coffee Shop Au"))
        assertTrue(f.relationshipNames.isEmpty())
        assertEquals("", f.query)
    }

    @Test fun authorExtraction() {
        val f = parser.parse("author:\"Astolat\" edward/bella")
        assertEquals("Astolat", f.creators)
        assertEquals(listOf("Edward/Bella"), f.relationshipNames)
        assertEquals("", f.query)
    }

    @Test fun unquotedAuthorExtraction() {
        val f = parser.parse("author:astolat edward/bella")
        assertEquals("astolat", f.creators)
        assertEquals(listOf("Edward/Bella"), f.relationshipNames)
        assertEquals("", f.query)
    }

    @Test fun authorAndTitleExtraction() {
        val f = parser.parse("author:astolat title:Tempest")
        assertEquals("astolat", f.creators)
        assertEquals("Tempest", f.title)
        assertEquals("", f.query)
    }

    @Test fun byAndCreatorExtraction() {
        assertEquals("astolat", parser.parse("by:astolat").creators)
        assertEquals("astolat", parser.parse("creator:\"astolat\"").creators)
        assertEquals("astolat", parser.parse("creators:astolat").creators)
    }

    @Test fun queryItemsRoundTripIncludesAllStandardFields() {
        val f = AO3SearchFilters().apply {
            relationshipNames = listOf("Edward/Bella")
            ratings = setOf(AO3SearchFilters.Rating.EXPLICIT)
            freeformNames = listOf("All Human")
            complete = AO3SearchFilters.TriState.YES
            wordCount = ">10000"
        }
        val names = f.queryItems().map { it.first }
        assertTrue(names.contains("work_search[relationship_names]"))
        assertTrue(names.contains("work_search[rating_ids]"))
        assertTrue(names.contains("work_search[freeform_names]"))
        assertTrue(names.contains("work_search[complete]"))
        assertTrue(names.contains("work_search[word_count]"))
    }

    @Test fun quotedPhraseKeepsMidWordApostropheLowercase() {
        // Swift String.capitalized leaves a mid-word apostrophe in-word:
        // "don't tell" -> "Don't Tell" (not "Don'T Tell").
        assertTrue(parser.parse("\"don't tell\"").freeformNames.contains("Don't Tell"))
    }

    @Test fun shipWithApostropheMatchesSwiftCapitalization() {
        // "o'brien/smith" -> "O'brien/Smith"; "mary'sue/peter" -> "Mary'sue/Peter".
        assertEquals(listOf("O'brien/Smith"), parser.parse("o'brien/smith").relationshipNames)
        assertEquals(listOf("Mary'sue/Peter"), parser.parse("mary'sue/peter").relationshipNames)
    }

    @Test fun excludedFreeformsBecomeNotInQuery() {
        val f = AO3SearchFilters().apply {
            query = "harry/draco"
            excludedFreeforms = listOf("mpreg")
        }
        val q = f.queryItems().firstOrNull { it.first == "work_search[query]" }?.second
        assertEquals("harry/draco NOT mpreg", q)
    }
}
