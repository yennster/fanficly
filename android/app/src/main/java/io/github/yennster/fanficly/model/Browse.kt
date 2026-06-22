package io.github.yennster.fanficly.model

import kotlinx.serialization.Serializable

/**
 * Browse / Popular models — the Kotlin port of the iOS `FandomCategory` /
 * `BrowseFandom` / `AO3WorkFilters` / `PopularSnapshot` types. The [FandomIcon]
 * enum stands in for the iOS SF Symbol string; the UI maps it to a Compose
 * `ImageVector` so the model layer stays Compose-free and testable.
 */
enum class FandomIcon { ANIME, BOOK, CARTOON, PERSON, FILM, MUSIC, AUDIO, THEATER, TV, GAME }

data class FandomCategory(
    val id: String,
    val name: String,
    val icon: FandomIcon,
    val fandoms: List<BrowseFandom>,
) {
    val ao3CanonicalName: String get() = name
}

data class BrowseFandom(
    val displayName: String,
    val canonicalName: String = displayName,
    /** AO3's listed work count (from `/media/.../fandoms`), when known. */
    val workCount: Int? = null,
)

/** One tag in a works-listing filter sidebar, with its work count. */
data class AO3TagFacet(val name: String, val count: Int)

/**
 * The faceted filter sidebar AO3 renders on a works listing
 * (`/tags/<tag>/works`): the most-used relationships, characters, fandoms, and
 * additional tags within that scope. Drives the live Popular ships/characters.
 */
data class AO3WorkFilters(
    val relationships: List<AO3TagFacet>,
    val characters: List<AO3TagFacet>,
    val fandoms: List<AO3TagFacet>,
    val freeforms: List<AO3TagFacet>,
)

/**
 * A daily snapshot of AO3's popular fandoms/ships/characters, cached on-device
 * (see `PopularStore`). Names are AO3-canonical so tapping one resolves to a
 * search. [fetchedAt] is epoch millis.
 */
@Serializable
data class PopularSnapshot(
    val fandoms: List<String>,
    val ships: List<String>,
    val characters: List<String>,
    val fetchedAt: Long,
)

/** A popular tag tapped in the Popular tab. */
enum class PopularKind { FANDOM, SHIP, CHARACTER }
