using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.System;

namespace Fanficly.App.Shell;

/// <summary>
/// One page in the detail column — the app's equivalent of a SwiftUI view
/// pushed on a NavigationStack. A screen builds its content once, names its
/// title, and offers toolbar items; the window draws the header and toolbar
/// around it, so every screen gets the same chrome.
/// </summary>
public abstract class Screen
{
    private FrameworkElement? _view;
    private string _title = "";

    /// <summary>Set by the navigator when the screen is pushed.</summary>
    public Navigator Navigator { get; internal set; } = null!;

    public string Title
    {
        get => _title;
        set { if (_title != value) { _title = value; ChromeChanged?.Invoke(); } }
    }

    /// <summary>Shown under the title in smaller text (a count, a fandom).</summary>
    public string? Subtitle { get; protected set; }

    /// <summary>False for screens that draw their own top chrome (the reader).</summary>
    public virtual bool ShowsHeader => true;

    /// <summary>Whether the window's sidebar may show beside this screen.</summary>
    public virtual bool PrefersFullWindow => false;

    /// <summary>Raised when the title or toolbar changed and the header must redraw.</summary>
    public event Action? ChromeChanged;

    public FrameworkElement View => _view ??= Build();

    public bool IsBuilt => _view is not null;

    protected abstract FrameworkElement Build();

    /// <summary>Toolbar items, right-aligned in the header (the nav bar's trailing items).</summary>
    public virtual IEnumerable<ICommandBarElement> PrimaryCommands() => [];

    /// <summary>Items in the toolbar's "…" overflow.</summary>
    public virtual IEnumerable<ICommandBarElement> SecondaryCommands() => [];

    /// <summary>Asks the window to rebuild this screen's header (title, toolbar).</summary>
    protected void InvalidateChrome() => ChromeChanged?.Invoke();

    public virtual void OnAppearing() { }
    public virtual void OnDisappearing() { }

    /// <summary>Called when the screen is popped for good.</summary>
    public virtual void OnRemoved() { }

    /// <summary>
    /// Window-level keys (arrows, Page Up/Down, gamepad shoulders) offered to the
    /// screen on top before anything else handles them. Return true to consume.
    /// </summary>
    public virtual bool HandleKey(VirtualKey key, VirtualKeyModifiers modifiers) => false;

    /// <summary>Back was requested (Esc, Alt+←, mouse back, gamepad B). Return
    /// true to consume it, e.g. to close an inline panel first.</summary>
    public virtual bool HandleBack() => false;
}
