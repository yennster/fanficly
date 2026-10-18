using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;
using Windows.System;
using Windows.UI.Core;

namespace Fanficly.App.Shell;

/// <summary>
/// The app window: a Windows 11 title bar, the sidebar (NavigationView: a full
/// sidebar when wide, icons when narrower, a flyout pane when narrow — the
/// Mac app's split view on Windows terms), and the detail column with its
/// header and toolbar. Holds the global UI zoom (Ctrl +/−/0) and the "Go"
/// shortcuts (Ctrl+1…9, Ctrl+,).
/// </summary>
public sealed partial class MainWindow : Window
{
    public static new MainWindow Current { get; private set; } = null!;

    public Navigator Navigator { get; } = new();
    public SidebarItem SelectedItem { get; private set; } = SidebarItem.Search;

    private void UpdatePaneToggle(NavigationViewDisplayMode mode)
    {
        var minimal = mode == NavigationViewDisplayMode.Minimal;
        _nav.IsPaneToggleButtonVisible = !minimal;
        _titleBar.IsPaneToggleButtonVisible = minimal;
    }

    /// <summary>The root element; dialogs and flyouts anchor to its XamlRoot.</summary>
    public Grid RootElement { get; }
    public XamlRoot XamlRoot => RootElement.XamlRoot;

    /// <summary>Raised whenever a different screen comes to the top.</summary>
    public event Action<Screen?>? ScreenChanged;

    private const string SelectedTabKey = "app.selectedTabRaw";
    private const string ZoomKey = "app.zoomScale";
    private const string BoundsKey = "app.windowBounds";

    private readonly TitleBar _titleBar;
    private readonly NavigationView _nav;
    private readonly Dictionary<SidebarItem, NavigationViewItem> _navItems = [];
    private readonly Dictionary<SidebarItem, Screen> _roots = [];
    private readonly Grid _zoomHost;
    private readonly Grid _zoomContent;
    private readonly Grid _header;
    private readonly TextBlock _headerTitle;
    private readonly TextBlock _headerSubtitle;
    private readonly CommandBar _commandBar;
    private readonly ContentPresenter _body;
    private readonly StackPanel _messages;

    /// <summary>The floating stack at the bottom of the detail column (in-app
    /// messages, the restore progress card).</summary>
    public Panel MessagesHost => _messages;
    private Screen? _shown;
    private bool _suppressSelection;
    private double _zoom = 1;

    /// <summary>Builds each tab's root screen; set by the app before the window opens.</summary>
    public Func<SidebarItem, Screen> RootFactory { get; set; } = item => new PlaceholderScreen(item.Title());

