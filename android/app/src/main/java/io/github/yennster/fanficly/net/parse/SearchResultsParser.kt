package io.github.yennster.fanficly.net.parse

import io.github.yennster.fanficly.model.SearchResults
import io.github.yennster.fanficly.model.WorkSummary
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import java.text.SimpleDateFormat
import java.util.Locale

/**
 * Parses an AO3 blurb listing (search / author works / bookmarks) — the Kotlin
 * port of iOS `SearchResultsParser`. Pure: takes an HTML string, returns typed
 * [SearchResults]. The bookmarks page uses `li.bookmark.blurb` (same inner
 * markup, different container), so callers pass that selector and reuse the rest.
 */
object SearchResultsParser {

    fun parse(html: String, blurbSelector: String = "li.work.blurb"): SearchResults {
        val doc = Jsoup.parse(html)
        val works = doc.select(blurbSelector).mapNotNull { parseBlurb(it) }

        var currentPage = 1
        var totalPages = 1
        for (li in doc.select("ol.pagination li")) {
            val num = li.text().trim().toIntOrNull() ?: continue
            totalPages = maxOf(totalPages, num)
            // will_paginate marks the current page with a "current" class — on the
            // <li> itself OR on an inner span/em. Check both, or "Load more" keeps
            // re-requesting the same page.
            val liIsCurrent = li.className().contains("current")
            val innerIsCurrent = li.select(".current").isNotEmpty()
            if (liIsCurrent || innerIsCurrent) currentPage = num
        }

        return SearchResults(works = works, totalPages = totalPages, currentPage = currentPage)
    }

    fun parseBlurb(li: Element): WorkSummary? {
        val titleAnchor = li.selectFirst("h4.heading a")

        // Work id: search/author pages tag the <li> as `work_<id>`; bookmarks tag
        // it `bookmark_<id>`, so fall back to the `/works/<id>` title link.
        // Series/external/deleted bookmarks have no such link → skipped (null).
        val idAttr = li.id()
        val id: Int = idAttr.removePrefix("work_").toIntOrNull()
            ?: titleAnchor?.attr("href")?.let { workId(it) }
            ?: return null

        val title = titleAnchor?.text() ?: ""

        val authorAnchors = li.select("h4.heading a[rel=author]")
        val author = authorAnchors.joinToString(", ") { it.text() }
        val authorUsername = authorLogin(authorAnchors.firstOrNull()?.attr("href") ?: "")

        val fandoms = li.select("h5.fandoms a.tag").map { it.text() }

        val requiredTagTexts = li.select("ul.required-tags span.text").map { it.text() }
        val rating = requiredTagTexts.firstOrNull { isRating(it) } ?: "Not Rated"
        val warnings = requiredTagTexts.filter { isWarning(it) }
        val categories = requiredTagTexts.filter { isCategory(it) }
        val isComplete = requiredTagTexts.any { it == "Complete Work" }

        val relationships = li.select("ul.tags li.relationships a.tag").map { it.text() }
        val characters = li.select("ul.tags li.characters a.tag").map { it.text() }
        val freeforms = li.select("ul.tags li.freeforms a.tag").map { it.text() }

        val summary = li.selectFirst("blockquote.summary")?.text() ?: ""
        val language = li.selectFirst("dd.language")?.text() ?: "English"
        val wordCount = (li.selectFirst("dd.words")?.text() ?: "0").replace(",", "").toIntOrNull() ?: 0
        val kudos = (li.selectFirst("dd.kudos")?.text() ?: "0").replace(",", "").toIntOrNull() ?: 0
        val hits = (li.selectFirst("dd.hits")?.text() ?: "0").replace(",", "").toIntOrNull() ?: 0

        val (chapterCount, totalChapters) = parseChapterFraction(li.selectFirst("dd.chapters")?.text() ?: "1/1")
        val updatedAt = parseAO3Date(li.selectFirst("p.datetime")?.text() ?: "")

        return WorkSummary(
            id = id,
            title = title,
            author = author,
            authorUsername = authorUsername,
            summary = summary,
            rating = rating,
            warnings = warnings,
            categories = categories,
            fandoms = fandoms,
            characters = characters,
            relationships = relationships,
            freeforms = freeforms,
            wordCount = wordCount,
            chapterCount = chapterCount,
            totalChapters = totalChapters,
            language = language,
            kudos = kudos,
            hits = hits,
            isComplete = isComplete,
            updatedAtMillis = updatedAt,
        )
    }

    /** Numeric work id from `/works/12345` or `/works/12345/chapters/678`; null for non-work links. */
    fun workId(href: String): Int? {
        val marker = "/works/"
        val idx = href.indexOf(marker)
        if (idx < 0) return null
        val rest = href.substring(idx + marker.length)
        return rest.substringBefore('/').toIntOrNull()
    }

    /** AO3 login from `/users/Name/pseuds/Name` → `Name`; "" for anonymous. */
    fun authorLogin(href: String): String {
        val marker = "/users/"
        val idx = href.indexOf(marker)
        if (idx < 0) return ""
        val seg = href.substring(idx + marker.length).substringBefore('/')
        return runCatching { java.net.URLDecoder.decode(seg, "UTF-8") }.getOrDefault(seg)
    }

    private fun parseChapterFraction(s: String): Pair<Int, Int?> {
        val parts = s.split("/").map { it.trim() }
        val current = parts.getOrNull(0)?.toIntOrNull() ?: 1
        val total: Int? = when {
            parts.size > 1 && parts[1] == "?" -> null
            parts.size > 1 -> parts[1].toIntOrNull() ?: current
            else -> current
        }
        return current to total
    }

    private fun parseAO3Date(s: String): Long? {
        val trimmed = s.trim()
        if (trimmed.isEmpty()) return null
        return runCatching {
            SimpleDateFormat("dd MMM yyyy", Locale.US).parse(trimmed)?.time
        }.getOrNull()
    }

    private fun isRating(s: String) = s in setOf(
        "General Audiences", "Teen And Up Audiences", "Mature", "Explicit", "Not Rated"
    )

    private fun isWarning(s: String) = s in setOf(
        "No Archive Warnings Apply",
        "Creator Chose Not To Use Archive Warnings",
        "Graphic Depictions Of Violence",
        "Major Character Death",
        "Rape/Non-Con",
        "Underage",
    )

    private fun isCategory(s: String) = s in setOf("F/F", "F/M", "Gen", "M/M", "Multi", "Other")
}
