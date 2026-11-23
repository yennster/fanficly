namespace Fanficly.Core;

/// <summary>What a folder import did (Swift: <c>EPUBImportCenter.FolderResult</c>):
/// new works, works already in the Library that it updated, extra copies of a
/// work it skipped, and files it couldn't read.</summary>
public sealed record EpubFolderImportResult
{
    public int Found { get; init; }
    public int Processed { get; init; }
    public int Imported { get; init; }
    public int Updated { get; init; }
    public int Skipped { get; init; }
    public IReadOnlyList<string> Failures { get; init; } = [];
    public bool Cancelled { get; init; }
}

/// <summary>Decides which copy of each work a folder import keeps and counts the
/// outcome (Swift: <c>EPUBImportCenter.FolderTally</c>). Pure, so the rules are
/// tested without files.</summary>
public sealed class EpubFolderTally
{
    // Chapter count of the copy kept for each work id so far.
    private readonly Dictionary<int, int> _kept = [];
    private readonly List<string> _failures = [];
    private int _imported, _updated, _skipped, _processed, _found;
    private bool _cancelled;

    /// <summary>Whether this copy should be saved: the first copy of a work, or a
    /// later one with more chapters than the copy already kept.</summary>
    public bool ShouldSave(int workId, int chapters) =>
        !_kept.TryGetValue(workId, out var previous) || chapters > previous;

    /// <summary>A copy was saved. A later copy that replaced an earlier one leaves
    /// that one skipped; otherwise it's new or an update.</summary>
    public void Saved(int workId, int chapters, bool wasInLibrary)
    {
        if (_kept.ContainsKey(workId)) _skipped++;
        else if (wasInLibrary) _updated++;
        else _imported++;
        _kept[workId] = chapters;
    }

    public void SkippedCopy() => _skipped++;
    public void Failed(string message) => _failures.Add(message);
    public void ProcessedOne() => _processed++;
    public void SetFound(int count) => _found = count;
    public void SetCancelled() => _cancelled = true;

    public EpubFolderImportResult Result => new()
    {
        Found = _found, Processed = _processed, Imported = _imported, Updated = _updated,
        Skipped = _skipped, Failures = _failures.ToList(), Cancelled = _cancelled,
    };
}

/// <summary>Imports every EPUB in a folder and its subfolders into the Library
/// (#418; Swift: <c>EPUBImportCenter.importFolder</c>), through the same
/// <see cref="EpubImport.Parse"/> and <see cref="EpubImport.Save"/> as a single
/// file. Offline: no AO3 requests.</summary>
public static class EpubFolderImport
{
    /// <summary>How many failures the outcome names before summing up the rest.</summary>
    public const int ListedFailures = 5;

    /// <summary>Every <c>.epub</c> file in <paramref name="folder"/> and its
    /// subfolders, in path order. Other files, hidden and system files, and
    /// folders the user can't read are left out.</summary>
    public static IReadOnlyList<string> FindEpubs(string folder)
    {
        var options = new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            MatchCasing = MatchCasing.CaseInsensitive,
            MatchType = MatchType.Simple,
            AttributesToSkip = FileAttributes.Hidden | FileAttributes.System,
        };
        try
        {
            return Directory.EnumerateFiles(folder, "*.epub", options)
                // "*.epub" also matches ".epub1" style names on some file systems.
                .Where(f => string.Equals(Path.GetExtension(f), ".epub", StringComparison.OrdinalIgnoreCase))
                .Order(StringComparer.OrdinalIgnoreCase)
                .ToList();
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    /// <summary>Reads, parses and saves each file in turn, one at a time so memory
    /// stays flat; parsing runs on the pool, saving on the caller's thread (the
    /// UI thread in the app). Checks <paramref name="cancel"/> between files and
    /// reports (done, total) to <paramref name="progress"/>. Queues one backup at
    /// the end when anything was saved.</summary>
    public static async Task<EpubFolderImportResult> ImportAsync(
        IReadOnlyList<string> files, LibraryStore store,
        Action<int, int>? progress = null, CancellationToken cancel = default)
    {
        var tally = new EpubFolderTally();
        tally.SetFound(files.Count);
        progress?.Invoke(0, files.Count);
        var saved = false;
        for (var i = 0; i < files.Count; i++)
        {
            if (cancel.IsCancellationRequested)
            {
                tally.SetCancelled();
                break;
            }
            var path = files[i];
            try
            {
                var (data, payload) = await Task.Run(() =>
                {
                    var bytes = File.ReadAllBytes(path);
                    return (bytes, EpubImport.Parse(bytes));
                });
                var id = payload.Summary.Id;
                if (tally.ShouldSave(id, payload.Chapters.Count))
                {
                    var wasInLibrary = store.GetWork(id) is not null;
                    // Importing a work deleted a moment ago keeps it (#169).
                    UndoQueue.Shared.Cancel(UndoQueue.Keys.Work(id));
                    EpubImport.Save(payload, data, store, queueBackup: false);
                    tally.Saved(id, payload.Chapters.Count, wasInLibrary);
                    saved = true;
                }
                else
                {
                    tally.SkippedCopy();
                }
            }
            catch (Exception e) when (e is not OutOfMemoryException)
            {
                tally.Failed($"{Path.GetFileName(path)}: {e.Message}");
            }
            tally.ProcessedOne();
            progress?.Invoke(i + 1, files.Count);
        }
        if (saved) LibrarySyncManager.QueueBackupShared(store);
        return tally.Result;
    }

    /// <summary>The dialog a folder import ends with (Swift: <c>EPUBImportCenter.folderOutcome</c>).</summary>
    public static (string Title, string Message) Outcome(EpubFolderImportResult r)
    {
        if (r.Found == 0)
            return ("No EPUBs found", "That folder and its subfolders have no EPUB files.");
        var kept = r.Imported + r.Updated;
        var title = r.Cancelled ? "Import stopped"
            : kept == 0 && r.Failures.Count > 0 ? "Couldn't import"
            : "Imported";
        var lines = new List<string>();
        if (r.Cancelled)
            lines.Add($"Stopped after {r.Processed} of {r.Found} files. What was imported stays in your Library.");
        if (r.Imported > 0)
            lines.Add(r.Imported == 1 ? "1 new story added to your Library." : $"{r.Imported} new stories added to your Library.");
        if (r.Updated > 0)
            lines.Add(r.Updated == 1 ? "1 story already in your Library updated." : $"{r.Updated} stories already in your Library updated.");
        if (r.Skipped > 0)
            lines.Add(r.Skipped == 1 ? "1 extra copy of a story skipped." : $"{r.Skipped} extra copies of stories skipped.");
        if (r.Failures.Count > 0)
        {
            lines.Add(r.Failures.Count == 1 ? "1 file couldn't be imported:" : $"{r.Failures.Count} files couldn't be imported:");
            lines.AddRange(r.Failures.Take(ListedFailures));
            var rest = r.Failures.Count - ListedFailures;
            if (rest > 0) lines.Add(rest == 1 ? "…and 1 more." : $"…and {rest} more.");
        }
        if (kept == 0 && r.Failures.Count == 0 && !r.Cancelled) lines.Add("Nothing new to add.");
        return (title, string.Join("\n", lines));
    }
}