    public MainWindow()
    {
        Current = this;
        Title = "Fanficly";
        AppWindow.Title = "Fanficly";
        try { AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Fanficly.ico")); } catch { }
        ExtendsContentIntoTitleBar = true;
        if (MicaController.IsSupported()) SystemBackdrop = new MicaBackdrop();
        else if (DesktopAcrylicController.IsSupported()) SystemBackdrop = new DesktopAcrylicBackdrop();

        // Title bar: app icon + name, back, and the sidebar toggle.
        _titleBar = new TitleBar
        {
            Title = "Fanficly",
            IsBackButtonVisible = true,
            IsBackButtonEnabled = false,
            IsPaneToggleButtonVisible = false,
            IconSource = new ImageIconSource { ImageSource = new BitmapImage(new Uri("ms-appx:///Assets/Square44x44Logo.targetsize-32.png")) },
        };
        AutomationProperties.SetAutomationId(_titleBar, "titleBar");
        _titleBar.BackRequested += (_, _) => GoBack();
        _titleBar.PaneToggleRequested += (_, _) => _nav!.IsPaneOpen = !_nav.IsPaneOpen;

        // Detail column: header (title + toolbar) over the screen's content.
        _headerTitle = new TextBlock
        {
            FontSize = 24,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            FontFamily = Theme.DisplayFont,
            TextTrimming = TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            VerticalAlignment = VerticalAlignment.Center,
        };
        AutomationProperties.SetAutomationId(_headerTitle, "header.title");
        AutomationProperties.SetHeadingLevel(_headerTitle, Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        _headerSubtitle = new TextBlock { FontSize = 12.5, Foreground = Theme.TextSecondary, TextTrimming = TextTrimming.CharacterEllipsis };
        _commandBar = new CommandBar
        {
            DefaultLabelPosition = CommandBarDefaultLabelPosition.Collapsed,
            Background = Theme.Transparent,
            IsDynamicOverflowEnabled = true,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        AutomationProperties.SetAutomationId(_commandBar, "header.commands");
        _header = UI.UI.Grid("*,Auto", columnSpacing: 12);
        _header.Padding = new Thickness(24, 6, 12, 6);
        _header.MinHeight = 52;
        _header.Children.Add(UI.UI.VStack(0, _headerTitle, _headerSubtitle).Also(s => s.VerticalAlignment = VerticalAlignment.Center).Col(0));
        _header.Children.Add(_commandBar.Col(1));

        _body = new ContentPresenter
        {
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Stretch,
        };
        var detail = UI.UI.Grid("*", "Auto,*");
        detail.Children.Add(_header.Row(0));
        detail.Children.Add(_body.Row(1));

        // In-app messages float at the bottom of the detail column.
        _messages = new StackPanel
        {
            Spacing = 8,
            VerticalAlignment = VerticalAlignment.Bottom,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(16, 0, 16, 20),
            MaxWidth = 520,
        };
        detail.Children.Add(_messages.Row(0, 2));

        _nav = new NavigationView
        {
            PaneDisplayMode = NavigationViewPaneDisplayMode.Auto,
            IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
            IsPaneToggleButtonVisible = true,
            IsSettingsVisible = false,
            IsTitleBarAutoPaddingEnabled = false,
            OpenPaneLength = 248,
            CompactModeThresholdWidth = 641,
            ExpandedModeThresholdWidth = 1008,
            Content = detail,
        };
        foreach (var item in SidebarItems.All)
        {
            var navItem = new NavigationViewItem
            {
                Content = item.Title(),
                Icon = Symbols.Icon(item.Symbol()),
                Tag = item.RawValue(),
            };
            ToolTipService.SetToolTip(navItem, $"{item.Title()} ({item.ShortcutText()})");
            AutomationProperties.SetAutomationId(navItem, $"sidebar.{item.RawValue()}");
            AutomationProperties.SetAcceleratorKey(navItem, item.ShortcutText());
            _navItems[item] = navItem;
            if (item == SidebarItem.Settings) _nav.FooterMenuItems.Add(navItem);
            else _nav.MenuItems.Add(navItem);
        }
        // In a narrow window the sidebar folds away and its menu button moves
        // into the title bar (as in Windows' own apps), so it never sits over
        // the screen header.
        _nav.DisplayModeChanged += (_, args) => UpdatePaneToggle(args.DisplayMode);
        _nav.SelectionChanged += (_, args) =>
        {
            if (_suppressSelection) return;
            if (args.SelectedItem is NavigationViewItem { Tag: string raw } && SidebarItems.FromRaw(raw) is { } item)
                Select(item);
        };
        // A tap on the already-selected tab pops back to its root, like the Mac sidebar.
        _nav.ItemInvoked += (_, args) =>
        {
            if (args.InvokedItemContainer is NavigationViewItem { Tag: string raw } && SidebarItems.FromRaw(raw) is { } item && item == SelectedItem)
                ShowRoot(item);
        };

        _zoomContent = new Grid { HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
        _zoomContent.Children.Add(_nav);
        _zoomHost = new Grid();
        _zoomHost.Children.Add(_zoomContent);
        _zoomHost.SizeChanged += (_, _) => ApplyZoom();

        RootElement = UI.UI.Grid("*", "Auto,*");
        RootElement.Children.Add(_titleBar.Row(0));
        RootElement.Children.Add(_zoomHost.Row(1));
        Content = Platform.CaptureMode.Wrap(this, RootElement);
        SetTitleBar(_titleBar);
        if (Platform.CaptureMode.IsOn) _titleBar.RightHeader = Platform.CaptureMode.CaptionGlyphs();

        RootElement.ActualThemeChanged += (_, _) => Theme.Apply(RootElement.ActualTheme);
        RootElement.Loaded += (_, _) => Theme.Apply(RootElement.ActualTheme);
        Theme.Apply(Application.Current.RequestedTheme == ApplicationTheme.Dark ? ElementTheme.Dark : ElementTheme.Light);

        Navigator.Changed += OnNavigatorChanged;
        InstallKeyboard();
        RootElement.PointerPressed += (_, e) =>
        {
            // Mouse "back" button.
            var props = e.GetCurrentPoint(RootElement).Properties;
            if (props.IsXButton1Pressed) { e.Handled = GoBack(); }
        };

        _zoom = UiZoom.Clamped(KeyValueStores.Default.GetDouble(ZoomKey, UiZoom.ActualSize));
        RestoreBounds();
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = 360;
            presenter.PreferredMinimumHeight = 480;
        }
        AppWindow.Closing += (_, _) => SaveBounds();
    }

    /// <summary>Opens the tab stored last time (or <paramref name="initial"/>).</summary>
    public void Start(SidebarItem? initial = null)
    {
        var stored = SidebarItems.FromRaw(KeyValueStores.Default.GetString(SelectedTabKey));
        Select(initial ?? stored ?? SidebarItem.Search);
    }

    // MARK: - Tabs

    /// <summary>Shows a tab, clearing anything pushed on it.</summary>
    public void Select(SidebarItem item)
    {
        SelectedItem = item;
        // UI tests read the open tab here: the sidebar items aren't in the
        // automation tree while the sidebar is folded into its menu button.
        AutomationProperties.SetItemStatus(_headerTitle, $"tab:{item.RawValue()}");
        KeyValueStores.Default.SetString(SelectedTabKey, item.RawValue());
        _suppressSelection = true;
        _nav.SelectedItem = _navItems[item];
        _suppressSelection = false;
        ShowRoot(item);
        if (_nav.DisplayMode == NavigationViewDisplayMode.Minimal) _nav.IsPaneOpen = false;
    }

    private void ShowRoot(SidebarItem item)
    {
        if (!_roots.TryGetValue(item, out var root))
        {
            root = RootFactory(item);
            if (string.IsNullOrEmpty(root.Title)) root.Title = item.Title();
            _roots[item] = root;
        }
        Navigator.SetRoot(root);
    }

    /// <summary>The cached root screen of a tab, if it has been opened.</summary>
    public T? RootScreen<T>(SidebarItem item) where T : Screen =>
        _roots.TryGetValue(item, out var s) ? s as T : null;

    /// <summary>Drops a tab's cached root so it rebuilds next time (sign-in changes).</summary>
    public void ResetRoot(SidebarItem item)
    {
        _roots.Remove(item);
        if (SelectedItem == item && Navigator.Depth <= 1) ShowRoot(item);
    }

    public bool GoBack()
    {
        if (Navigator.Current?.HandleBack() == true) return true;
        return Navigator.GoBack();
    }

    private void OnNavigatorChanged(bool forward)
    {
        if (_shown is not null) _shown.ChromeChanged -= RefreshChrome;
        var screen = Navigator.Current;
        _shown = screen;
        if (screen is not null) screen.ChromeChanged += RefreshChrome;

        _body.ContentTransitions = new TransitionCollection
        {
            new EntranceThemeTransition { FromHorizontalOffset = forward ? 40 : -40, FromVerticalOffset = 0, IsStaggeringEnabled = false },
        };
        var view = screen?.View;
        if (view?.Parent is ContentPresenter old && old != _body) old.Content = null;
        _body.Content = view;
        RefreshChrome();
        _titleBar.IsBackButtonEnabled = Navigator.CanGoBack;
        ScreenChanged?.Invoke(screen);
    }

    private void RefreshChrome()
    {
        var screen = Navigator.Current;
        _header.Visibility = screen?.ShowsHeader == false ? Visibility.Collapsed : Visibility.Visible;
        _headerTitle.Text = screen?.Title ?? "";
        _headerSubtitle.Text = screen?.Subtitle ?? "";
        _headerSubtitle.Visibility = string.IsNullOrEmpty(screen?.Subtitle) ? Visibility.Collapsed : Visibility.Visible;
        _commandBar.PrimaryCommands.Clear();
        _commandBar.SecondaryCommands.Clear();
        if (screen is null) return;
        foreach (var c in screen.PrimaryCommands()) _commandBar.PrimaryCommands.Add(c);
        foreach (var c in screen.SecondaryCommands()) _commandBar.SecondaryCommands.Add(c);
        _commandBar.OverflowButtonVisibility = _commandBar.SecondaryCommands.Count > 0
            ? CommandBarOverflowButtonVisibility.Visible
            : CommandBarOverflowButtonVisibility.Collapsed;
        Title = screen.Title.Length > 0 && Navigator.CanGoBack ? $"{screen.Title} – Fanficly" : "Fanficly";
        AppWindow.Title = Title;
    }

    /// <summary>Shows or hides the sidebar and title bar (the reader's full screen).</summary>
    public void SetChromeHidden(bool hidden)
    {
        _nav.IsPaneVisible = !hidden;
        _titleBar.Visibility = hidden ? Visibility.Collapsed : Visibility.Visible;
    }

    public void ToggleSidebar()
    {
        if (_nav.DisplayMode == NavigationViewDisplayMode.Expanded) _nav.IsPaneOpen = !_nav.IsPaneOpen;
        else _nav.IsPaneOpen = !_nav.IsPaneOpen;
    }

    public bool IsFullScreen => AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen;

    public void ToggleFullScreen() =>
        AppWindow.SetPresenter(IsFullScreen ? AppWindowPresenterKind.Default : AppWindowPresenterKind.FullScreen);

    // MARK: - In-app messages

    /// <summary>A short, self-dismissing message at the bottom of the window
    /// (and announced to Narrator).</summary>
    public void ShowMessage(string title, string? message = null, InfoBarSeverity severity = InfoBarSeverity.Success, int seconds = 4)
    {
        var bar = UI.UI.Banner(title, message, severity);
        bar.Background = Theme.CardBackground;
        bar.Shadow = new ThemeShadow();
        _messages.Children.Add(bar);
        Announce(message is null ? title : $"{title}. {message}");
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(seconds);
        timer.IsRepeating = false;
        timer.Tick += (_, _) => _messages.Children.Remove(bar);
        bar.Closed += (_, _) => _messages.Children.Remove(bar);
        timer.Start();
    }

    /// <summary>Narrator announcement (UIAccessibility.post(.announcement)).</summary>
    public void Announce(string text)
    {
        var peer = Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.FromElement(_headerTitle)
                   ?? Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.CreatePeerForElement(_headerTitle);
        peer?.RaiseNotificationEvent(
            Microsoft.UI.Xaml.Automation.Peers.AutomationNotificationKind.Other,
            Microsoft.UI.Xaml.Automation.Peers.AutomationNotificationProcessing.ImportantMostRecent,
            text, "fanficly.announcement");
    }

    // MARK: - Zoom (the Mac app's ⌘ / ⇧⌘ +/− and ⌘0)

    public double Zoom => _zoom;

    public void ZoomIn() => SetZoom(UiZoom.Stepped(_zoom, forward: true));
    public void ZoomOut() => SetZoom(UiZoom.Stepped(_zoom, forward: false));
    public void ResetZoom() => SetZoom(UiZoom.ActualSize);

    private void SetZoom(double value)
    {
        _zoom = value;
        KeyValueStores.Default.SetDouble(ZoomKey, value);
        ApplyZoom();
        Announce($"Zoom {Math.Round(value * 100)}%");
    }

    private void ApplyZoom()
    {
        var w = _zoomHost.ActualWidth;
        var h = _zoomHost.ActualHeight;
        if (w <= 0 || h <= 0) return;
        if (Math.Abs(_zoom - 1) < 0.001)
        {
            _zoomContent.Width = w;
            _zoomContent.Height = h;
            _zoomContent.RenderTransform = null;
            return;
        }
        // Lay the UI out in a smaller (or larger) box and scale it to fill the
        // window, so everything — text, icons, hit targets — grows together.
        _zoomContent.Width = w / _zoom;
        _zoomContent.Height = h / _zoom;
        _zoomContent.RenderTransform = new ScaleTransform { ScaleX = _zoom, ScaleY = _zoom };
    }

    // MARK: - Keyboard

    private void InstallKeyboard()
    {
        RootElement.KeyboardAcceleratorPlacementMode = KeyboardAcceleratorPlacementMode.Hidden;
        void Add(VirtualKey key, VirtualKeyModifiers mods, Action action)
        {
            var accel = new KeyboardAccelerator { Key = key, Modifiers = mods };
            accel.Invoked += (_, a) => { a.Handled = true; action(); };
            RootElement.KeyboardAccelerators.Add(accel);
        }
        foreach (var item in SidebarItems.All)
        {
            var (key, mods) = item.Shortcut();
            Add(key, mods, () => Select(item));
        }
        // Zoom, with or without Shift (the Mac app's ⌘ and ⇧⌘ +/−): the Plus key
        // (VK_OEM_PLUS, = on US layouts), the Minus key and the number pad's.
        var ctrlShift = VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift;
        Add((VirtualKey)187, VirtualKeyModifiers.Control, ZoomIn);   // Ctrl+= / Ctrl++
        Add((VirtualKey)187, ctrlShift, ZoomIn);
        Add(VirtualKey.Add, VirtualKeyModifiers.Control, ZoomIn);
        Add(VirtualKey.Add, ctrlShift, ZoomIn);
        Add((VirtualKey)189, VirtualKeyModifiers.Control, ZoomOut);  // Ctrl+-
        Add((VirtualKey)189, ctrlShift, ZoomOut);
        Add(VirtualKey.Subtract, VirtualKeyModifiers.Control, ZoomOut);
        Add(VirtualKey.Subtract, ctrlShift, ZoomOut);
        Add(VirtualKey.Number0, VirtualKeyModifiers.Control, ResetZoom);
        Add(VirtualKey.NumberPad0, VirtualKeyModifiers.Control, ResetZoom);
        Add(VirtualKey.Left, VirtualKeyModifiers.Menu, () => GoBack());
        Add(VirtualKey.GoBack, VirtualKeyModifiers.None, () => GoBack());
        Add(VirtualKey.F11, VirtualKeyModifiers.None, ToggleFullScreen);

        // Keys offered to the screen on top first (reader page turns), unless
        // a text box has focus.
        RootElement.PreviewKeyDown += (_, e) =>
        {
            if (FocusManager.GetFocusedElement(RootElement.XamlRoot) is TextBox or PasswordBox or AutoSuggestBox or RichEditBox) return;
            var mods = CurrentModifiers();
            if (Navigator.Current?.HandleKey(e.Key, mods) == true) { e.Handled = true; return; }
            if (e.Key == VirtualKey.V && mods == VirtualKeyModifiers.Control) { e.Handled = AppHost.PasteImport(); return; }
            if (e.Key is VirtualKey.Escape or VirtualKey.GamepadB && mods == VirtualKeyModifiers.None && Navigator.CanGoBack)
            {
                e.Handled = GoBack();
            }
        };
    }

    public static VirtualKeyModifiers CurrentModifiers()
    {
        var mods = VirtualKeyModifiers.None;
        bool Down(VirtualKey k) => InputKeyboardSource.GetKeyStateForCurrentThread(k).HasFlag(CoreVirtualKeyStates.Down);
        if (Down(VirtualKey.Control)) mods |= VirtualKeyModifiers.Control;
        if (Down(VirtualKey.Shift)) mods |= VirtualKeyModifiers.Shift;
        if (Down(VirtualKey.Menu)) mods |= VirtualKeyModifiers.Menu;
        if (Down(VirtualKey.LeftWindows) || Down(VirtualKey.RightWindows)) mods |= VirtualKeyModifiers.Windows;
        return mods;
    }

    // MARK: - Window placement

    private void RestoreBounds()
    {
        var raw = KeyValueStores.Default.GetString(BoundsKey);
        var parts = raw?.Split(',').Select(p => int.TryParse(p, out var v) ? v : int.MinValue).ToArray();
        if (parts is { Length: 4 } && parts.All(p => p != int.MinValue) && parts[2] >= 360 && parts[3] >= 480)
        {
            var rect = new RectInt32(parts[0], parts[1], parts[2], parts[3]);
            if (DisplayArea.GetFromRect(rect, DisplayAreaFallback.None) is not null)
            {
                AppWindow.MoveAndResize(rect);
                return;
            }
        }
        // First launch: a comfortable reading window centred on the screen.
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var width = Math.Min(1280, (int)(area.Width * 0.85));
        var height = Math.Min(860, (int)(area.Height * 0.85));
        AppWindow.MoveAndResize(new RectInt32(area.X + (area.Width - width) / 2, area.Y + (area.Height - height) / 2, width, height));
    }

    private void SaveBounds()
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Restored })
        {
            var p = AppWindow.Position;
            var s = AppWindow.Size;
            KeyValueStores.Default.SetString(BoundsKey, $"{p.X},{p.Y},{s.Width},{s.Height}");
        }
    }
}

/// <summary>Stand-in for a tab whose screen hasn't been built.</summary>
public sealed class PlaceholderScreen(string title) : Screen
{
    protected override FrameworkElement Build()
    {
        Title = title;
        return UI.UI.EmptyState("hammer", title, "Coming soon.");
    }
}
