using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>The Undo bar behind one-tap deletes (#169), the Swift UndoCenterTests.</summary>
public class UndoQueueTests
{
    private readonly List<string> _commits = [];

    [Fact]
    public void ScheduleHidesKeysWithoutCommitting()
    {
        var undo = new UndoQueue();
        undo.Schedule("Deleted “A”", [UndoQueue.Keys.Work(1)], LibraryEntityKinds.Works, () => _commits.Add("A"));

        Assert.True(undo.IsPending(UndoQueue.Keys.Work(1)));
        Assert.False(undo.IsPending(UndoQueue.Keys.Work(2)));
        Assert.Equal("Deleted “A”", undo.Current?.Message);
        Assert.Empty(_commits);
    }

    [Fact]
    public void UndoDropsTheDeleteForGood()
    {
        var undo = new UndoQueue();
        var item = undo.Schedule("Deleted “A”", [UndoQueue.Keys.Work(1)], LibraryEntityKinds.Works, () => _commits.Add("A"));
        Assert.True(undo.Undo());

        Assert.Null(undo.Current);
        Assert.False(undo.IsPending(UndoQueue.Keys.Work(1)));
        undo.CommitPending();
        undo.Commit(item.Id); // the bar's timer firing late
        Assert.Empty(_commits);
    }

    [Fact]
    public void CommitRunsOnce()
    {
        var undo = new UndoQueue();
        var item = undo.Schedule("Deleted “A”", [UndoQueue.Keys.Work(1)], LibraryEntityKinds.Works, () => _commits.Add("A"));
        undo.Commit(item.Id);
        undo.CommitPending();
        Assert.False(undo.Undo());

        Assert.Equal(["A"], _commits);
        Assert.Null(undo.Current);
    }

    [Fact]
    public void SecondDeleteRunsTheFirstAndUndoesOnlyItself()
    {
        var undo = new UndoQueue();
        var first = undo.Schedule("Deleted “A”", [UndoQueue.Keys.Work(1)], LibraryEntityKinds.Works, () => _commits.Add("A"));
        undo.Schedule("Deleted “B”", [UndoQueue.Keys.Folder("B")], LibraryEntityKinds.Folders, () => _commits.Add("B"));

        Assert.Equal(["A"], _commits);
        Assert.False(undo.IsPending(UndoQueue.Keys.Work(1)));
        Assert.True(undo.IsPending(UndoQueue.Keys.Folder("B")));
        Assert.False(undo.Undo(first.Id), "the first one already ran");

        Assert.True(undo.Undo());
        Assert.Equal(["A"], _commits);
    }

    [Fact]
    public void ChangedReportsTheKindsToRedraw()
    {
        var undo = new UndoQueue();
        var seen = new List<(bool Showing, LibraryEntityKinds Kinds, bool Committed)>();
        undo.Changed += (p, kinds) => seen.Add((p is not null, kinds, _commits.Count > 0));
        undo.Schedule("Deleted “A”", [UndoQueue.Keys.Work(1)], LibraryEntityKinds.Works, () => _commits.Add("A"));
        undo.CommitPending();

        Assert.Equal([(true, LibraryEntityKinds.Works, false), (false, LibraryEntityKinds.Works, true)], seen);
    }

    [Fact]
    public void OfferUndoRunsTheRevert()
    {
        var undo = new UndoQueue();
        undo.Offer("Deleted profile “Night”", () => _commits.Add("restored"));
        Assert.NotNull(undo.Current);
        Assert.True(undo.Undo());
        Assert.Equal(["restored"], _commits);
    }

    [Fact]
    public void OfferClosingKeepsTheDelete()
    {
        var undo = new UndoQueue();
        undo.Offer("Deleted profile “Night”", () => _commits.Add("restored"));
        undo.CommitPending();
        Assert.False(undo.Undo());
        Assert.Empty(_commits);
    }
}
