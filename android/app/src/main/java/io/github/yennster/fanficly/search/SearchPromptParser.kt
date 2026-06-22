package io.github.yennster.fanficly.search

import io.github.yennster.fanficly.model.AO3SearchFilters

/**
 * Rules-based natural-language search parser — the Kotlin port of the iOS
 * `SearchPromptParser`. Turns a free-text prompt like
 * `edward/bella romance all human complete` into a structured
 * [AO3SearchFilters]. Each extractor consumes the substring it recognizes from
 * a mutable working copy of the prompt; whatever is left over becomes the
 * free-text `query`.
 *
 * The logic mirrors the iOS implementation one-to-one, including extractor
 * order (which is significant — e.g. word-count and status are pulled before
 * the leftover words could be mistaken for freeform tags). Keep the two in
 * sync; the shared `SearchPromptParserTests` cases are ported verbatim.
 */
class SearchPromptParser {

    fun parse(prompt: String): AO3SearchFilters {
        val filters = AO3SearchFilters()

        val normalized = prompt
            .replace('“', '"').replace('”', '"')   // “ ” → "
            .replace('‘', '\'').replace('’', '\'') // ‘ ’ → '

        val working = StringBuilder(normalized.lowercase())
        val cased = StringBuilder(normalized)

        extractTitle(working, cased, filters)
        extractCreators(working, cased, filters)
        extractExclusions(working, filters)
        extractQuoted(working, filters)
        extractShips(working, filters)
        extractWordCount(working, filters)
        extractEngagement(working, filters)
        extractStatus(working, filters)
        extractCrossover(working, filters)
        extractLanguage(working, filters)
        extractCategories(working, filters)
        extractRatings(working, filters)
        extractWarnings(working, filters)
        extractFandoms(working, filters)
        extractFreeformTags(working, filters)

        val remainder = collapseWhitespace(working.toString())
        if (remainder.isNotEmpty()) filters.query = remainder
        return filters
    }

    // MARK: - Field extractors (title / creators read the case-preserved copy)

    private fun extractTitle(working: StringBuilder, cased: StringBuilder, filters: AO3SearchFilters) {
        val patterns = listOf(
            "title:\\s*\"([^\"]+)\"",
            "title:\\s*([^\\s]+)",
        )
        extractField(working, cased, patterns) { filters.title = it }
    }

    private fun extractCreators(working: StringBuilder, cased: StringBuilder, filters: AO3SearchFilters) {
        val patterns = listOf(
            "\\b(?:author|creator|creators|by):\\s*\"([^\"]+)\"",
            "\\b(?:author|creator|creators|by):\\s*([^\\s]+)",
        )
        extractField(working, cased, patterns) { filters.creators = it }
    }

    /** Reads group 1 from the case-preserved copy, deletes the full match from both. */
    private fun extractField(
        working: StringBuilder,
        cased: StringBuilder,
        patterns: List<String>,
        assign: (String) -> Unit,
    ) {
        for (pattern in patterns) {
            val regex = Regex(pattern, RegexOption.IGNORE_CASE)
            for (m in regex.findAll(working.toString()).toList().asReversed()) {
                val g = m.groups[1]
                if (g != null) {
                    val value = cased.substring(g.range.first, g.range.last + 1).trim()
                    if (value.isNotEmpty()) assign(value)
                }
                working.delete(m.range.first, m.range.last + 1)
                cased.delete(m.range.first, m.range.last + 1)
            }
        }
    }

    private fun extractExclusions(working: StringBuilder, filters: AO3SearchFilters) {
        val patterns = listOf(
            "(?:^|\\s)-\"([^\"]+)\"",
            """(?:^|\s)-([a-z0-9][a-z0-9'\-]*)\b""",
            "(?:^|\\s)not\\s+\"([^\"]+)\"",
            """(?:^|\s)not\s+([a-z0-9][a-z0-9'\-]*)\b""",
        )
        for (pattern in patterns) {
            val regex = Regex(pattern)
            for (m in regex.findAll(working.toString()).toList().asReversed()) {
                val term = m.groupValues[1].trim()
                if (term.isNotEmpty()) filters.excludedFreeforms = filters.excludedFreeforms + term
                working.delete(m.range.first, m.range.last + 1)
            }
        }
    }

