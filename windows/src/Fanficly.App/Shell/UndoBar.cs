using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Fanficly.App.Shell;

/// <summary>
/// The "Deleted 'X' · Undo" InfoBar for <see cref="UndoQueue.Shared"/> (#169),
/// the Swift app's <c>UndoToast</c>. It shows in the innermost host: the
/// window's message area, or a sheet's own area while one is open (a
/// <c>ContentDialog</c> covers the window's), and moves back to the window when
/// the sheet closes. The waiting delete runs when the bar closes: after
/// <see cref="Delay"/>, its close button, another delete, or the app closing.
/// The countdown starts again while the pointer or keyboard focus is on the bar,
/// so there's time to read it and reach Undo.
/// </summary>
internal static class UndoBar
{
    /// <summary>Swift's 6 s (VoiceOver gets 12 s there; here the countdown
    /// waits while focus is on the bar instead).</summary>
    public static readonly TimeSpan Delay = TimeSpan.FromSeconds(6);

    private static readonly List<Panel> Hosts = [];
    private static InfoBar? _bar;
    private static DispatcherQueueTimer? _timer;
    private static bool _held;

    /// <summary>Called once from <see cref="MainWindow"/>, with its message area.</summary>
    public static void Install(Panel windowHost)
    {
        Hosts.Add(windowHost);
        UndoQueue.Shared.Changed += OnChanged;
    }

    /// <summary>A sheet's own message area, innermost until <see cref="PopHost"/>.</summary>
    public static void PushHost(Panel host)
    {
        Hosts.Remove(host);
        Hosts.Add(host);
        Move();
    }

    public static void PopHost(Panel host)
    {
        Hosts.Remove(host);
        Move();
    }

    private static void OnChanged(UndoQueue.Pending? pending, LibraryEntityKinds kinds)
    {
        // The hidden rows' screens redraw (they skip IsPending keys).
        AppHost.Library.NotifyChanged(kinds);
        Close();
        if (pending is null) return;

        var undo = UI.UI.Button("Undo", () => UndoQueue.Shared.Undo(pending.Id), kind: UI.UI.ButtonKind.Subtle);
        AutomationProperties.SetAutomationId(undo, "undo.button");
        AutomationProperties.SetHelpText(undo, "Puts it back");
        ToolTipService.SetToolTip(undo, "Undo the delete (Ctrl+Z)");
        var bar = UI.UI.Banner(pending.Message, severity: InfoBarSeverity.Informational);
        bar.ActionButton = undo;
        bar.Background = Theme.CardBackground;
        bar.Shadow = new ThemeShadow();
        AutomationProperties.SetAutomationId(bar, "undo.bar");
        // The close button keeps the delete, like the bar timing out.
        bar.Closed += (_, _) => { if (ReferenceEquals(_bar, bar)) UndoQueue.Shared.Commit(pending.Id); };
        bar.PointerEntered += (_, _) => Hold(true);
        bar.PointerExited += (_, _) => Hold(false);
        bar.GotFocus += (_, _) => Hold(true);
        bar.LostFocus += (_, _) => Hold(false);
        _bar = bar;
        Hosts.LastOrDefault()?.Children.Add(bar);
        MainWindow.Current?.Announce($"{pending.Message}. Undo is available.");

        var timer = DispatcherQueue.GetForCurrentThread().CreateTimer();
        timer.Interval = Delay;
        timer.IsRepeating = false;
        timer.Tick += (_, _) => { if (!_held) UndoQueue.Shared.Commit(pending.Id); };
        _timer = timer;
        _held = false;
        timer.Start();
    }

    private static void Hold(bool held)
    {
        _held = held;
        if (_timer is null) return;
        // Starting again resets the interval: a full Delay after leaving the bar.
        _timer.Stop();
        if (!held) _timer.Start();
    }

    private static void Close()
    {
        _timer?.Stop();
        _timer = null;
        _held = false;
        if (_bar is not { } bar) return;
        _bar = null;
        (bar.Parent as Panel)?.Children.Remove(bar);
    }

    private static void Move()
    {
        if (_bar is not { } bar || Hosts.LastOrDefault() is not { } host || ReferenceEquals(bar.Parent, host)) return;
        (bar.Parent as Panel)?.Children.Remove(bar);
        host.Children.Add(bar);
    }
}
