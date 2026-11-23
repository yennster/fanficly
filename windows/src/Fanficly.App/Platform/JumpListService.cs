using Fanficly.Core;
using Windows.UI.StartScreen;

namespace Fanficly.App.Platform;

/// <summary>
/// The taskbar / Start jump list: "Continue reading" the last story (the
/// widget's resume route) plus shortcuts to the main tabs.
/// </summary>
public static class JumpListService
{
    /// <summary>How long a reading-position save waits before the jump list
    /// is rebuilt (#165).</summary>
    private static readonly TimeSpan SaveRefreshDelay = TimeSpan.FromSeconds(5);

    private static CancellationTokenSource? _pendingRefresh;

    /// <summary>Rebuilds the jump list after a reading-position save: at most
    /// once every <see cref="SaveRefreshDelay"/> while reading (saves come every
    /// 1.5 s, and more reading doesn't push it back), or right away when
    /// <paramref name="now"/> (leaving the reader, closing the window). Call it
    /// on the UI thread.</summary>
    public static void RefreshSoon(bool now = false)
    {
        if (now)
        {
            _pendingRefresh?.Cancel();
            _pendingRefresh = null;
            _ = RefreshAsync();
            return;
        }
        if (_pendingRefresh is { IsCancellationRequested: false }) return;
        var cts = _pendingRefresh = new CancellationTokenSource();
        _ = RefreshAfterDelayAsync(cts);
    }

    private static async Task RefreshAfterDelayAsync(CancellationTokenSource cts)
    {
        try { await Task.Delay(SaveRefreshDelay, cts.Token); }
        catch (OperationCanceledException) { return; }
        if (_pendingRefresh == cts) _pendingRefresh = null;
        await RefreshAsync();
    }

    public static async Task RefreshAsync()
    {
        if (AppHost.IsDemoMode || !JumpList.IsSupported()) return;
        try
        {
            var list = await JumpList.LoadCurrentAsync();
            list.SystemGroupKind = JumpListSystemGroupKind.None;
            list.Items.Clear();

            if (WidgetProgressStore.Load() is { } last)
            {
                var uri = DeepLink.ResumeUri(last.Id, last.Chapter, last.Paragraph);
                var resume = JumpListItem.CreateWithArguments(uri.ToString(), $"Continue “{Trim(last.Title)}”");
                resume.Description = last.Author.Length > 0 ? $"by {last.Author} · {Math.Round(last.ClampedProgress * 100)}% read" : "";
                resume.GroupName = "Reading";
                resume.Logo = new Uri("ms-appx:///Assets/Square44x44Logo.targetsize-32.png");
                list.Items.Add(resume);
            }

            foreach (var item in new[] { SidebarItem.Search, SidebarItem.Library, SidebarItem.Popular, SidebarItem.Subscriptions })
            {
                var entry = JumpListItem.CreateWithArguments($"-tab {item.RawValue()}", item.Title());
                entry.GroupName = "Go to";
                list.Items.Add(entry);
            }
            await list.SaveAsync();
        }
        catch (Exception e)
        {
            AppHost.Log($"Jump list update failed: {e.Message}");
        }
    }

    private static string Trim(string title) => title.Length <= 40 ? title : title[..39] + "…";
}
