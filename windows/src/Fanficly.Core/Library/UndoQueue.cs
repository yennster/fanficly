namespace Fanficly.Core;

/// <summary>
/// One-tap deletes wait behind an Undo bar (#169), the Swift app's
/// <c>UndoCenter</c>. A delete schedules its work here instead of running it:
/// the row leaves its list at once (screens skip <see cref="IsPending"/> keys),
/// a "Deleted 'X' · Undo" InfoBar shows, and the delete only runs when the bar
/// closes. Undo (or Ctrl+Z) drops it and the row comes back untouched, with its
/// offline text, EPUB, notes, tags and folders.
///
/// One delete waits at a time: scheduling another runs the one before it first,
/// and closing the app runs it too. If the app is killed while the bar is up,
/// the delete simply never happened, which loses nothing. The timer and the bar
/// live in the app (<c>UndoBar</c>); this class is UI-thread only, like the
/// records it deletes.
/// </summary>
public sealed class UndoQueue
{
    public static UndoQueue Shared { get; } = new();

    public sealed class Pending
    {
        internal Pending(string message, IReadOnlySet<string> keys, LibraryEntityKinds kinds, Action? commit, Action? revert)
        {
            Message = message;
            Keys = keys;
            Kinds = kinds;
            Commit = commit;
            Revert = revert;
        }

        public Guid Id { get; } = Guid.NewGuid();
        public string Message { get; }
        public IReadOnlySet<string> Keys { get; }
        /// <summary>The records the hidden rows are, so their screens redraw.</summary>
        public LibraryEntityKinds Kinds { get; }
        internal Action? Commit { get; }
        internal Action? Revert { get; }
    }

    public Pending? Current { get; private set; }

    /// <summary>Raised when a delete starts or ends waiting (it hid or showed
    /// rows): <c>UndoBar</c> shows or closes the bar, and the app redraws the
    /// screens that list <see cref="Pending.Kinds"/>.</summary>
    public event Action<Pending?, LibraryEntityKinds>? Changed;

    public bool IsPending(string key) => Current?.Keys.Contains(key) == true;

    /// <summary>Hides <paramref name="keys"/> from their lists and runs
    /// <paramref name="commit"/> when the bar closes, unless Undo comes first.
    /// <paramref name="commit"/> must check its records still exist: a sync
    /// restore can delete them while the bar is up.</summary>
    public Pending Schedule(string message, IEnumerable<string> keys, LibraryEntityKinds kinds, Action commit) =>
        Show(new Pending(message, keys.ToHashSet(), kinds, commit, null));

    /// <summary>For a delete that already happened and is cheap to put back (a
    /// reader profile, whose deletion syncs as a tombstone): the same bar, and
    /// Undo runs <paramref name="revert"/>.</summary>
    public Pending Offer(string message, Action revert) =>
        Show(new Pending(message, new HashSet<string>(), LibraryEntityKinds.None, null, revert));

    /// <summary>Drops a waiting delete without undoing anything because
    /// <paramref name="key"/> is being saved again by the user (a search or
    /// filter saved under that name, a deleted work followed, saved offline or
    /// imported again): the newest intent wins, and the delete never runs or
    /// writes its tombstone. Swift's <c>UndoCenter.cancel</c>.</summary>
    public void Cancel(string key)
    {
        if (Current is not { } item || !item.Keys.Contains(key)) return;
        Current = null;
        Changed?.Invoke(null, item.Kinds);
    }

    /// <summary>Drops the waiting delete; its rows come back.</summary>
    public bool Undo() => Current is { } p && Undo(p.Id);

    public bool Undo(Guid id)
    {
        if (Current is not { } item || item.Id != id) return false;
        Current = null;
        Changed?.Invoke(null, item.Kinds);
        item.Revert?.Invoke();
        return true;
    }

    /// <summary>Runs the waiting delete now, if there is one.</summary>
    public void CommitPending()
    {
        if (Current is { } p) Commit(p.Id);
    }

    public void Commit(Guid id)
    {
        if (Current is not { } item || item.Id != id) return;
        Current = null;
        // The delete first, so the redraw doesn't flash the row back.
        item.Commit?.Invoke();
        Changed?.Invoke(null, item.Kinds);
    }

    private Pending Show(Pending item)
    {
        CommitPending();
        Current = item;
        Changed?.Invoke(item, item.Kinds);
        return item;
    }

    /// <summary>Keys for the records a delete hides, the Swift <c>UndoCenter.Key</c>.</summary>
    public static class Keys
    {
        public static string Work(int ao3Id) => $"work:{ao3Id}";
        public static string Folder(string name) => $"folder:{name}";
        public static string Search(string name) => $"search:{name}";
        public static string Filter(string name) => $"filter:{name}";
        public static string Author(string username) => $"author:{username}";
    }
}
