using Fanficly.App.Shell;
using Fanficly.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Gaming.Input;
using Windows.System;

namespace Fanficly.App.Platform;

/// <summary>
/// Xbox / any XInput controller support for the desktop app. Desktop WinUI
/// doesn't turn controller input into focus navigation the way Xbox does, so
/// this polls <see cref="Gamepad"/> while the window is active and maps it:
/// D-pad / left stick move focus, A activates, B goes back, LB / RB switch
/// sidebar tabs, LT / RT turn pages (offered to the screen first, like the
/// arrow keys), the right stick scrolls, Menu opens the sidebar and View
/// toggles full screen. While a dialog, flyout, menu or drop-down is open
/// (they live in popups outside the window's tree) the D-pad moves focus
/// inside it, A activates, B closes it like Escape, the right stick scrolls
/// it, and nothing reaches the screen or the shell behind it (#167). When the
/// platform does deliver controller keys to XAML (Xbox), this steps aside so
/// nothing fires twice.
/// </summary>
public static class GamepadInput
{
    private const double StickThreshold = 0.6;
    private static readonly TimeSpan RepeatDelay = TimeSpan.FromMilliseconds(420);
    private static readonly TimeSpan RepeatInterval = TimeSpan.FromMilliseconds(110);

    private static Microsoft.UI.Dispatching.DispatcherQueueTimer? _timer;
    private static MainWindow? _window;
    private static GamepadButtons _previous;
    private static readonly Dictionary<GamepadButtons, DateTime> _heldSince = [];
    private static readonly Dictionary<GamepadButtons, DateTime> _lastRepeat = [];
    private static bool _windowActive = true;
    /// <summary>Submenus opened from the controller, innermost last, so B and
    /// D-pad left close them through their <see cref="MenuFlyoutSubItem"/>.</summary>
    private static readonly List<MenuFlyoutSubItem> _openSubmenus = [];
    /// <summary>What had focus in the window before a popup opened, to put
    /// focus back if closing the popup leaves it nowhere.</summary>
    private static WeakReference<Control>? _focusBeforePopup;

    /// <summary>True once XAML has delivered a gamepad key itself.</summary>
    public static bool XamlDeliversGamepad { get; private set; }

    /// <summary>Raised when a controller connects or disconnects (Settings shows its state).</summary>
    public static event Action? ControllersChanged;

    public static bool HasController => Gamepad.Gamepads.Count > 0;

    public static void Install(MainWindow window)
    {
        _window = window;
        Gamepad.GamepadAdded += (_, _) => window.DispatcherQueue.TryEnqueue(() => { UpdateTimer(); ControllersChanged?.Invoke(); });
        Gamepad.GamepadRemoved += (_, _) => window.DispatcherQueue.TryEnqueue(() => { UpdateTimer(); ControllersChanged?.Invoke(); });
        window.Activated += (_, e) =>
        {
            _windowActive = e.WindowActivationState != WindowActivationState.Deactivated;
            UpdateTimer();
        };
        window.RootElement.PreviewKeyDown += (_, e) =>
        {
            if (e.Key >= VirtualKey.GamepadA && e.Key <= VirtualKey.GamepadRightThumbstickLeft)
            {
                XamlDeliversGamepad = true;
                UpdateTimer();
            }
        };
        UpdateTimer();
    }

    private static void UpdateTimer()
    {
        var shouldRun = _window is not null && _windowActive && HasController && !XamlDeliversGamepad;
        if (shouldRun && _timer is null)
        {
            _timer = _window!.DispatcherQueue.CreateTimer();
            _timer.Interval = TimeSpan.FromMilliseconds(16);
            _timer.Tick += (_, _) => Poll();
            _timer.Start();
        }
        else if (!shouldRun && _timer is not null)
        {
            _timer.Stop();
            _timer = null;
            _previous = GamepadButtons.None;
        }
    }

