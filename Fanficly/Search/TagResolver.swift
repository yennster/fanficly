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
            if let matches = try? await client.autocomplete(field: field, term: term),
               let best = bestMatch(for: term, in: matches) {
                out.append(best)
            } else {
                out.append(term)
            }
        }
        return out
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
