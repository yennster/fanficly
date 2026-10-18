using Fanficly.App.Shell;
using Fanficly.Core;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
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
/// toggles full screen. When the platform does deliver controller keys to
/// XAML (Xbox), this steps aside so nothing fires twice.
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

    private static void MoveFocus(FocusNavigationDirection direction)
    {
        var root = _window!.XamlRoot;
        if (root is null) return;
        if (FocusManager.GetFocusedElement(root) is null or Microsoft.UI.Xaml.Controls.ScrollViewer)
        {
            if (FocusManager.FindFirstFocusableElement(_window.RootElement) is Control first)
            {
                first.Focus(FocusState.Keyboard);
                return;
            }
        }
        var options = new FindNextElementOptions { SearchRoot = _window.RootElement, XYFocusNavigationStrategyOverride = XYFocusNavigationStrategyOverride.Projection };
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
        ScrollViewer? viewer = null;
        while (node is not null && viewer is null)
        {
            viewer = node as ScrollViewer;
            node = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(node);
        }
        viewer ??= FindScrollViewer(_window.Navigator.Current?.View);
        viewer?.ChangeView(viewer.HorizontalOffset + dx, viewer.VerticalOffset + dy, null, disableAnimation: true);
    }

    private static ScrollViewer? FindScrollViewer(DependencyObject? node)
    {
        if (node is null) return null;
        if (node is ScrollViewer sv) return sv;
        var count = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(node);
        for (var i = 0; i < count; i++)
            if (FindScrollViewer(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(node, i)) is { } found) return found;
        return null;
    }
}