    private static void Poll()
    {
        if (_window is null || Gamepad.Gamepads.Count == 0) return;
        var reading = Gamepad.Gamepads[0].GetCurrentReading();
        var buttons = reading.Buttons;

        // The left stick and triggers act as extra buttons.
        if (reading.LeftThumbstickY > StickThreshold) buttons |= GamepadButtons.DPadUp;
        if (reading.LeftThumbstickY < -StickThreshold) buttons |= GamepadButtons.DPadDown;
        if (reading.LeftThumbstickX < -StickThreshold) buttons |= GamepadButtons.DPadLeft;
        if (reading.LeftThumbstickX > StickThreshold) buttons |= GamepadButtons.DPadRight;
        const GamepadButtons LeftTrigger = (GamepadButtons)0x10000, RightTrigger = (GamepadButtons)0x20000;
        if (reading.LeftTrigger > 0.5) buttons |= LeftTrigger;
        if (reading.RightTrigger > 0.5) buttons |= RightTrigger;

        var now = DateTime.UtcNow;
        foreach (var button in new[]
        {
            GamepadButtons.DPadUp, GamepadButtons.DPadDown, GamepadButtons.DPadLeft, GamepadButtons.DPadRight,
            GamepadButtons.A, GamepadButtons.B, GamepadButtons.X, GamepadButtons.Y,
            GamepadButtons.LeftShoulder, GamepadButtons.RightShoulder, GamepadButtons.Menu, GamepadButtons.View,
            LeftTrigger, RightTrigger,
        })
        {
            var down = buttons.HasFlag(button);
            var wasDown = _previous.HasFlag(button);
            if (down && !wasDown)
            {
                _heldSince[button] = now;
                _lastRepeat[button] = now;
                Press(button);
            }
            else if (down && IsRepeatable(button) && now - _heldSince[button] > RepeatDelay && now - _lastRepeat[button] > RepeatInterval)
            {
                _lastRepeat[button] = now;
                Press(button);
            }
        }
        _previous = buttons;

        // Right stick scrolls whatever scrolls around the focused element.
        if (Math.Abs(reading.RightThumbstickY) > 0.2 || Math.Abs(reading.RightThumbstickX) > 0.2)
            Scroll(-reading.RightThumbstickY * 22, reading.RightThumbstickX * 22);
    }

    private static bool IsRepeatable(GamepadButtons b) =>
        b is GamepadButtons.DPadUp or GamepadButtons.DPadDown or GamepadButtons.DPadLeft or GamepadButtons.DPadRight;

