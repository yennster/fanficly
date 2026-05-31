import Foundation

/// Resolves user-typed tags to AO3's canonical names via AO3's autocomplete
/// endpoint, so a search matches the same works whether it comes from the
/// Search tab or the Browse filters. e.g. "Draco/Hermione" →
/// "Hermione Granger/Draco Malfoy".
enum TagResolver {
    static func resolve(_ filters: AO3SearchFilters, using client: any AO3ClientProtocol) async -> AO3SearchFilters {
        var resolved = filters
        resolved.relationshipNames = await resolveList(filters.relationshipNames, field: .relationship, client: client)
        resolved.characterNames    = await resolveList(filters.characterNames,    field: .character,    client: client)
        resolved.freeformNames     = await resolveList(filters.freeformNames,     field: .freeform,     client: client)
        resolved.fandomNames       = await resolveList(filters.fandomNames,       field: .fandom,       client: client)
        return resolved
    }

    private static func resolveList(_ terms: [String], field: AO3AutocompleteField, client: any AO3ClientProtocol) async -> [String] {
        var out: [String] = []
        for term in terms {
            out.append(await resolveOne(term, field: field, client: client))
        }
        return out
    }

    private static func resolveOne(_ term: String, field: AO3AutocompleteField, client: any AO3ClientProtocol) async -> String {
        // Try the term as typed, then a few fallbacks — AO3's autocomplete
        // is picky about slashes/order in ship names ("hermione/draco" may
        // need to be "hermione draco" to match "Hermione Granger/Draco Malfoy").
        for candidate in candidates(for: term, field: field) {
            if let matches = try? await client.autocomplete(field: field, term: candidate),
               let best = bestMatch(for: term, in: matches) {
                return best
            }
        }
        return term
    }

    private static func candidates(for term: String, field: AO3AutocompleteField) -> [String] {
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
    private static func bestMatch(for term: String, in matches: [String]) -> String? {
        guard !matches.isEmpty else { return nil }
        if let exact = matches.first(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) {
            return exact
        }
        return matches.first
    }
}
