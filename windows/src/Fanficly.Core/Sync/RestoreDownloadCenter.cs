using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace Fanficly.Core;

/// <summary>After a library restore, offers to re-download the EPUB files for
/// works that were saved offline on the old device. Chapter text rides in the
/// backup but the EPUB files don't, so a restored library reads offline yet
/// loses its Downloaded state until the files are fetched again. Any restore
/// path (launch auto-sync, Settings) calls <see cref="ProposeRedownload"/>; the
/// app shows a prompt while <see cref="ProposedIds"/> is set and a progress
/// banner while <see cref="Progress"/> is. Downloads are cancellable at any
/// point — the restored library data is already saved and unaffected.
///
/// UI-agnostic: property changes and <see cref="Announcement"/>s are raised on
/// the thread that called <see cref="StartDownloads"/> when it has a
/// synchronization context (the UI thread), else on the thread pool.</summary>
public sealed class RestoreDownloadCenter : INotifyPropertyChanged
{
    public static RestoreDownloadCenter Shared { get; } = new();

    public readonly record struct DownloadProgress(int Done, int Failed, int Total, bool Finished);

    private IReadOnlyList<int>? _proposedIds;
    private DownloadProgress? _progress;
    private IReadOnlyList<int> _lastProposal = [];
    private CancellationTokenSource? _downloadCts;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>An accessibility announcement for the app to post (screen readers).</summary>
    public event Action<string>? Announcement;

    /// <summary>How long the finished banner stays up.</summary>
    public TimeSpan FinishedBannerDuration { get; set; } = TimeSpan.FromSeconds(4);

    /// <summary>Non-null while the "re-download?" prompt should show.</summary>
    public IReadOnlyList<int>? ProposedIds
    {
        get => _proposedIds;
        private set
        {
            _proposedIds = value;
            OnPropertyChanged();
        }
    }

    /// <summary>Non-null while downloads run (or briefly after, with Finished set).</summary>
    public DownloadProgress? Progress
    {
        get => _progress;
        private set
        {
            if (_progress == value) return;
            _progress = value;
            OnPropertyChanged();
        }
    }

    public bool IsDownloading => _downloadCts is not null;

    /// <summary>Works whose offline text was restored but whose EPUB file is
    /// missing locally — i.e. downloaded on the device that made the backup.</summary>
    public static IReadOnlyList<int> RedownloadCandidates(LibraryStore store) =>
        store.All<Work>()
            .Where(w => w.Chapters.Count > 0 && WorkPersistence.EpubPath(w.Ao3Id) is null)
            .OrderBy(w => w.Title, StringComparer.CurrentCultureIgnoreCase)
            .Select(w => w.Ao3Id)
            .ToList();

    public void ProposeRedownload(LibraryStore store)
    {
        if (_downloadCts is not null || Progress is not null || ProposedIds is not null) return;
        var ids = RedownloadCandidates(store);
        if (ids.Count == 0) return;
        _lastProposal = ids;
        ProposedIds = ids;
    }

    public void DismissProposal() => ProposedIds = null;

    /// <summary>Starts sequential EPUB downloads (the AO3 throttle spaces them
    /// out anyway). Uses the snapshot taken at proposal time, so it works
    /// whether the prompt clears <see cref="ProposedIds"/> before or after.
    /// The returned task completes when the run ends (finished or cancelled).</summary>
    public Task StartDownloads(IAO3Client client)
    {
        var ids = _lastProposal;
        if (ids.Count == 0 || _downloadCts is not null) return Task.CompletedTask;
        ProposedIds = null;
        _lastProposal = [];
        Progress = new DownloadProgress(0, 0, ids.Count, false);
        Announcement?.Invoke($"Downloading {ids.Count} stories for offline reading.");
        var cts = _downloadCts = new CancellationTokenSource();
        return RunAsync(client, ids, cts);
    }

    private async Task RunAsync(IAO3Client client, IReadOnlyList<int> ids, CancellationTokenSource cts)
    {
        var ct = cts.Token;
        int done = 0, failed = 0;
        foreach (var id in ids)
        {
            if (ct.IsCancellationRequested) break;
            try
            {
                await client.DownloadEpubAsync(id, ct);
                done++;
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception)
            {
                // Skip and move on — a deleted work mustn't stall the rest.
                failed++;
            }
            if (ct.IsCancellationRequested) break;
            Progress = new DownloadProgress(done, failed, ids.Count, false);
        }
        if (ct.IsCancellationRequested) return;
        _downloadCts = null;
        Progress = new DownloadProgress(done, failed, ids.Count, true);
        Announcement?.Invoke(failed == 0
            ? $"Downloaded {done} stories for offline reading."
            : $"Downloads finished. {done} succeeded, {failed} failed.");
        try
        {
            await Task.Delay(FinishedBannerDuration, ct);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        if (Progress?.Finished == true) Progress = null;
    }

    /// <summary>Stops the downloads; everything already restored (and already
    /// downloaded) stays.</summary>
    public void Cancel()
    {
        _downloadCts?.Cancel();
        _downloadCts = null;
        Progress = null;
        Announcement?.Invoke("Downloads canceled. Your restored library is unaffected.");
    }

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
