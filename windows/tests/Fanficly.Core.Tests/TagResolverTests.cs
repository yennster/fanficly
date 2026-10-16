using Fanficly.Core;

namespace Fanficly.Core.Tests;

public class TagResolverTests
{
    public TagResolverTests()
    {
        // The resolution cache is process-global; clear it so a memoized result
        // from one case can't leak into the next. (xUnit runs a class's tests one
        // at a time, and only this class touches the resolver.)
        TagResolver.ClearCacheForTesting();
    }

    [Fact]
    public void BestMatch_PrefersExactCaseInsensitive()
    {
        string[] matches = ["Hermione Granger/Draco Malfoy", "Draco Malfoy/Harry Potter"];
        Assert.Equal("Hermione Granger/Draco Malfoy", TagResolver.BestMatch("hermione granger/draco malfoy", matches));
    }

    [Fact]
    public void BestMatch_FallsBackToFirst()
    {
        // Non-freeform fields still take AO3's top (most popular) suggestion when
        // nothing matches exactly — that's what lets a character lookup like
        // "hermione" canonicalize to "Hermione Granger", and it powers
        // ship-via-character resolution. Freeform tags are stricter — see the
        // freeform tests below.
        string[] matches = ["Hermione Granger", "Hermione Granger (Wizarding World)"];
        Assert.Equal("Hermione Granger", TagResolver.BestMatch("hermione", matches, AO3AutocompleteField.Character));
    }

    [Fact]
    public void BestMatch_EmptyReturnsNil()
    {
        Assert.Null(TagResolver.BestMatch("x", []));
    }

    [Fact]
    public void Candidates_RelationshipExpandsSlashVariants()
    {
        var c = TagResolver.Candidates("hermione/draco", AO3AutocompleteField.Relationship);
        Assert.Contains("hermione/draco", c);
        Assert.Contains("hermione draco", c); // slash -> space
        Assert.Contains("draco hermione", c); // reversed
    }

    [Fact]
    public void Candidates_NonRelationshipIsJustTheTerm()
    {
        Assert.Equal(["Slow Burn"], TagResolver.Candidates("Slow Burn", AO3AutocompleteField.Freeform));
        Assert.Equal(["Hermione Granger"], TagResolver.Candidates("Hermione Granger", AO3AutocompleteField.Character));
    }

    [Fact]
    public async Task Resolve_UsesMockAutocomplete()
    {
        // The Swift MockAO3Client echoes the term, so resolution returns the input.
        var filters = new AO3SearchFilters { RelationshipNames = ["Edward/Bella"] };
        var resolved = await TagResolver.ResolveAsync(filters, new StubAO3Client { AutocompleteEchoesTerm = true });
        Assert.Equal(["Edward/Bella"], resolved.RelationshipNames);
    }

    [Fact]
    public async Task Resolve_ShipViaCharacterFallback()
    {
        // AO3 can't match "hermione/draco" directly, but can match each character
        // and then the ship from the full names.
        var stub = new StubAO3Client
        {
            AutocompleteResponses = new()
            {
                // Direct relationship lookups return nothing for the short forms…
                ["hermione/draco"] = [],
                ["hermione draco"] = [],
                ["draco hermione"] = [],
                // …character lookups succeed…
                ["hermione"] = ["Hermione Granger"],
                ["draco"] = ["Draco Malfoy"],
                // …and the ship from the canonical names resolves.
                ["hermione granger/draco malfoy"] = ["Hermione Granger/Draco Malfoy"],
            },
        };
        var filters = new AO3SearchFilters { RelationshipNames = ["hermione/draco"] };
        var resolved = await TagResolver.ResolveAsync(filters, stub);
        Assert.Equal(["Hermione Granger/Draco Malfoy"], resolved.RelationshipNames);
    }

    [Fact]
    public void BestMatch_RelationshipPrefersSameArityWholeWordMatch()
    {
        // "Bella/Edward" must not resolve to a 3-person ship where "Bella" is
        // only a substring of "Isabella".
        string[] matches = ["Oswald Cobblepot/Isabella/Edward Nygma", "Bella Swan/Edward Cullen"];
        Assert.Equal("Bella Swan/Edward Cullen", TagResolver.BestMatch("Bella/Edward", matches, AO3AutocompleteField.Relationship));
    }

    [Fact]
    public void BestMatch_FreeformDoesNotExpandToMoreSpecificTag()
    {
        // Regression: typing the freeform "caveman" must not get rewritten to a
        // popular compound tag that merely contains it. AO3 ranks autocomplete by
        // popularity, so "Caveman Derek Hale" comes back first.
        Assert.Equal("caveman", TagResolver.BestMatch("caveman", ["Caveman Derek Hale"], AO3AutocompleteField.Freeform));
    }

    [Fact]
    public void BestMatch_FreeformStillCanonicalizesFormatting()
    {
        // Same tag up to case/spacing/punctuation should still resolve.
        Assert.Equal("Hurt/Comfort", TagResolver.BestMatch("hurt comfort", ["Caveman Derek Hale", "Hurt/Comfort"], AO3AutocompleteField.Freeform));
    }

    [Fact]
    public async Task Resolve_FreeformKeepsTypedTermWhenOnlyNarrowerSuggestions()
    {
        var stub = new StubAO3Client { AutocompleteResponses = new() { ["caveman"] = ["Caveman Derek Hale"] } };
        var filters = new AO3SearchFilters { FreeformNames = ["caveman"] };
        var resolved = await TagResolver.ResolveAsync(filters, stub);
        Assert.Equal(["caveman"], resolved.FreeformNames);
    }

    [Fact]
    public async Task Resolve_DirectRelationshipMatch()
    {
        var stub = new StubAO3Client { AutocompleteResponses = new() { ["edward/bella"] = ["Edward Cullen/Bella Swan"] } };
        var filters = new AO3SearchFilters { RelationshipNames = ["edward/bella"] };
        var resolved = await TagResolver.ResolveAsync(filters, stub);
        Assert.Equal(["Edward Cullen/Bella Swan"], resolved.RelationshipNames);
    }

    [Fact]
    public async Task Resolve_NetworkFailureIsNotCached()
    {
        // Regression: a failed lookup (offline / 429) must not poison the
        // process-lifetime cache — once connectivity returns, the same term must
        // resolve canonically without an app relaunch.
        var stub = new StubAO3Client
        {
            AutocompleteResponses = new() { ["hermione"] = ["Hermione Granger"] },
            AutocompleteFailingTerms = ["hermione"],
        };
        var filters = new AO3SearchFilters { CharacterNames = ["hermione"] };
        var offline = await TagResolver.ResolveAsync(filters, stub);
        Assert.Equal(["hermione"], offline.CharacterNames); // falls back to the typed term while the lookup fails

        stub.AutocompleteFailingTerms = [];
        var online = await TagResolver.ResolveAsync(filters, stub);
        Assert.Equal(["Hermione Granger"], online.CharacterNames); // recovers once the network is back
    }

    [Fact]
    public async Task Resolve_NoMatchAnswerIsCached()
    {
        // An authoritative empty answer IS cacheable: the second resolve must not
        // re-hit autocomplete for the same term.
        var stub = new StubAO3Client();
        var filters = new AO3SearchFilters { CharacterNames = ["totallyunknown"] };
        await TagResolver.ResolveAsync(filters, stub);
        var callsAfterFirst = stub.AutocompleteCalls.Count;
        await TagResolver.ResolveAsync(filters, stub);
        Assert.Equal(callsAfterFirst, stub.AutocompleteCalls.Count); // authoritative no-match answers are memoized
    }
}
