package io.github.yennster.fanficly

import io.github.yennster.fanficly.browse.FandomCatalog
import io.github.yennster.fanficly.model.FandomIcon
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of the iOS `FandomCatalogTests` — fandom → category icon heuristic. */
class FandomCatalogTest {

    @Test fun exactCatalogMatchWins() {
        // Harry Potter is seeded under Books & Literature → BOOK icon.
        assertEquals(FandomIcon.BOOK, FandomCatalog.iconFor("Harry Potter - J. K. Rowling"))
    }

    @Test fun videoGameSuffix() {
        assertEquals(FandomIcon.GAME, FandomCatalog.iconFor("Some New Game (Video Game)"))
    }

    @Test fun tvSuffix() {
        assertEquals(FandomIcon.TV, FandomCatalog.iconFor("Some New Show (TV 2024)"))
    }

    @Test fun animeSuffix() {
        assertEquals(FandomIcon.ANIME, FandomCatalog.iconFor("Some Series (Anime & Manga)"))
    }

    @Test fun podcastFallsBackToAudio() {
        assertEquals(FandomIcon.AUDIO, FandomCatalog.iconFor("Some New Show (Podcast)"))
    }

    @Test fun rpfIsPerson() {
        assertEquals(FandomIcon.PERSON, FandomCatalog.iconFor("Some Sport RPF"))
    }

    @Test fun unknownDefaultsToBook() {
        assertEquals(FandomIcon.BOOK, FandomCatalog.iconFor("A Completely Unknown Thing"))
    }

    @Test fun catalogHasTenCategories() {
        assertEquals(10, FandomCatalog.all.size)
        assertTrue(FandomCatalog.all.all { it.fandoms.isNotEmpty() })
    }
}