    private static void Press(GamepadButtons button)
    {
        var window = _window!;
        var screen = window.Navigator.Current;
        var key = button switch
        {
            GamepadButtons.DPadUp => VirtualKey.GamepadDPadUp,
            GamepadButtons.DPadDown => VirtualKey.GamepadDPadDown,
            GamepadButtons.DPadLeft => VirtualKey.GamepadDPadLeft,
            GamepadButtons.DPadRight => VirtualKey.GamepadDPadRight,
            GamepadButtons.A => VirtualKey.GamepadA,
            GamepadButtons.B => VirtualKey.GamepadB,
            GamepadButtons.X => VirtualKey.GamepadX,
            GamepadButtons.Y => VirtualKey.GamepadY,
            GamepadButtons.LeftShoulder => VirtualKey.GamepadLeftShoulder,
            GamepadButtons.RightShoulder => VirtualKey.GamepadRightShoulder,
            GamepadButtons.Menu => VirtualKey.GamepadMenu,
            GamepadButtons.View => VirtualKey.GamepadView,
            (GamepadButtons)0x10000 => VirtualKey.GamepadLeftTrigger,
            _ => VirtualKey.GamepadRightTrigger,
        };
        // A dialog, flyout or drop-down is on top: keep the controller inside it.
        if (ModalPopup() is { } popup)
        {
            switch (key)
            {
                case VirtualKey.GamepadDPadUp: MoveFocus(FocusNavigationDirection.Up, popup); break;
                case VirtualKey.GamepadDPadDown: MoveFocus(FocusNavigationDirection.Down, popup); break;
                case VirtualKey.GamepadDPadLeft:
                    if (!CloseSubmenu(popup)) MoveFocus(FocusNavigationDirection.Left, popup);
                    break;
                case VirtualKey.GamepadDPadRight:
                    if (!OpenSubmenu()) MoveFocus(FocusNavigationDirection.Right, popup);
                    break;
                case VirtualKey.GamepadA: Activate(); break;
                case VirtualKey.GamepadB: Dismiss(popup); break;
            }
            return;
        }

        _openSubmenus.Clear();
        if (window.XamlRoot is { } xamlRoot && FocusManager.GetFocusedElement(xamlRoot) is Control mainFocus)
            _focusBeforePopup = new(mainFocus);

        // The screen gets first refusal (the reader turns pages on D-pad / triggers).
        if (screen?.HandleKey(key, VirtualKeyModifiers.None) == true) return;

        switch (key)
        {
            case VirtualKey.GamepadDPadUp: MoveFocus(FocusNavigationDirection.Up); break;
            case VirtualKey.GamepadDPadDown: MoveFocus(FocusNavigationDirection.Down); break;
            case VirtualKey.GamepadDPadLeft: MoveFocus(FocusNavigationDirection.Left); break;
            case VirtualKey.GamepadDPadRight: MoveFocus(FocusNavigationDirection.Right); break;
            case VirtualKey.GamepadA: Activate(); break;
            case VirtualKey.GamepadB: window.GoBack(); break;
            case VirtualKey.GamepadLeftShoulder: StepTab(-1); break;
            case VirtualKey.GamepadRightShoulder: StepTab(1); break;
            case VirtualKey.GamepadMenu: window.ToggleSidebar(); break;
            case VirtualKey.GamepadView: window.ToggleFullScreen(); break;
        }
    }

    private static void StepTab(int delta)
    {
        var all = SidebarItems.All;
        var index = Array.IndexOf(all, _window!.SelectedItem);
        _window.Select(all[(index + delta + all.Length) % all.Length]);
        _window.Announce(_window.SelectedItem.Title());
    }

    /// <summary>The open popup the controller should stay in: a ContentDialog,
    /// flyout, context menu or drop-down. Tooltips and popups with nothing to
    /// focus (a dialog's smoke layer) don't count. The one holding focus wins,
    /// so a menu opened from inside a dialog comes before the dialog.</summary>
    private static Popup? ModalPopup()
    {
        var root = _window!.XamlRoot;
        if (root is null) return null;
        var focused = FocusManager.GetFocusedElement(root) as DependencyObject;
        Popup? fallback = null;
        foreach (var popup in VisualTreeHelper.GetOpenPopupsForXamlRoot(root))
        {
            if (!popup.IsOpen || popup.Child is null or ToolTip) continue;
            if (FocusManager.FindFirstFocusableElement(popup.Child) is null) continue;
            if (IsInside(focused, popup.Child)) return popup;
            fallback ??= popup;
        }
        return fallback;
    }

    private static bool IsInside(DependencyObject? node, DependencyObject container)
    {
        for (; node is not null; node = VisualTreeHelper.GetParent(node))
            if (ReferenceEquals(node, container)) return true;
        return false;
    }

