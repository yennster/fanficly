using System.Text;

namespace Fanficly.Core;

/// <summary>
/// Resolves user-typed tags to AO3's canonical names via AO3's autocomplete
/// endpoint, so a search matches the same works whether it comes from the Search
/// tab or the Browse filters. e.g. "Draco/Hermione" → "Hermione Granger/Draco Malfoy".
///
/// A process-lifetime memo of <c>term → canonical</c> means re-applying the same
/// filters (or sharing a tag across Search and Browse) doesn't re-hit AO3's
/// throttled autocomplete. Canonical tag names are stable, so it never goes stale.
/// Only authoritative answers are memoized — see <see cref="ResolveOneAsync"/>.
/// </summary>
public static class TagResolver
{
    private static readonly Lock CacheGate = new();
    private static readonly Dictionary<string, string> Cache = new(StringComparer.Ordinal);

    /// <param name="resolveFandoms">Browse passes false — its fandom is picked from
    /// AO3's own fandom list and is already canonical, so resolving it is a wasted
    /// round-trip (and risks matching a different fandom).</param>
    public static async Task<AO3SearchFilters> ResolveAsync(
        AO3SearchFilters filters, IAO3Client client, bool resolveFandoms = true, CancellationToken ct = default)
    {
        var resolved = filters.Clone();
        resolved.RelationshipNames = await ResolveListAsync(filters.RelationshipNames, AO3AutocompleteField.Relationship, client, ct);
        resolved.CharacterNames = await ResolveListAsync(filters.CharacterNames, AO3AutocompleteField.Character, client, ct);
        resolved.FreeformNames = await ResolveListAsync(filters.FreeformNames, AO3AutocompleteField.Freeform, client, ct);
        if (resolveFandoms)
            resolved.FandomNames = await ResolveListAsync(filters.FandomNames, AO3AutocompleteField.Fandom, client, ct);
        return resolved;
    }

    /// <summary>Clears the process-lifetime resolution cache. For tests, so a
    /// memoized result from one case can't bleed into another.</summary>
    public static void ClearCacheForTesting()
    {
        lock (CacheGate) Cache.Clear();
    }

    private static async Task<List<string>> ResolveListAsync(
        List<string> terms, AO3AutocompleteField field, IAO3Client client, CancellationToken ct)
    {
        var output = new List<string>();
        foreach (var term in terms) output.Add(await ResolveOneAsync(term, field, client, ct));
        return output;
    }

    private static async Task<string> ResolveOneAsync(string term, AO3AutocompleteField field, IAO3Client client, CancellationToken ct)
    {
        var cacheKey = $"{field.RawValue()}|{term.ToLowerInvariant()}";
        lock (CacheGate)
        {
            if (Cache.TryGetValue(cacheKey, out var cached)) return cached;
        }
        var (value, authoritative) = await ResolveUncachedAsync(term, field, client, ct);
        // Only memoize answers AO3 actually gave. If a lookup failed (offline,
        // 429), caching the raw typed term would pin the unresolved literal for
        // the rest of the session — that tag's searches would silently match
        // nothing even after connectivity recovers.
        if (authoritative)
        {
            lock (CacheGate) Cache[cacheKey] = value;
        }
        return value;
    }

    private static async Task<(string Value, bool Authoritative)> ResolveUncachedAsync(
        string term, AO3AutocompleteField field, IAO3Client client, CancellationToken ct)
    {
        // Authoritative = every lookup we needed got an answer (even an empty
        // one). A thrown autocomplete anywhere makes the result a best-effort
        // fallback that must not be cached.
        var authoritative = true;
        // Try the term as typed, then a few simple fallbacks.
        foreach (var candidate in Candidates(term, field))
        {
            try
            {
                var matches = await client.AutocompleteAsync(field, candidate, ct);
                if (BestMatch(term, matches, field) is { } best) return (best, true);
            }
            catch (Exception e) when (!IsCancellation(e, ct))
            {
                authoritative = false;
            }
        }
        // Relationship couldn't be matched directly (AO3's autocomplete needs the
        // canonical full names, e.g. "Hermione Granger/Draco Malfoy", not
        // "hermione/draco"). Resolve each side to a canonical character, then
        // look up the ship.
        if (field == AO3AutocompleteField.Relationship && term.Contains('/'))
        {
            var parts = SplitSides(term);
            if (parts.Length == 2)
            {
                var a = await ResolveOneAsync(parts[0], AO3AutocompleteField.Character, client, ct);
                var b = await ResolveOneAsync(parts[1], AO3AutocompleteField.Character, client, ct);
                // Try the ship in both orders / separators.
                foreach (var query in new[] { $"{a}/{b}", $"{a} {b}", $"{b}/{a}", $"{b} {a}" })
                {
                    try
                    {
                        var matches = await client.AutocompleteAsync(AO3AutocompleteField.Relationship, query, ct);
                        if (BestMatch($"{a}/{b}", matches, AO3AutocompleteField.Relationship) is { } best) return (best, true);
                    }
                    catch (Exception e) when (!IsCancellation(e, ct))
                    {
                        authoritative = false;
                    }
                }
                // Last resort: construct it from the resolved names.
                if (a != parts[0] || b != parts[1]) return ($"{a}/{b}", authoritative);
            }
        }
        return (term, authoritative);
    }

