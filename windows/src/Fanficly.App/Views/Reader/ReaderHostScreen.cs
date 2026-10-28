using Fanficly.App.Shell;
using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.System;

namespace Fanficly.App.Views.Reader;

/// <summary>
/// A screen that hosts a <see cref="ReaderView"/> (WorkDetailView and
/// SavedWorkReader). Until the reader exists it shows the window's header and a
/// loading or error view on the reader's page colour, so the screen is opaque
/// from the first frame; once it does, the reader draws its own top bar.
/// Forwards the screen lifecycle (appearing, disappearing, removal) and the
/// window's keys to the reader.
/// </summary>
internal abstract class ReaderHostScreen : Screen
{
    private readonly ReaderBrushes _brushes = new();
    private bool _onTop;
    private bool _removed;
    private readonly CancellationTokenSource _lifetime = new();

    protected Grid Host { get; } = new();

    protected ReaderView? Reader { get; private set; }

    public override bool ShowsHeader => Reader is null;

    protected override FrameworkElement Build()
    {
        ApplyBackground();
        Theme.Changed += ApplyBackground;
        Start();
        return Host;
    }

    /// <summary>Starts loading (called once, when the screen is first built).</summary>
    protected abstract void Start();

    private void ApplyBackground()
    {
        _brushes.Update(ReaderPrefs.Theme);
        Host.Background = _brushes.Background;
        Host.RequestedTheme = _brushes.ElementTheme;
    }

    protected void ShowReader(ReaderView reader)
    {
        if (_removed) { reader.Removed(); return; }
        if (Reader is { } old)
        {
            if (_onTop) old.Disappearing();
            old.Removed();
        }
        Reader = reader;
        Host.Children.Clear();
        Host.Children.Add(reader.Root);
        InvalidateChrome();
        if (_onTop) reader.Appearing();
    }

    /// <summary>Replaces the reader with one holding more of the same work, opened
    /// where the current one is (its chapters arrived after the first).</summary>
    protected void SwapReader(ReaderView next)
    {
        if (_removed) { next.Retire(); return; }
        if (Reader is not { } old) { ShowReader(next); return; }
        next.ContinueFrom(old);
        old.Retire();
        Reader = next;
        Host.Children.Clear();
        Host.Children.Add(next.Root);
        InvalidateChrome();
        if (_onTop) next.Appearing();
    }

    /// <summary>Fetches the whole work behind a reader that opened on one chapter,
    /// retrying while AO3 is struggling, and waits for narration to stop before
    /// handing it over, so Listen isn't cut off. Null when the screen closed or
    /// AO3 never answered (the open chapter stays readable).</summary>
    protected async Task<AO3WorkPayload?> FetchRestAsync(int workId)
    {
        var ct = _lifetime.Token;
        AO3WorkPayload? full = null;
        for (var attempt = 0; full is null; attempt++)
        {
            try { full = await AppHost.Client.FetchWorkAsync(workId, ct); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { return null; }
            catch (Exception e)
            {
                AppHost.Log($"Loading the rest of work {workId} failed: {e.Message}");
                if (attempt >= 2) return null;
                try { await Task.Delay(TimeSpan.FromSeconds(30), ct); }
                catch (OperationCanceledException) { return null; }
            }
        }
        while (Reader is { IsListening: true } && !_removed)
        {
            try { await Task.Delay(TimeSpan.FromSeconds(2), ct); }
            catch (OperationCanceledException) { return null; }
        }
        return _removed ? null : full;
    }

    protected void ShowLoading(string message)
    {
        var ring = new ProgressRing { IsActive = true, Width = 32, Height = 32, Foreground = _brushes.Fg50 };
        var text = new TextBlock { Text = message, FontSize = 13.5, Foreground = _brushes.Fg60, HorizontalAlignment = HorizontalAlignment.Center };
        var stack = UI.UI.VStack(12, ring, text);
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        stack.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetName(ring, message);
        Host.Children.Clear();
        Host.Children.Add(stack);
        MainWindow.Current.Announce(message);
    }

    /// <summary>ContentUnavailableView in the reader's colours, with an optional Retry.</summary>
    protected void ShowError(string sfSymbol, string title, string message, Action? retry)
    {
        var icon = Symbols.Icon(sfSymbol, 44).A11yHidden();
        icon.Foreground = _brushes.Fg45;
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        var heading = new TextBlock
        {
            Text = title,
            FontSize = 18,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            Foreground = _brushes.Foreground,
            HorizontalAlignment = HorizontalAlignment.Center,
            TextAlignment = TextAlignment.Center,
        }.A11yHeading();
        var body = new TextBlock
        {
            Text = message,
            FontSize = 14,
            Foreground = _brushes.Fg65,
            TextWrapping = TextWrapping.Wrap,
            TextAlignment = TextAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
            MaxWidth = 440,
            IsTextSelectionEnabled = true,
        };
        var stack = UI.UI.VStack(10, icon, heading, body);
        if (retry is not null)
        {
            var button = UI.UI.Button("Retry", retry, kind: UI.UI.ButtonKind.Accent);
            button.HorizontalAlignment = HorizontalAlignment.Center;
            button.Margin = new Thickness(0, 6, 0, 0);
            stack.Children.Add(button);
        }
        stack.HorizontalAlignment = HorizontalAlignment.Center;
        stack.VerticalAlignment = VerticalAlignment.Center;
        stack.Padding = new Thickness(24);
        Host.Children.Clear();
        Host.Children.Add(stack);
        MainWindow.Current.Announce($"{title}. {message}");
    }

    public override void OnAppearing()
    {
        _onTop = true;
        Reader?.Appearing();
    }

    public override void OnDisappearing()
    {
        _onTop = false;
        Reader?.Disappearing();
    }

    public override void OnRemoved()
    {
        _removed = true;
        _lifetime.Cancel();
        Theme.Changed -= ApplyBackground;
        Reader?.Removed();
    }

    public override bool HandleKey(VirtualKey key, VirtualKeyModifiers modifiers) =>
        Reader?.HandleKey(key, modifiers) ?? false;

    public override bool WantsVolumeKeys => Reader?.WantsVolumeKeys ?? false;

    protected bool IsRemoved => _removed;
}
