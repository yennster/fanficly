package io.github.yennster.fanficly.net.parse

import io.github.yennster.fanficly.model.ChapterPayload
import io.github.yennster.fanficly.model.WorkMetadata
import io.github.yennster.fanficly.model.WorkPayload
import io.github.yennster.fanficly.model.WorkSummary
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element
import java.text.SimpleDateFormat
import java.util.Locale

/**
 * Parses a full work page (`?view_full_work=true`) — the Kotlin port of iOS
 * `WorkPageParser`. The structured `dl.work.meta.group` holds the canonical
 * tags; chapters are wrapped in `div.chapter[id^=chapter-]` (the exact selector
 * that avoids matching nested `.preface` divs).
 */
object WorkPageParser {

    fun parse(html: String, workId: Int): WorkPayload {
        val doc = Jsoup.parse(html)

        // Strip AO3's screen-reader-only landmark headings so they don't render.
        doc.select("h3.landmark, .landmark.heading").remove()

        val title = firstNonEmptyText(
            doc,
            listOf(
                "#workskin .preface.group h2.title.heading",
                "#workskin h2.title.heading",
                "h2.title.heading",
                "h2.title",
            ),
        )

        val author = parseAuthor(doc)
        val authorUsername = run {
            val href = doc.selectFirst("h3.byline a")?.attr("href")
                ?: doc.selectFirst("dl.work.meta dd.creator a")?.attr("href")
                ?: ""
            SearchResultsParser.authorLogin(href)
        }

        val meta = doc.selectFirst("dl.work.meta.group")
        val rating = meta?.selectFirst("dd.rating a.tag")?.text() ?: "Not Rated"
        val warnings = meta?.select("dd.warning a.tag")?.map { it.text() } ?: emptyList()
        val categories = meta?.select("dd.category a.tag")?.map { it.text() } ?: emptyList()
        val fandoms = meta?.select("dd.fandom a.tag")?.map { it.text() } ?: emptyList()
        val relationships = meta?.select("dd.relationship a.tag")?.map { it.text() } ?: emptyList()
        val characters = meta?.select("dd.character a.tag")?.map { it.text() } ?: emptyList()
        val freeforms = meta?.select("dd.freeform a.tag")?.map { it.text() } ?: emptyList()
        val language = meta?.selectFirst("dd.language")?.text()?.trim() ?: "English"

        val stats = meta?.selectFirst("dl.stats")
        val wordCount = parseInt(stats?.selectFirst("dd.words")?.text() ?: "0")
        val kudos = parseInt(stats?.selectFirst("dd.kudos")?.text() ?: "0")
        val hits = parseInt(stats?.selectFirst("dd.hits")?.text() ?: "0")

        val (chapterCount, totalChapters) = parseChapterFraction(stats?.selectFirst("dd.chapters")?.text() ?: "1/1")
        val isComplete = totalChapters != null && chapterCount == totalChapters

        val summary = doc.selectFirst("#workskin .summary blockquote.userstuff, .summary blockquote.userstuff")?.html() ?: ""
        val chapters = parseChapters(doc)

        val published = parseAO3Date(stats?.selectFirst("dd.published")?.text() ?: "")
        val updatedAt = parseAO3Date(stats?.selectFirst("dd.status")?.text() ?: "") ?: published

        val summaryStruct = WorkSummary(
            id = workId,
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
        return WorkPayload(summary = summaryStruct, chapters = chapters)
    }

    /** Lightweight metadata-only parse (chapter counts + last update) for the poller. */
    fun parseMetadata(html: String, workId: Int): WorkMetadata {
        val doc = Jsoup.parse(html)
        val stats = doc.selectFirst("dl.work.meta.group dl.stats")
        val (chapterCount, totalChapters) = parseChapterFraction(stats?.selectFirst("dd.chapters")?.text() ?: "1/1")
        val updatedAt = parseAO3Date(stats?.selectFirst("dd.status")?.text() ?: "")
            ?: parseAO3Date(stats?.selectFirst("dd.published")?.text() ?: "")
        return WorkMetadata(workId, chapterCount, totalChapters, updatedAt)
    }

    private fun parseAuthor(doc: Document): String {
        doc.selectFirst("h3.byline")?.let { byline ->
            val linkTexts = byline.select("a").map { it.text() }.filter { it.isNotEmpty() }
            if (linkTexts.isNotEmpty()) return linkTexts.joinToString(", ")
            val txt = byline.text().trim()
            if (txt.isNotEmpty()) {
                return if (txt.lowercase().startsWith("by ")) txt.drop(3).trim() else txt
            }
        }
        doc.selectFirst("dl.work.meta dd.creator a, dl.work.meta dd.creator")?.text()?.trim()?.let {
            if (it.isNotEmpty()) return it
        }
        return "Anonymous"
    }

    private fun parseChapters(doc: Document): List<ChapterPayload> {
        val orderedIds = chapterIndexIds(doc)
        fun idAt(index: Int): Int? = orderedIds.getOrNull(index)

        val nested = doc.select("div.chapter[id^=chapter-]")
        if (nested.isNotEmpty()) {
            return nested.mapIndexed { index, div ->
                val rawTitle = div.selectFirst("h3.title")?.text() ?: ""
                val body = div.selectFirst("div.userstuff")?.html() ?: ""
                ChapterPayload(index + 1, cleanChapterTitle(rawTitle, index + 1), body, chapterAoId(div) ?: idAt(index))
            }
        }

        val workskin = doc.select("#workskin > div.chapter, #workskin div[role=article]")
        if (workskin.isNotEmpty()) {
            return workskin.mapIndexed { index, div ->
                val rawTitle = div.selectFirst("h3.title, h2.title")?.text() ?: ""
                val body = div.selectFirst("div.userstuff")?.html() ?: ""
                ChapterPayload(index + 1, cleanChapterTitle(rawTitle, index + 1), body, chapterAoId(div) ?: idAt(index))
            }
        }

        doc.selectFirst("#workskin .userstuff, div#chapters div.userstuff, div#chapters")?.let {
            return listOf(ChapterPayload(1, "", it.html(), idAt(0)))
        }
        return emptyList()
    }

    private fun chapterAoId(div: Element): Int? {
        div.selectFirst("h3.title a[href], h3.landmark.heading a[href]")?.attr("href")
            ?.let { chapterId(it) }?.let { return it }
        div.selectFirst("a[href*=/chapters/]")?.attr("href")?.let { chapterId(it) }?.let { return it }
        return null
    }

    private fun chapterIndexIds(doc: Document): List<Int> {
        doc.select("select#selected_id option").mapNotNull { it.attr("value").trim().toIntOrNull() }
            .takeIf { it.isNotEmpty() }?.let { return it }
        doc.select("#chapter_index a[href*=/chapters/], ol.chapter.index a[href*=/chapters/]")
            .mapNotNull { chapterId(it.attr("href")) }.takeIf { it.isNotEmpty() }?.let { return it }
        return emptyList()
    }

    /** Extracts `123` from a `/works/9/chapters/123` href. */
    fun chapterId(href: String): Int? =
        Regex("/chapters/(\\d+)").find(href)?.groupValues?.get(1)?.toIntOrNull()

    /** Strip AO3's "Chapter N: " prefix; a bare "Chapter N" means no real title. */
    fun cleanChapterTitle(raw: String, index: Int): String {
        var t = raw.trim()
        Regex("^Chapter\\s+\\d+\\s*:?\\s*").find(t)?.let { t = t.substring(it.range.last + 1).trim() }
        if (Regex("^Chapter\\s+\\d+$").matches(t)) return ""
        return t
    }

    private fun firstNonEmptyText(doc: Document, selectors: List<String>): String {
        for (sel in selectors) {
            val text = doc.selectFirst(sel)?.text()?.trim()
            if (!text.isNullOrEmpty()) return text
        }
        return ""
    }

    private fun parseInt(s: String) = s.replace(",", "").trim().toIntOrNull() ?: 0

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
        return runCatching { SimpleDateFormat("yyyy-MM-dd", Locale.US).parse(trimmed)?.time }.getOrNull()
    }
}
