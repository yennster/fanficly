using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
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

    /// <summary>True while volume keys should turn pages rather than change the
    /// volume ("Volume buttons turn pages"; see <c>Platform.VolumeKeyGate</c>).</summary>
    public virtual bool WantsVolumeKeys => false;

    // MARK: - Keyboard focus across navigation (#178)

    private WeakReference<UIElement>? _focusOnReturn;

    /// <summary>Notes which element has keyboard focus as another screen is pushed
    /// over this one, so Back can put it there again (UIKit's navigation stack
    /// does this for VoiceOver and Full Keyboard Access on the Apple app).</summary>
    internal void RememberFocus()
    {
        _focusOnReturn = null;
        if (!IsBuilt || View.XamlRoot is not { } root) return;
        if (FocusManager.GetFocusedElement(root) is UIElement focused && IsWithinView(focused))
            _focusOnReturn = new WeakReference<UIElement>(focused);
    }

    /// <summary>
    /// Moves keyboard focus into the screen once it's on top and loaded: back to
    /// the element that had it when <paramref name="returning"/> (Back), otherwise
    /// to the first thing that takes focus. Focus is set programmatically, so the
    /// focus rectangle shows only when the last input was the keyboard.
    /// </summary>
    /// <returns>False when nothing could take focus yet (the screen is still
    /// loading), so the window tries again as its content arrives.</returns>
    internal bool MoveFocusIn(bool returning)
    {
        var remembered = _focusOnReturn;
        _focusOnReturn = null;
        // A screen that focused something itself as it loaded (Login's first
        // field) keeps it.
        if (!returning && FocusIsWithinView()) return true;
        if (returning && RestoreFocus()) return true;
        if (returning && remembered?.TryGetTarget(out var previous) == true
            && previous is FrameworkElement { IsLoaded: true } && IsWithinView(previous)
            && previous.Focus(FocusState.Programmatic))
            return true;
        return FocusInitial();
    }

    /// <summary>Screens that rebuild their rows when they reappear (the Library)
    /// put focus back on the same row themselves; return true when handled.</summary>
    protected virtual bool RestoreFocus() => false;

    /// <summary>Focuses the screen's first focusable element that isn't a text
    /// box (a focused text box would swallow Esc and the screen's own keys).
    /// Returns false when there's none yet. The reader overrides this to leave
    /// the story, not a toolbar button, in charge of the arrow keys.</summary>
    protected virtual bool FocusInitial() =>
        IsBuilt && FirstFocusable(View)?.Focus(FocusState.Programmatic) == true;

    /// <summary>Retried while a screen loads: moves focus in once something can
    /// take it. <paramref name="stranded"/> is where focus sat when the first try
    /// failed; if the user has moved it anywhere else since, leave it.</summary>
    internal bool RetryFocusInitial(object? stranded)
    {
        if (FocusIsWithinView()) return true;
        if (!IsBuilt || View.XamlRoot is not { } root) return false;
        var focused = FocusManager.GetFocusedElement(root);
        if (focused is not null && !ReferenceEquals(focused, stranded) && focused is FrameworkElement { IsLoaded: true })
            return true;
        return FocusInitial();
    }

    private bool FocusIsWithinView() =>
        IsBuilt && View.XamlRoot is { } root && FocusManager.GetFocusedElement(root) is DependencyObject focused && IsWithinView(focused);

    private bool IsWithinView(DependencyObject element)
    {
        for (DependencyObject? node = element; node is not null; node = VisualTreeHelper.GetParent(node))
            if (ReferenceEquals(node, _view)) return true;
        return false;
    }

    /// <summary>The first visible, enabled tab stop under <paramref name="root"/>
    /// in tree order, skipping text entry.</summary>
    internal static Control? FirstFocusable(DependencyObject root)
    {
        if (root is UIElement { Visibility: Visibility.Collapsed }) return null;
        if (root is Control { IsTabStop: true, IsEnabled: true } control
            && control is not (TextBox or PasswordBox or AutoSuggestBox or RichEditBox))
            return control;
        if (root is TextBox or PasswordBox or AutoSuggestBox or RichEditBox) return null;
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < count; i++)
            if (FirstFocusable(VisualTreeHelper.GetChild(root, i)) is { } found) return found;
        return null;
    }

    /// <summary>Back was requested (Esc, Alt+←, mouse back, gamepad B). Return
    /// true to consume it, e.g. to close an inline panel first.</summary>
    public virtual bool HandleBack() => false;
}
