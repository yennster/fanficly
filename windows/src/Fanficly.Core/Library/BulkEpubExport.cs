namespace Fanficly.Core;

/// <summary>Settings → Storage → Export All Downloaded EPUBs (#417): one EPUB
/// per downloaded story, written into a folder the user picks. Swift:
/// <c>BulkEPUBExporter</c>, which hands the same files to the share sheet.
///
/// Each file is the one Export → EPUB would make (#173): a copy of the saved
/// AO3 EPUB, or one <see cref="EpubBuilder"/> makes from the saved chapter
/// text, so it works offline and never asks AO3. Files are named after the
/// story, as a single export names them (<see cref="EpubBuilder.FileName"/>);
/// two stories with the same name get their work id added ("Stay (12345).epub").</summary>
public static class BulkEpubExport
{
    public sealed record Plan(IReadOnlyList<int> WorkIds, long EstimatedBytes)
    {
        public int Count => WorkIds.Count;
    }

    /// <summary>The downloaded stories (saved text or a saved EPUB), in title
    /// order, and roughly how much room their files take: a saved EPUB's size,
    /// or about 6 bytes a word for one built from the text. Read on the UI
    /// thread, like every record.</summary>
    public static Plan MakePlan(LibraryStore store, Func<int, bool>? isPending = null, string? epubFolder = null)
    {
        var ids = new List<int>();
        long bytes = 0;
        var works = store.Works
            .Where(w => isPending?.Invoke(w.Ao3Id) != true)
            .OrderBy(w => w.Title, StringComparer.CurrentCultureIgnoreCase);
        foreach (var work in works)
        {
            var saved = SavedFile(work.Ao3Id, epubFolder);
            if (saved is null && !WorkPersistence.IsDownloaded(work)) continue;
            ids.Add(work.Ao3Id);
            long? size = null;
            if (saved is not null)
            {
                try { size = new FileInfo(saved).Length; }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
            }
            bytes += size ?? (long)Math.Max(work.WordCount, 0) * 6 + 8_000;
        }
        return new Plan(ids, bytes);
    }

    /// <summary>File names for the stories, without ".epub": the story's name
    /// as a single export names it, with " (&lt;id&gt;)" added for every story
    /// whose name another one shares (ignoring case, as Windows and Files do).</summary>
    public static Dictionary<int, string> FileNames(IEnumerable<(int Id, string Title)> works)
    {
        var bases = works.Select(w => (w.Id, Name: EpubBuilder.FileName(w.Title, w.Id))).ToList();
        var counts = bases.GroupBy(b => b.Name, StringComparer.OrdinalIgnoreCase)
            .ToDictionary(g => g.Key, g => g.Count(), StringComparer.OrdinalIgnoreCase);
        return bases.ToDictionary(b => b.Id, b => counts[b.Name] > 1 ? $"{b.Name} ({b.Id})" : b.Name);
    }

    /// <summary>Writes the plan's files into <paramref name="folder"/> and
    /// returns their paths. Each book is read on the caller's (UI) thread and
    /// built and written on the thread pool, one at a time, so a large library
    /// never sits in memory at once. <paramref name="progress"/> gets the
    /// number done after each; cancelling stops between files and throws
    /// <see cref="OperationCanceledException"/>, leaving the files already
    /// written. An existing file with the same name is replaced.</summary>
    public static async Task<List<string>> ExportAsync(Plan plan, LibraryStore store, string folder,
        IProgress<int>? progress = null, CancellationToken ct = default, string? epubFolder = null)
    {
        Directory.CreateDirectory(folder);
        var works = plan.WorkIds.Select(store.GetWork).OfType<Work>().ToList();
        var names = FileNames(works.Select(w => (w.Ao3Id, w.Title)));
        var written = new List<string>();
        var done = 0;
        foreach (var work in works)
        {
            ct.ThrowIfCancellationRequested();
            var target = Path.Combine(folder, $"{names[work.Ao3Id]}.epub");
            var saved = SavedFile(work.Ao3Id, epubFolder);
            var copied = false;
            if (saved is not null)
            {
                try
                {
                    await Task.Run(() => File.Copy(saved, target, overwrite: true), ct);
                    copied = true;
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    // A saved file that can't be read, or a name Windows won't
                    // take: build one from the text instead, under the work id
                    // if the name was the problem.
                    LibraryHooks.Log?.Invoke($"Copying {saved} failed: {e.Message}");
                }
            }
            if (copied)
            {
                written.Add(target);
            }
            else if (WorkPersistence.IsDownloaded(work))
            {
                var book = EpubBuilder.BookFrom(work);
                var bytes = await Task.Run(() => EpubBuilder.Build(book), ct);
                try
                {
                    await File.WriteAllBytesAsync(target, bytes, ct);
                }
                catch (IOException e)
                {
                    // A name Windows won't take (a title like "CON" or "AUX"):
                    // fall back to the work id rather than stop the whole export.
                    LibraryHooks.Log?.Invoke($"Writing {target} failed: {e.Message}");
                    target = Path.Combine(folder, $"work-{work.Ao3Id}.epub");
                    await File.WriteAllBytesAsync(target, bytes, ct);
                }
                written.Add(target);
            }
            done++;
            progress?.Report(done);
        }
        return written;
    }

    private static string? SavedFile(int workId, string? epubFolder)
    {
        if (epubFolder is null) return WorkPersistence.EpubPath(workId);
        var path = Path.Combine(epubFolder, $"{workId}.epub");
        return File.Exists(path) ? path : null;
    }
}
