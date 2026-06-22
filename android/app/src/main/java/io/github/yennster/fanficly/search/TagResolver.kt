package io.github.yennster.fanficly.search

import io.github.yennster.fanficly.model.AO3SearchFilters
import io.github.yennster.fanficly.model.AutocompleteField
import io.github.yennster.fanficly.net.AO3Client
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * Resolves user-typed tags to AO3's canonical names via AO3's autocomplete
 * endpoint, so a search matches the same works whether it comes from the smart
 * search box or the (eventual) Browse filters — e.g. `Draco/Hermione` →
 * `Hermione Granger/Draco Malfoy`. The Kotlin port of the iOS `TagResolver`.
 *
 * Results are memoized for the process lifetime (canonical names are stable, so
 * this never goes stale) to avoid re-hitting the throttled autocomplete when the
 * same tag is searched again.
 */
object TagResolver {

    private val cache = HashMap<String, String>()
    private val cacheLock = Mutex()

    /**
     * @param resolveFandoms pass `false` when the fandom came from AO3's own
     *   fandom list and is already canonical (resolving it is a wasted round-trip
     *   and risks matching a different fandom).
     */
    suspend fun resolve(
        filters: AO3SearchFilters,
        client: AO3Client,
        resolveFandoms: Boolean = true,
    ): AO3SearchFilters {
        val resolved = filters.copy()
        resolved.relationshipNames = resolveList(filters.relationshipNames, AutocompleteField.RELATIONSHIP, client)
        resolved.characterNames = resolveList(filters.characterNames, AutocompleteField.CHARACTER, client)
        resolved.freeformNames = resolveList(filters.freeformNames, AutocompleteField.FREEFORM, client)
        if (resolveFandoms) {
            resolved.fandomNames = resolveList(filters.fandomNames, AutocompleteField.FANDOM, client)
        }
        return resolved
    }

    /** Clears the process-lifetime resolution cache (for tests). */
    suspend fun clearCacheForTesting() {
        cacheLock.withLock { cache.clear() }
    }

    private suspend fun resolveList(
        terms: List<String>,
        field: AutocompleteField,
        client: AO3Client,
    ): List<String> = terms.map { resolveOne(it, field, client) }

    private suspend fun resolveOne(term: String, field: AutocompleteField, client: AO3Client): String {
        val key = "${field.path}|${term.lowercase()}"
        cacheLock.withLock { cache[key] }?.let { return it }
        val result = resolveUncached(term, field, client)
        cacheLock.withLock { cache[key] = result }
        return result
    }

    private suspend fun resolveUncached(term: String, field: AutocompleteField, client: AO3Client): String {
        // Try the term as typed, then a few simple fallbacks.
        for (candidate in candidates(term, field)) {
            val matches = runCatching { client.autocomplete(field, candidate) }.getOrNull()
            if (matches != null) {
                bestMatch(term, matches, field)?.let { return it }
            }
        }
        // A relationship couldn't be matched directly (AO3's autocomplete needs
        // the canonical full names, e.g. "Hermione Granger/Draco Malfoy", not
        // "hermione/draco"). Resolve each side to a canonical character, then
        // look up the ship.
        if (field == AutocompleteField.RELATIONSHIP && term.contains("/")) {
            val parts = term.split("/").map { it.trim() }
            if (parts.size == 2) {
                val a = resolveOne(parts[0], AutocompleteField.CHARACTER, client)
                val b = resolveOne(parts[1], AutocompleteField.CHARACTER, client)
                for (query in listOf("$a/$b", "$a $b", "$b/$a", "$b $a")) {
                    val matches = runCatching { client.autocomplete(AutocompleteField.RELATIONSHIP, query) }.getOrNull()
                    if (matches != null) {
                        bestMatch("$a/$b", matches, AutocompleteField.RELATIONSHIP)?.let { return it }
                    }
                }
                // Last resort: construct it from the resolved names.
                if (a != parts[0] || b != parts[1]) return "$a/$b"
            }
        }
        return term
    }

    /** Visible for testing. */
    fun candidates(term: String, field: AutocompleteField): List<String> {
        val list = mutableListOf(term)
        if (field == AutocompleteField.RELATIONSHIP && term.contains("/")) {
            list += term.replace("/", " ")
            val parts = term.split("/").map { it.trim() }
            if (parts.size == 2) list += "${parts[1]} ${parts[0]}"
        }
        return list
    }

    /**
     * Prefer a case-insensitive exact match, else the best-scored ship (for
     * relationships), else the top suggestion. Visible for testing.
     */
    fun bestMatch(term: String, matches: List<String>, field: AutocompleteField = AutocompleteField.FREEFORM): String? {
        if (matches.isEmpty()) return null
        matches.firstOrNull { it.equals(term, ignoreCase = true) }?.let { return it }
        if (field == AutocompleteField.RELATIONSHIP && term.contains("/")) {
            return bestRelationshipMatch(term, matches) ?: matches.first()
        }
        return matches.first()
    }

    /**
     * Score each candidate ship against the typed term. Penalize candidates whose
     * `/`-arity doesn't match (a 2-person query shouldn't resolve to a 3+person
     * ship), and reward candidates where each typed side appears as a whole word
     * in the corresponding side of the candidate.
     */
    private fun bestRelationshipMatch(term: String, matches: List<String>): String? {
        val typed = term.split("/").map { it.trim().lowercase() }
        if (typed.size < 2) return null
        var best: Pair<Int, String>? = null
        for (candidate in matches) {
            val parts = candidate.split("/").map { it.trim() }
            var score = 0
            if (parts.size == typed.size) score += 10 else score -= 5 * kotlin.math.abs(parts.size - typed.size)
            for ((i, side) in typed.withIndex()) {
                if (i < parts.size && containsWholeWord(side, parts[i].lowercase())) {
                    score += 3
                } else if (parts.any { containsWholeWord(side, it.lowercase()) }) {
                    score += 2
                } else {
                    score -= 2
                }
            }
            if (best == null || score > best.first) best = score to candidate
        }
        return best?.second
    }

    private fun containsWholeWord(needle: String, haystack: String): Boolean {
        if (needle.isEmpty()) return false
        val tokens = haystack.split(Regex("[^\\p{L}\\p{N}]+")).filter { it.isNotEmpty() }
        return tokens.contains(needle)
    }
}