    /// <summary>"B" over a popup: close it the way Escape would, rather than
    /// going back on the page underneath.</summary>
    private static void Dismiss(Popup popup)
    {
        if (CloseSubmenu(popup)) return;
        // A ContentDialog closes through Hide so its Closing handlers run
        // (the import dialog cancels its import there).
        if (FindDescendant<ContentDialog>(popup.Child) is { } dialog)
        {
            dialog.Hide();
            return;
        }
        // A templated popup (a ComboBox's drop-down, an AutoSuggestBox's
        // suggestion list) belongs to its control: close it through the control
        // so the control's own state stays in step.
        for (DependencyObject? node = popup; node is not null; node = VisualTreeHelper.GetParent(node))
        {
            switch (node)
            {
                case ComboBox combo: combo.IsDropDownOpen = false; combo.Focus(FocusState.Keyboard); return;
                case AutoSuggestBox box: box.IsSuggestionListOpen = false; return;
            }
        }
        // Flyouts and menus: closing their popup closes the flyout. Every open
        // menu level goes, as Escape on a menu bar's flyout would leave the
        // parent stale otherwise.
        popup.IsOpen = false;
        if (popup.Child is MenuFlyoutPresenter && VisualTreeHelper.GetOpenPopupsForXamlRoot(_window!.XamlRoot) is { } open)
            foreach (var other in open)
                if (other.Child is MenuFlyoutPresenter) other.IsOpen = false;
        _openSubmenus.Clear();
        RestoreFocusSoon();
    }

