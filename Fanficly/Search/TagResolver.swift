import Foundation

/// Resolves user-typed tags to AO3's canonical names via AO3's autocomplete
/// endpoint, so a search matches the same works whether it comes from the
/// Search tab or the Browse filters. e.g. "Draco/Hermione" →
/// "Hermione Granger/Draco Malfoy".
/// Process-lifetime memo of `term → canonical` so re-applying the same filters
/// (or sharing a tag across Search and Browse) doesn't re-hit AO3's throttled
/// autocomplete. Canonical tag names are stable, so this never goes stale.
private actor ResolutionCache {
    static let shared = ResolutionCache()
    private var store: [String: String] = [:]
    func value(for key: String) -> String? { store[key] }
    func set(_ value: String, for key: String) { store[key] = value }
    func clear() { store.removeAll() }
}

enum TagResolver {
    /// - Parameter resolveFandoms: Browse passes `false` — its fandom is picked
    ///   from AO3's own fandom list and is already canonical, so resolving it is
    ///   a wasted round-trip (and risks matching a different fandom).
    static func resolve(
        _ filters: AO3SearchFilters,
        using client: any AO3ClientProtocol,
        resolveFandoms: Bool = true
    ) async -> AO3SearchFilters {
        var resolved = filters
        resolved.relationshipNames = await resolveList(filters.relationshipNames, field: .relationship, client: client)
        resolved.characterNames    = await resolveList(filters.characterNames,    field: .character,    client: client)
        resolved.freeformNames     = await resolveList(filters.freeformNames,     field: .freeform,     client: client)
        if resolveFandoms {
            resolved.fandomNames   = await resolveList(filters.fandomNames,       field: .fandom,       client: client)
        }
        return resolved
    }

    /// Clears the process-lifetime resolution cache. For tests, so a memoized
    /// result from one case can't bleed into another.
    static func clearCacheForTesting() async {
        await ResolutionCache.shared.clear()
    }

    private static func resolveList(_ terms: [String], field: AO3AutocompleteField, client: any AO3ClientProtocol) async -> [String] {
        var out: [String] = []
        for term in terms {
            out.append(await resolveOne(term, field: field, client: client))
        }
        return out
    }

    private static func resolveOne(_ term: String, field: AO3AutocompleteField, client: any AO3ClientProtocol) async -> String {
        let cacheKey = "\(field.rawValue)|\(term.lowercased())"
        if let cached = await ResolutionCache.shared.value(for: cacheKey) {
            return cached
        }
        let result = await resolveUncached(term, field: field, client: client)
        await ResolutionCache.shared.set(result, for: cacheKey)
        return result
    }

    private static func resolveUncached(_ term: String, field: AO3AutocompleteField, client: any AO3ClientProtocol) async -> String {
        // Try the term as typed, then a few simple fallbacks.
        for candidate in candidates(for: term, field: field) {
            if let matches = try? await client.autocomplete(field: field, term: candidate),
               let best = bestMatch(for: term, in: matches, field: field) {
                return best
            }
        }
        // Relationship couldn't be matched directly (AO3's autocomplete needs
        // the canonical full names, e.g. "Hermione Granger/Draco Malfoy", not
        // "hermione/draco"). Resolve each side to a canonical character, then
        // look up the ship.
        if field == .relationship, term.contains("/") {
            let parts = term.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                let a = await resolveOne(parts[0], field: .character, client: client)
                let b = await resolveOne(parts[1], field: .character, client: client)
                // Try the ship in both orders / separators.
                for query in ["\(a)/\(b)", "\(a) \(b)", "\(b)/\(a)", "\(b) \(a)"] {
                    if let matches = try? await client.autocomplete(field: .relationship, term: query),
                       let best = bestMatch(for: "\(a)/\(b)", in: matches, field: .relationship) {
                        return best
                    }
                }
                // Last resort: construct it from the resolved names.
                if a != parts[0] || b != parts[1] { return "\(a)/\(b)" }
            }
        }
        return term
    }

    static func candidates(for term: String, field: AO3AutocompleteField) -> [String] {
        var list = [term]
        if field == .relationship, term.contains("/") {
            let spaced = term.replacingOccurrences(of: "/", with: " ")
            list.append(spaced)
            // Also try the reversed order ("draco hermione").
            let parts = term.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                list.append("\(parts[1]) \(parts[0])")
            }
        }
        return list
    }

    /// Prefer a case-insensitive exact match, else the top suggestion,
    /// else keep the original term.
    static func bestMatch(for term: String, in matches: [String], field: AO3AutocompleteField = .freeform) -> String? {
        guard !matches.isEmpty else { return nil }
        if let exact = matches.first(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            return exact
        }
        if field == .relationship, term.contains("/") {
            return bestRelationshipMatch(for: term, in: matches) ?? matches.first
        }
        if field == .freeform {
            return bestFreeformMatch(for: term, in: matches)
        }
        return matches.first
    }

    /// Freeform (additional) tags are user-authored descriptors, and AO3's
    /// autocomplete ranks suggestions by popularity — so a plain tag like
    /// "Caveman" gets outranked by a more specific compound tag that merely
    /// contains it ("Caveman Derek Hale"). Blindly taking the top suggestion
    /// therefore silently rewrites the user's tag into a different, narrower one.
    /// Only accept a suggestion that is the *same* tag up to case / spacing /
    /// punctuation (so we still canonicalize e.g. "hurt comfort" → "Hurt/Comfort"
    /// or fix casing); otherwise keep exactly what the user typed.
    private static func bestFreeformMatch(for term: String, in matches: [String]) -> String {
        let typed = normalizedTag(term)
        return matches.first(where: { normalizedTag($0) == typed }) ?? term
    }

    /// Lowercased, alphanumerics only — collapses case, whitespace and
    /// punctuation differences so superficial formatting variants compare equal.
    private static func normalizedTag(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Score each candidate ship against the typed term. Penalize candidates
    /// whose `/`-arity doesn't match (a 2-person query shouldn't resolve to a
    /// 3+person ship), and reward candidates where each typed side appears as a
    /// whole word in the corresponding side of the candidate.
    /// e.g. "Bella/Edward" → prefer "Bella Swan/Edward Cullen" over
    /// "Oswald Cobblepot/Isabella/Edward Nygma" (3 parts; "Bella" only matches
    /// inside "Isabella").
    private static func bestRelationshipMatch(for term: String, in matches: [String]) -> String? {
        let typed = term.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard typed.count >= 2 else { return nil }
        var best: (score: Int, value: String)?
        for candidate in matches {
            let parts = candidate.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            var score = 0
            if parts.count == typed.count { score += 10 }
            else { score -= 5 * abs(parts.count - typed.count) }
            // Each typed side should be a whole-word match in *some* part.
            // Slightly prefer same-order alignment.
            for (i, side) in typed.enumerated() {
                if i < parts.count, containsWholeWord(side, in: parts[i].lowercased()) {
                    score += 3
                } else if parts.contains(where: { containsWholeWord(side, in: $0.lowercased()) }) {
                    score += 2
                } else {
                    score -= 2
                }
            }
            if best == nil || score > best!.score {
                best = (score, candidate)
            }
        }
        return best?.value
    }

    private static func containsWholeWord(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty else { return false }
        let tokens = haystack.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return tokens.contains(needle)
    }
}