    /// <summary>Cancelling the caller's token stops resolution (C# convention);
    /// every other failure is a best-effort fallback, as in the Swift app.</summary>
    private static bool IsCancellation(Exception e, CancellationToken ct) =>
        e is OperationCanceledException && ct.IsCancellationRequested;

    private static string[] SplitSides(string term) =>
        term.Split('/', StringSplitOptions.RemoveEmptyEntries).Select(p => p.Trim()).ToArray();

    public static IReadOnlyList<string> Candidates(string term, AO3AutocompleteField field)
    {
        var list = new List<string> { term };
        if (field == AO3AutocompleteField.Relationship && term.Contains('/'))
        {
            list.Add(term.Replace("/", " "));
            // Also try the reversed order ("draco hermione").
            var parts = SplitSides(term);
            if (parts.Length == 2) list.Add($"{parts[1]} {parts[0]}");
        }
        return list;
    }

    /// <summary>Prefer a case-insensitive exact match; then relationships pick the
    /// best-scored ship, freeforms accept only a formatting variant of what was
    /// typed (else keep the typed term), and other fields take the top suggestion.</summary>
    public static string? BestMatch(string term, IReadOnlyList<string> matches, AO3AutocompleteField field = AO3AutocompleteField.Freeform)
    {
        if (matches.Count == 0) return null;
        if (matches.FirstOrDefault(m => string.Equals(m, term, StringComparison.OrdinalIgnoreCase)) is { } exact) return exact;
        if (field == AO3AutocompleteField.Relationship && term.Contains('/'))
            return BestRelationshipMatch(term, matches) ?? matches[0];
        if (field == AO3AutocompleteField.Freeform) return BestFreeformMatch(term, matches);
        return matches[0];
    }

    /// <summary>Freeform (additional) tags are user-authored descriptors, and AO3's
    /// autocomplete ranks suggestions by popularity — so a plain tag like "Caveman"
    /// gets outranked by a more specific compound tag that merely contains it
    /// ("Caveman Derek Hale"). Blindly taking the top suggestion would silently
    /// rewrite the user's tag into a different, narrower one. Only accept a
    /// suggestion that is the <i>same</i> tag up to case / spacing / punctuation
    /// (so "hurt comfort" → "Hurt/Comfort" still canonicalizes); otherwise keep
    /// exactly what the user typed.</summary>
    internal static string BestFreeformMatch(string term, IReadOnlyList<string> matches)
    {
        var typed = NormalizedTag(term);
        return matches.FirstOrDefault(m => NormalizedTag(m) == typed) ?? term;
    }

    /// <summary>Lowercased, letters and numbers only — collapses case, whitespace
    /// and punctuation differences so formatting variants compare equal.</summary>
    internal static string NormalizedTag(string s)
    {
        var sb = new StringBuilder();
        foreach (var rune in s.ToLowerInvariant().EnumerateRunes())
            if (Rune.IsLetter(rune) || Rune.IsNumber(rune)) sb.Append(rune.ToString());
        return sb.ToString();
    }

    /// <summary>Scores each candidate ship against the typed term. Penalizes
    /// candidates whose <c>/</c>-arity doesn't match (a 2-person query shouldn't
    /// resolve to a 3+ person ship), and rewards candidates where each typed side
    /// appears as a whole word in the corresponding side of the candidate.
    /// e.g. "Bella/Edward" → prefer "Bella Swan/Edward Cullen" over
    /// "Oswald Cobblepot/Isabella/Edward Nygma" (3 parts; "Bella" only matches
    /// inside "Isabella").</summary>
    private static string? BestRelationshipMatch(string term, IReadOnlyList<string> matches)
    {
        var typed = SplitSides(term).Select(s => s.ToLowerInvariant()).ToArray();
        if (typed.Length < 2) return null;
        (int Score, string Value)? best = null;
        foreach (var candidate in matches)
        {
            var parts = SplitSides(candidate);
            var score = parts.Length == typed.Length ? 10 : -5 * Math.Abs(parts.Length - typed.Length);
            // Each typed side should be a whole-word match in *some* part.
            // Slightly prefer same-order alignment.
            for (var i = 0; i < typed.Length; i++)
            {
                var side = typed[i];
                if (i < parts.Length && ContainsWholeWord(side, parts[i].ToLowerInvariant())) score += 3;
                else if (parts.Any(p => ContainsWholeWord(side, p.ToLowerInvariant()))) score += 2;
                else score -= 2;
            }
            if (best is null || score > best.Value.Score) best = (score, candidate);
        }
        return best?.Value;
    }

    private static bool ContainsWholeWord(string needle, string haystack) =>
        needle.Length > 0 && SearchSuggestions.AlphanumericTokens(haystack).Contains(needle);
}
