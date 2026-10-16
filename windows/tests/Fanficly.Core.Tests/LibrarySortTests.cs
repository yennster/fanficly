using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>Library sorting: pinned stories stay on top, every key orders the
/// rest in its chosen direction, stories missing the key sink to the bottom,
/// and ties fall back to a stable order.</summary>
public sealed class LibrarySortTests
{
    private sealed record Story(
        string Title,
        string AuthorName,
        DateTimeOffset SavedAt,
        DateTimeOffset? LastReadAt,
        DateTimeOffset? UpdatedAt,
        int WordCount,
        bool IsPinned) : ILibrarySortable;

    private static DateTimeOffset Day(double n) => DateTimeOffset.UnixEpoch.AddDays(n);
    private static string[] Titles(IEnumerable<Story> stories) => stories.Select(s => s.Title).ToArray();
    private static Story S(string title, string authorName = "author", DateTimeOffset? savedAt = null,
                           DateTimeOffset? lastReadAt = null, DateTimeOffset? updatedAt = null,
                           int wordCount = 0, bool isPinned = false) =>
        new(title, authorName, savedAt ?? DateTimeOffset.UnixEpoch, lastReadAt, updatedAt, wordCount, isPinned);

    [Fact]
    public void Default_IsNewestSavedFirst_WithPinnedOnTop()
    {
        Story[] stories = [S("old", savedAt: Day(1)), S("pinned", savedAt: Day(0), isPinned: true), S("new", savedAt: Day(3))];
        Assert.Equal(["pinned", "new", "old"], Titles(LibrarySort.Default.Sorted(stories)));
    }

    [Fact]
    public void PinnedStaysOnTop_InEitherDirection()
    {
        Story[] stories = [S("B"), S("Z", isPinned: true), S("A")];
        Assert.Equal(["Z", "A", "B"], Titles(new LibrarySort(LibrarySortKey.Title, true).Sorted(stories)));
        Assert.Equal(["Z", "B", "A"], Titles(new LibrarySort(LibrarySortKey.Title, false).Sorted(stories)));
    }

    [Fact]
    public void LastRead_NeverReadSinksInBothDirections()
    {
        Story[] stories = [S("never"), S("monday", lastReadAt: Day(1)), S("friday", lastReadAt: Day(5))];
        Assert.Equal(["friday", "monday", "never"], Titles(new LibrarySort(LibrarySortKey.LastRead, false).Sorted(stories)));
        Assert.Equal(["monday", "friday", "never"], Titles(new LibrarySort(LibrarySortKey.LastRead, true).Sorted(stories)));
    }

    [Fact]
    public void LastUpdated_MissingDateSinks()
    {
        Story[] stories = [S("no date"), S("older", updatedAt: Day(2)), S("newer", updatedAt: Day(9))];
        Assert.Equal(["newer", "older", "no date"], Titles(new LibrarySort(LibrarySortKey.LastUpdated, false).Sorted(stories)));
        Assert.Equal(["older", "newer", "no date"], Titles(new LibrarySort(LibrarySortKey.LastUpdated, true).Sorted(stories)));
    }

    [Fact]
    public void Title_UsesNaturalOrder()
    {
        Story[] stories = [S("Part 10"), S("part 2"), S("Apple")];
        Assert.Equal(["Apple", "part 2", "Part 10"], Titles(new LibrarySort(LibrarySortKey.Title, true).Sorted(stories)));
        Assert.Equal(["Part 10", "part 2", "Apple"], Titles(new LibrarySort(LibrarySortKey.Title, false).Sorted(stories)));
    }

    [Fact]
    public void Author_TiesReadTitleAToZ_WhicheverWayAuthorsRun()
    {
        Story[] stories = [S("Zeta", authorName: "beth"), S("Alpha", authorName: "beth"), S("Mid", authorName: "anna")];
        Assert.Equal(["Mid", "Alpha", "Zeta"], Titles(new LibrarySort(LibrarySortKey.Author, true).Sorted(stories)));
        Assert.Equal(["Alpha", "Zeta", "Mid"], Titles(new LibrarySort(LibrarySortKey.Author, false).Sorted(stories)));
    }

    [Fact]
    public void Length()
    {
        Story[] stories = [S("short", wordCount: 1_000), S("epic", wordCount: 250_000), S("novella", wordCount: 30_000)];
        Assert.Equal(["epic", "novella", "short"], Titles(new LibrarySort(LibrarySortKey.Length, false).Sorted(stories)));
        Assert.Equal(["short", "novella", "epic"], Titles(new LibrarySort(LibrarySortKey.Length, true).Sorted(stories)));
    }

    [Fact]
    public void Ties_FallBackToNewestSavedThenTitle()
    {
        Story[] stories =
        [
            S("b", savedAt: Day(1), wordCount: 500),
            S("a", savedAt: Day(1), wordCount: 500),
            S("c", savedAt: Day(4), wordCount: 500),
        ];
        Assert.Equal(["c", "a", "b"], Titles(new LibrarySort(LibrarySortKey.Length, false).Sorted(stories)));
    }

    [Fact]
    public void KeysStartInTheirNaturalDirection()
    {
        Assert.False(LibrarySortKey.DateSaved.DefaultAscending());
        Assert.False(LibrarySortKey.LastRead.DefaultAscending());
        Assert.False(LibrarySortKey.LastUpdated.DefaultAscending());
        Assert.False(LibrarySortKey.Length.DefaultAscending());
        Assert.True(LibrarySortKey.Title.DefaultAscending());
        Assert.True(LibrarySortKey.Author.DefaultAscending());
        Assert.Equal("Longest First", LibrarySortKey.Length.DirectionLabel(ascending: false));
        Assert.Equal("A to Z", LibrarySortKey.Title.DirectionLabel(ascending: true));
        Assert.Equal("Newest First", LibrarySortKey.LastRead.DirectionLabel(ascending: false));
    }

    [Fact]
    public void UnknownPersistedKey_FallsBackToDefault()
    {
        Assert.Equal(LibrarySort.Default, LibrarySort.FromStored("kudos", true));
        Assert.Equal(new LibrarySort(LibrarySortKey.Title, true), LibrarySort.FromStored("title", true));
    }
}
