package io.github.yennster.fanficly.net.parse

import io.github.yennster.fanficly.model.BrowseFandom
import org.jsoup.Jsoup
import java.text.Collator
import java.util.Locale

/**
 * Parses AO3's `/media/<category>/fandoms` page into a list of [BrowseFandom]
 * with work counts — the Kotlin port of iOS `MediaCategoryParser`. Each fandom
 * is an `<a href="/tags/<tag>/works">Name</a> (123456)`; the count is read from
 * the enclosing element's text so the Popular tab can rank by it.
 */
object MediaCategoryParser {

    // Locale-aware, case-insensitive collation (accents fold near their base
    // letter), matching iOS `localizedCaseInsensitiveCompare`.
    private val collator: Collator = Collator.getInstance(Locale.US).apply { strength = Collator.SECONDARY }

    fun parse(html: String): List<BrowseFandom> {
        val doc = Jsoup.parse(html)
        val seen = HashSet<String>()
        val results = mutableListOf<BrowseFandom>()

        for (link in doc.select("a[href^=/tags/]")) {
            val href = link.attr("href")
            if (!href.endsWith("/works")) continue
            val raw = link.text().trim()
            if (raw.isEmpty()) continue

            val canonical = canonicalizeFandomName(raw)
            val containerText = link.parent()?.text() ?: raw
            val count = trailingCount(containerText)
            if (seen.add(canonical)) {
                results += BrowseFandom(canonical, canonicalName = canonical, workCount = count)
            }
        }
        return results.sortedWith(compareBy(collator) { it.canonicalName })
    }

    /** The number inside the trailing `(…)` of a fandom line, e.g. "… (123,456)" → 123456. */
    fun trailingCount(text: String): Int? {
        val open = text.lastIndexOf('(')
        if (open < 0) return null
        val close = text.indexOf(')', open)
        if (close < 0) return null
        val digits = text.substring(open + 1, close).filter { it.isDigit() }
        return digits.toIntOrNull()
    }

    private fun canonicalizeFandomName(s: String): String =
        s.replace(' ', ' ').replace(Regex("\\s+"), " ").trim()
}