    /// <summary>Puts focus back on what had it before the popup opened when
    /// closing the popup left focus nowhere (WinUI usually does this itself).</summary>
    private static void RestoreFocusSoon()
    {
        _window!.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            var root = _window.XamlRoot;
            if (root is null || ModalPopup() is not null) return;
            if (FocusManager.GetFocusedElement(root) is UIElement { XamlRoot: not null }) return;
            if (_focusBeforePopup?.TryGetTarget(out var previous) == true && previous.IsLoaded)
                previous.Focus(FocusState.Keyboard);
        });
    }

    /// <summary>A on a <see cref="MenuFlyoutSubItem"/>, or D-pad right: open its
    /// submenu and move focus into it (automation's Expand opens it but leaves
    /// focus on the parent menu, where the D-pad can't reach the new items).</summary>
    private static bool OpenSubmenu()
    {
        var root = _window!.XamlRoot;
        if (root is null || FocusManager.GetFocusedElement(root) is not MenuFlyoutSubItem sub) return false;
        var before = new HashSet<Popup>(VisualTreeHelper.GetOpenPopupsForXamlRoot(root));
        if ((FrameworkElementAutomationPeer.FromElement(sub) ?? FrameworkElementAutomationPeer.CreatePeerForElement(sub))
            ?.GetPattern(PatternInterface.ExpandCollapse) is not IExpandCollapseProvider expand) return false;
        expand.Expand();
        _openSubmenus.Remove(sub);
        _openSubmenus.Add(sub);
        // The submenu's popup opens on a later frame.
        _window.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
        {
            foreach (var popup in VisualTreeHelper.GetOpenPopupsForXamlRoot(root))
            {
                if (before.Contains(popup) || popup.Child is not MenuFlyoutPresenter) continue;
                if (FocusManager.FindFirstFocusableElement(popup.Child) is Control first) first.Focus(FocusState.Keyboard);
                return;
            }
        });
        return true;
    }

    /// <summary>B or D-pad left inside a submenu the controller opened: close
    /// just that level and put focus back on its <see cref="MenuFlyoutSubItem"/>.</summary>
    private static bool CloseSubmenu(Popup focusedPopup)
    {
        while (_openSubmenus.Count > 0)
        {
            var sub = _openSubmenus[^1];
            _openSubmenus.RemoveAt(_openSubmenus.Count - 1);
            if (!sub.IsLoaded || IsInside(sub, focusedPopup.Child)) continue; // stale, or focus is on the item itself
            if ((FrameworkElementAutomationPeer.FromElement(sub) ?? FrameworkElementAutomationPeer.CreatePeerForElement(sub))
                ?.GetPattern(PatternInterface.ExpandCollapse) is IExpandCollapseProvider expand
                && expand.ExpandCollapseState != Microsoft.UI.Xaml.Automation.ExpandCollapseState.Collapsed)
            {
                expand.Collapse();
                sub.Focus(FocusState.Keyboard);
                return true;
            }
        }
        return false;
    }

    private static T? FindDescendant<T>(DependencyObject? node) where T : DependencyObject
    {
        if (node is null) return null;
        if (node is T match) return match;
        var count = VisualTreeHelper.GetChildrenCount(node);
        for (var i = 0; i < count; i++)
            if (FindDescendant<T>(VisualTreeHelper.GetChild(node, i)) is { } found) return found;
        return null;
    }

    /// <summary>Moves focus in the window, or only inside <paramref name="popup"/>
    /// when one is open (a popup isn't under the window's root, so a search
    /// there never finds the dialog's buttons).</summary>
    private static void MoveFocus(FocusNavigationDirection direction, Popup? popup = null)
    {
        var root = _window!.XamlRoot;
        if (root is null) return;
        DependencyObject searchRoot = popup?.Child ?? _window.RootElement;
        var focused = FocusManager.GetFocusedElement(root);
        if (focused is null or ScrollViewer || (popup is not null && !IsInside(focused as DependencyObject, searchRoot)))
        {
            if (FocusManager.FindFirstFocusableElement(searchRoot) is Control first)
            {
                first.Focus(FocusState.Keyboard);
                return;
            }
        }
        var options = new FindNextElementOptions { SearchRoot = searchRoot, XYFocusNavigationStrategyOverride = XYFocusNavigationStrategyOverride.Projection };
        if (!FocusManager.TryMoveFocus(direction, options) && direction is FocusNavigationDirection.Up or FocusNavigationDirection.Down)
            Scroll(direction == FocusNavigationDirection.Down ? 120 : -120, 0);
    }

    /// <summary>"A": invoke, toggle, expand or select whatever has focus.</summary>
    private static void Activate()
    {
        var root = _window!.XamlRoot;
        if (root is null || FocusManager.GetFocusedElement(root) is not UIElement focused) return;
        if (focused is TextBox or PasswordBox or AutoSuggestBox) return; // the touch keyboard takes it
        var peer = FrameworkElementAutomationPeer.FromElement(focused) ?? FrameworkElementAutomationPeer.CreatePeerForElement(focused);
        if (peer is null) return;
        if (focused is MenuFlyoutSubItem && OpenSubmenu()) return;
        // A drop-down item: pick it and close the list, as Enter would.
        if (focused is ComboBoxItem item && ItemsControl.ItemsControlFromItemContainer(item) is ComboBox combo)
        {
            combo.SelectedItem = combo.ItemFromContainer(item);
            combo.IsDropDownOpen = false;
            combo.Focus(FocusState.Keyboard);
            return;
        }
        if (peer.GetPattern(PatternInterface.Invoke) is IInvokeProvider invoke) { invoke.Invoke(); return; }
        if (peer.GetPattern(PatternInterface.Toggle) is IToggleProvider toggle) { toggle.Toggle(); return; }
        if (peer.GetPattern(PatternInterface.ExpandCollapse) is IExpandCollapseProvider expand)
        {
            if (expand.ExpandCollapseState == Microsoft.UI.Xaml.Automation.ExpandCollapseState.Collapsed) expand.Expand(); else expand.Collapse();
            return;
        }
        if (peer.GetPattern(PatternInterface.SelectionItem) is ISelectionItemProvider select) select.Select();
    }

    private static void Scroll(double dy, double dx)
    {
        var root = _window!.XamlRoot;
        DependencyObject? node = root is null ? null : FocusManager.GetFocusedElement(root) as DependencyObject;
        // With a popup open, scroll inside it (a long dialog), never the page behind it.
        var popup = ModalPopup();
        if (popup is not null && !IsInside(node, popup.Child)) node = null;
        ScrollViewer? viewer = null;
        while (node is not null && viewer is null)
        {
            viewer = node as ScrollViewer;
            node = VisualTreeHelper.GetParent(node);
        }
        viewer ??= FindDescendant<ScrollViewer>(popup is not null ? popup.Child : _window.Navigator.Current?.View);
        viewer?.ChangeView(viewer.HorizontalOffset + dx, viewer.VerticalOffset + dy, null, disableAnimation: true);
    }
}