    /**
     * Pulls out double-quoted phrases as exact tags before the ship regex can
     * mangle them — so `"Hermione Granger/Draco Malfoy"` stays one relationship
     * instead of the ship matcher grabbing "granger/draco". A quoted phrase with
     * a slash is a relationship; otherwise it's a freeform tag.
     */
    private fun extractQuoted(working: StringBuilder, filters: AO3SearchFilters) {
        val regex = Regex("\"([^\"]+)\"")
        for (m in regex.findAll(working.toString()).toList().asReversed()) {
            val phrase = m.groupValues[1].trim()
            if (phrase.isNotEmpty()) {
                if (phrase.contains("/")) {
                    filters.relationshipNames = filters.relationshipNames + capitalizedWords(phrase)
                } else {
                    filters.freeformNames = filters.freeformNames + capitalizedWords(phrase)
                }
            }
            working.delete(m.range.first, m.range.last + 1)
        }
    }

    private fun extractShips(working: StringBuilder, filters: AO3SearchFilters) {
        val regex = Regex("""(?<![\w/])([a-z][a-z'\-]+)/([a-z][a-z'\-]+)(?![\w/])""")
        for (m in regex.findAll(working.toString()).toList().asReversed()) {
            val left = m.groupValues[1]
            val right = m.groupValues[2]
            val category = KnownTags.categoryAliases["$left/$right"]
            if (category != null) {
                filters.categories = filters.categories + category
            } else {
                filters.relationshipNames =
                    filters.relationshipNames + "${capitalizedWords(left)}/${capitalizedWords(right)}"
            }
            working.delete(m.range.first, m.range.last + 1)
        }
    }

    private class WordCountPattern(val regex: Regex, val render: (Int, Int?) -> String)

    private val wordCountPatterns: List<WordCountPattern> = run {
        val k = "(?:k|,000)"
        listOf(
            WordCountPattern(Regex("""under\s+(\d+)\s*$k?""")) { n, _ -> "<$n" },
            WordCountPattern(Regex("""over\s+(\d+)\s*$k?""")) { n, _ -> ">$n" },
            WordCountPattern(Regex("""more than\s+(\d+)\s*$k?""")) { n, _ -> ">$n" },
            WordCountPattern(Regex("""less than\s+(\d+)\s*$k?""")) { n, _ -> "<$n" },
            WordCountPattern(Regex("""between\s+(\d+)\s*$k?\s+and\s+(\d+)\s*$k?""")) { lo, hi ->
                if (hi != null) "$lo-$hi" else "$lo"
            },
        )
    }

    private fun extractWordCount(working: StringBuilder, filters: AO3SearchFilters) {
        for (pattern in wordCountPatterns) {
            for (m in pattern.regex.findAll(working.toString()).toList().asReversed()) {
                val full = m.value
                val raw1 = m.groupValues[1]
                val hadK = full.contains("k") || full.contains(",000")
                val n1 = (raw1.toIntOrNull() ?: 0) * (if (hadK) 1_000 else 1)
                var n2: Int? = null
                if (m.groups.size > 2 && m.groups[2] != null) {
                    val raw2 = m.groupValues[2]
                    val hadK2 = full.contains(raw2 + "k") || full.contains(raw2 + ",000")
                    n2 = (raw2.toIntOrNull() ?: 0) * (if (hadK2) 1_000 else 1)
                }
                filters.wordCount = pattern.render(n1, n2)
                working.delete(m.range.first, m.range.last + 1)
            }
        }
    }

    private fun extractEngagement(working: StringBuilder, filters: AO3SearchFilters) {
        if (removeFirst(working, """\bpopular\b""")) filters.kudosCount = ">1000"
        if (removeFirst(working, """\bmost kudos\b""")) {
            filters.sortColumn = AO3SearchFilters.SortColumn.KUDOS_COUNT
            filters.sortDirection = AO3SearchFilters.SortDirection.DESC
        }
        if (removeFirst(working, """\bmost hits\b""")) {
            filters.sortColumn = AO3SearchFilters.SortColumn.HITS
            filters.sortDirection = AO3SearchFilters.SortDirection.DESC
        }
        if (removeFirst(working, """\brecently updated\b""")) {
            filters.sortColumn = AO3SearchFilters.SortColumn.REVISED_AT
            filters.sortDirection = AO3SearchFilters.SortDirection.DESC
        }
        if (removeFirst(working, """\bnewest\b|\brecent\b""")) {
            filters.sortColumn = AO3SearchFilters.SortColumn.CREATED_AT
            filters.sortDirection = AO3SearchFilters.SortDirection.DESC
        }
    }

    private fun extractStatus(working: StringBuilder, filters: AO3SearchFilters) {
        if (removeFirst(working, """\boneshot\b|\bone\s*-?\s*shot\b|\bone shot\b""")) filters.singleChapter = true
        if (removeFirst(working, """\bcomplete\b|\bcompleted\b|\bfinished\b""")) filters.complete = AO3SearchFilters.TriState.YES
        if (removeFirst(working, """\bwip\b|\bwork in progress\b|\bin progress\b|\bunfinished\b""")) filters.complete = AO3SearchFilters.TriState.NO
    }

