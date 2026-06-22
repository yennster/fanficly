package io.github.yennster.fanficly.net.parse

import io.github.yennster.fanficly.model.AO3TagFacet
import io.github.yennster.fanficly.model.AO3WorkFilters
import org.jsoup.Jsoup
import org.jsoup.nodes.Document

/**
 * Parses the faceted filter sidebar AO3 renders on a works listing
 * (`/tags/<tag>/works`) — the Kotlin port of iOS `WorkFiltersParser`. Each facet
 * is a `<label for="include_<kind>_ids_<n>">Tag Name <span class="count">(123)
 * </span></label>`; the count comes from `span.count`, the name from the rest.
 */
object WorkFiltersParser {

    fun parse(html: String): AO3WorkFilters {
        val doc = Jsoup.parse(html)
        return AO3WorkFilters(
            relationships = facets(doc, "include_relationship_ids"),
            characters = facets(doc, "include_character_ids"),
            fandoms = facets(doc, "include_fandom_ids"),
            freeforms = facets(doc, "include_freeform_ids"),
        )
    }

    private fun facets(doc: Document, idPrefix: String): List<AO3TagFacet> {
        val result = mutableListOf<AO3TagFacet>()
        for (label in doc.select("label[for^=$idPrefix]")) {
            val countText = label.selectFirst("span.count")?.text()
            val count = countText?.let { MediaCategoryParser.trailingCount(it) } ?: 0
            var name = label.text()
            if (countText != null) name = name.replace(countText, "")
            name = name.trim()
            if (name.isEmpty()) continue
            result += AO3TagFacet(name = name, count = count)
        }
        return result
    }
}