    private fun extractCrossover(working: StringBuilder, filters: AO3SearchFilters) {
        if (removeFirst(working, """\bno\s+crossovers?\b""")) {
            filters.crossover = AO3SearchFilters.TriState.NO
        } else if (removeFirst(working, """\bcrossovers?\b""")) {
            filters.crossover = AO3SearchFilters.TriState.YES
        }
    }

    private fun extractLanguage(working: StringBuilder, filters: AO3SearchFilters) {
        for ((alias, code) in KnownTags.languageAliases) {
            if (removeFirst(working, """\b${Regex.escape(alias)}\b""")) {
                filters.languageId = code
                return
            }
        }
    }

    private fun extractCategories(working: StringBuilder, filters: AO3SearchFilters) {
        for ((alias, category) in KnownTags.categoryAliases) {
            if (removeFirst(working, """(?<![\w/])${Regex.escape(alias)}(?![\w/])""")) {
                filters.categories = filters.categories + category
            }
        }
    }

    private fun extractRatings(working: StringBuilder, filters: AO3SearchFilters) {
        for (alias in KnownTags.ratingAliases.keys.sortedByDescending { it.length }) {
            val rating = KnownTags.ratingAliases[alias] ?: continue
            val escaped = Regex.escape(alias)
            val pattern = if (alias.length == 1) """\b$escaped-rated\b""" else """\b$escaped\b"""
            if (removeFirst(working, pattern)) filters.ratings = filters.ratings + rating
        }
    }

    private fun extractWarnings(working: StringBuilder, filters: AO3SearchFilters) {
        for (alias in KnownTags.warningAliases.keys.sortedByDescending { it.length }) {
            val warning = KnownTags.warningAliases[alias] ?: continue
            if (removeFirst(working, """\b${Regex.escape(alias)}\b""")) filters.warnings = filters.warnings + warning
        }
    }

    private fun extractFreeformTags(working: StringBuilder, filters: AO3SearchFilters) {
        for (tag in KnownTags.freeformTags.sortedByDescending { it.length }) {
            if (removeFirst(working, """\b${Regex.escape(tag)}\b""")) {
                filters.freeformNames = filters.freeformNames + canonicalize(tag)
            }
        }
    }

    private fun extractFandoms(working: StringBuilder, filters: AO3SearchFilters) {
        for (alias in KnownTags.fandomAliases.keys.sortedByDescending { it.length }) {
            val canonical = KnownTags.fandomAliases[alias] ?: continue
            if (removeFirst(working, """\b${Regex.escape(alias)}\b""")) {
                if (!filters.fandomNames.contains(canonical)) filters.fandomNames = filters.fandomNames + canonical
            }
        }
    }

    // MARK: - Helpers

    /** Title-cases a freeform tag while keeping short joining words lowercase. */
    private fun canonicalize(tag: String): String =
        tag.split(" ").joinToString(" ") { word ->
            val lower = word.lowercase()
            when {
                word.isEmpty() -> word
                lower == "of" || lower == "and" || lower == "the" || lower == "to" || lower == "a" -> lower
                else -> word.substring(0, 1).uppercase() + word.substring(1).lowercase()
            }
        }

    /**
     * Swift `String.capitalized` equivalent: capitalize the first letter of each
     * word and lowercase the rest, using Unicode word breaking. Spaces and `/`
     * start a new word, but a mid-word apostrophe (between two letters) does
     * NOT — so `coffee shop au` → `Coffee Shop Au`, `draco/hermione` →
     * `Draco/Hermione`, and `don't tell` → `Don't Tell` (not `Don'T Tell`),
     * matching the iOS parser exactly.
     */
    private fun capitalizedWords(s: String): String {
        val sb = StringBuilder(s.length)
        var atWordStart = true
        for (i in s.indices) {
            val ch = s[i]
            if (ch.isLetter()) {
                sb.append(if (atWordStart) ch.uppercaseChar() else ch.lowercaseChar())
                atWordStart = false
            } else {
                sb.append(ch)
                val midWordApostrophe = ch == '\'' &&
                    i > 0 && s[i - 1].isLetter() &&
                    i + 1 < s.length && s[i + 1].isLetter()
                if (!midWordApostrophe) atWordStart = true
            }
        }
        return sb.toString()
    }

    /** Deletes the first match of [pattern] from [working]; true if one was removed. */
    private fun removeFirst(working: StringBuilder, pattern: String): Boolean {
        val m = Regex(pattern).find(working) ?: return false
        working.delete(m.range.first, m.range.last + 1)
        return true
    }

    private fun collapseWhitespace(s: String): String =
        s.replace(Regex("""\s+"""), " ").trim()
}
