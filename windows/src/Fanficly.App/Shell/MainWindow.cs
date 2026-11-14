using Fanficly.App.UI;
using Fanficly.App.Views.Reader;
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
    private const string MaximizedKey = "app.windowMaximized";

    // Kept alive for its change event (a collected instance stops raising it).
    private readonly Windows.UI.ViewManagement.UISettings _uiSettings = new();
    /// <summary>The window's last normal (not maximized, minimized or full screen)
    /// bounds, which are what a maximized window reopens to when un-maximized.</summary>
    private RectInt32? _restoredBounds;
    /// <summary>Whether the window was last maximized (minimized and full screen
    /// leave it as it was); saved on close.</summary>
    private bool _isMaximized;
    private bool _maximizeWhenShown;
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
            var shortcut = item.ShortcutText();
            ToolTipService.SetToolTip(navItem, shortcut is null ? item.Title() : $"{item.Title()} ({shortcut})");
            AutomationProperties.SetAutomationId(navItem, $"sidebar.{item.RawValue()}");
            if (shortcut is not null) AutomationProperties.SetAcceleratorKey(navItem, shortcut);
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
        // Turning high contrast on or off (or switching between contrast themes)
        // while the app runs doesn't always change ActualTheme, so re-apply the
        // palette when the system colours change too; it arrives off the UI
        // thread (#206). Not AccessibilitySettings.HighContrastChanged: it needs
        // a CoreWindow, which a WinUI 3 desktop window doesn't have, and
        // subscribing to it crashed the app at launch.
        try
        {
            _uiSettings.ColorValuesChanged += (_, _) => DispatcherQueue.TryEnqueue(() => Theme.Apply(RootElement.ActualTheme));
        }
        catch (Exception ex)
        {
            AppHost.Log($"Couldn't watch the system colours: {ex.Message}");
        }
        RootElement.Loaded += (_, _) => Theme.Apply(RootElement.ActualTheme);
        Theme.Apply(Application.Current.RequestedTheme == ApplicationTheme.Dark ? ElementTheme.Dark : ElementTheme.Light);

        Navigator.Changed += OnNavigatorChanged;
        InstallKeyboard();
        Platform.VolumeKeyGate.Install(WinRT.Interop.WindowNative.GetWindowHandle(this));
        RootElement.PointerPressed += (_, e) =>
        {
            // Mouse "back" button.
            var props = e.GetCurrentPoint(RootElement).Properties;
            if (props.IsXButton1Pressed && !Views.Account.ContentSafetyViews.AgeGateActive) { e.Handled = GoBack(); }
        };

        _zoom = UiZoom.Clamped(KeyValueStores.Default.GetDouble(ZoomKey, UiZoom.ActualSize));
        RestoreBounds();
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = 360;
            presenter.PreferredMinimumHeight = 480;
        }
        AppWindow.Changed += (_, e) =>
        {
            if (AppWindow.Presenter is not OverlappedPresenter overlapped) return;   // full screen keeps both
            // Minimized keeps whether it was maximized, so closing from the
            // taskbar reopens the window the way it was before.
            if (overlapped.State == OverlappedPresenterState.Maximized) _isMaximized = true;
            else if (overlapped.State == OverlappedPresenterState.Restored)
            {
                _isMaximized = false;
                if (e.DidPositionChange || e.DidSizeChange)
                    _restoredBounds = new RectInt32(AppWindow.Position.X, AppWindow.Position.Y, AppWindow.Size.Width, AppWindow.Size.Height);
            }
        };
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
        // Nothing goes back behind the 17+ gate, whatever asked (the title
        // bar's back button included) (#203).
        if (Views.Account.ContentSafetyViews.AgeGateActive) return false;
        if (Navigator.Current?.HandleBack() == true) return true;
        return Navigator.GoBack();
    }

    private void OnNavigatorChanged(NavigationChange change)
    {
        var forward = change == NavigationChange.Push;
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
        // A tab change leaves focus where it was (the sidebar, or a shortcut).
        if (screen is not null && change != NavigationChange.Root) FocusAfterNavigation(screen, returning: !forward);
        else _focusToken++;
    }

    private int _focusToken;

    /// <summary>A screen that was still loading (a spinner, AO3 not answered yet)
    /// had nothing to focus: try again as its layout changes, for up to 20 s.</summary>
    private void RetryWhileLoading(Screen screen, int token)
    {
        var view = screen.View;
        var stranded = XamlRoot is { } root ? FocusManager.GetFocusedElement(root) : null;
        var deadline = DateTime.UtcNow.AddSeconds(20);
        var queued = false;
        void Stop() => view.LayoutUpdated -= OnLayout;
        void OnLayout(object? sender, object e)
        {
            if (queued) return;
            if (token != _focusToken || Navigator.Current != screen || DateTime.UtcNow > deadline) { Stop(); return; }
            queued = true;
            DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
            {
                queued = false;
                if (token != _focusToken || Navigator.Current != screen) { Stop(); return; }
                if (FocusIsInPopup() || screen.RetryFocusInitial(stranded)) Stop();
            });
        }
        view.LayoutUpdated += OnLayout;
    }

    /// <summary>Whether a dialog, menu or other popup holds keyboard focus.</summary>
    private bool FocusIsInPopup()
    {
        if (RootElement.XamlRoot is not { } root || FocusManager.GetFocusedElement(root) is not DependencyObject focused) return false;
        foreach (var popup in VisualTreeHelper.GetOpenPopupsForXamlRoot(root))
        {
            if (!popup.IsOpen || popup.Child is null or ToolTip) continue;
            for (DependencyObject? node = focused; node is not null; node = VisualTreeHelper.GetParent(node))
                if (ReferenceEquals(node, popup.Child)) return true;
        }
        return false;
    }

    /// <summary>
    /// After a push or Back, moves keyboard focus into the screen now on top and
    /// tells Narrator which page it is (#178), as UIKit's navigation stack does for
    /// VoiceOver: a push focuses the new screen, Back returns focus to the element
    /// the user left. Waits for the screen's view to load and lay out, so its rows
    /// exist, and gives up if another navigation came first.
    /// </summary>
    private void FocusAfterNavigation(Screen screen, bool returning)
    {
        var view = screen.View;
        var token = ++_focusToken;
        void Run()
        {
            if (token != _focusToken || Navigator.Current != screen) return;
            // Leave a dialog or menu that opened meanwhile in charge of focus
            // (and don't talk over it).
            if (FocusIsInPopup()) return;
            if (screen.Title.Length > 0) Announce(screen.Title, interrupt: false);
            if (!screen.MoveFocusIn(returning)) RetryWhileLoading(screen, token);
        }
        void Later() => DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, Run);
        if (view.IsLoaded && view.Parent == _body) { Later(); return; }
        void OnLoaded(object sender, RoutedEventArgs e)
        {
            view.Loaded -= OnLoaded;
            Later();
        }
        view.Loaded += OnLoaded;
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

    /// <summary>A message at the bottom of the window, announced to Narrator.
    /// A confirmation closes by itself after <paramref name="seconds"/> (4 by
    /// default); an error or warning stays until closed (<see cref="MessageLifetime"/>, #205).</summary>
    public void ShowMessage(string title, string? message = null, InfoBarSeverity severity = InfoBarSeverity.Success, int? seconds = null)
    {
        // The same words again keep the bar already up (and any focus on it)
        // rather than stacking a copy.
        var bars = _messages.Children.OfType<InfoBar>().ToList();
        if (bars.Any(b => b.Title == title && b.Message == (message ?? "") && b.Severity == severity))
        {
            Announce(message is null ? title : $"{title}. {message}");
            return;
        }
        // Errors stay until closed, so keep the stack from covering the window:
        // past MaxMessages the oldest goes.
        for (var i = 0; i <= bars.Count - MessageLifetime.MaxMessages; i++) _messages.Children.Remove(bars[i]);
        var bar = UI.UI.Banner(title, message, severity);
        bar.Background = Theme.CardBackground;
        bar.Shadow = new ThemeShadow();
        _messages.Children.Add(bar);
        Announce(message is null ? title : $"{title}. {message}");
        bar.Closed += (_, _) => _messages.Children.Remove(bar);
        if (MessageLifetime.Seconds(severity == InfoBarSeverity.Error || severity == InfoBarSeverity.Warning, seconds) is not { } lifetime) return;

        // A confirmation closes by itself, but never while the pointer is over
        // it or keyboard focus is inside it (WCAG 2.2.1): the countdown starts
        // again when they leave.
        var timer = DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromSeconds(lifetime);
        timer.IsRepeating = false;
        timer.Tick += (_, _) => _messages.Children.Remove(bar);
        var pointerOver = false;
        var focusInside = false;
        void Hold()
        {
            if (pointerOver || focusInside) timer.Stop();
            else timer.Start();
        }
        bar.PointerEntered += (_, _) => { pointerOver = true; Hold(); };
        bar.PointerExited += (_, _) => { pointerOver = false; Hold(); };
        bar.PointerCanceled += (_, _) => { pointerOver = false; Hold(); };
        bar.GotFocus += (_, _) => { focusInside = true; Hold(); };
        bar.LostFocus += (_, _) => { focusInside = false; Hold(); };
        bar.Closed += (_, _) => timer.Stop();
        timer.Start();
    }

    /// <summary>Narrator announcement (UIAccessibility.post(.announcement)).</summary>
    /// <remarks>With <paramref name="interrupt"/> false the announcement queues
    /// behind what Narrator is saying (a page name after the focus moved).</remarks>
    public void Announce(string text, bool interrupt = true)
    {
        var peer = Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.FromElement(_headerTitle)
                   ?? Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.CreatePeerForElement(_headerTitle);
        peer?.RaiseNotificationEvent(
            Microsoft.UI.Xaml.Automation.Peers.AutomationNotificationKind.Other,
            interrupt
                ? Microsoft.UI.Xaml.Automation.Peers.AutomationNotificationProcessing.ImportantMostRecent
                : Microsoft.UI.Xaml.Automation.Peers.AutomationNotificationProcessing.ImportantAll,
            text, interrupt ? "fanficly.announcement" : "fanficly.page");
    }

    // MARK: - Zoom (the Mac app's ⇧⌘ +/− and ⌘0)

    public double Zoom => _zoom;

    public void ZoomIn() => SetZoom(UiZoom.Stepped(_zoom, forward: true));
    public void ZoomOut() => SetZoom(UiZoom.Stepped(_zoom, forward: false));
    public void ResetZoom() => SetZoom(UiZoom.ActualSize);

    // MARK: - Reader text size (the Mac's Reader → Bigger / Smaller Text, ⌘+ / ⌘−)

    public void BiggerText() => SetTextSize(ReaderMetrics.SteppedFontSize(ReaderPrefs.FontSizePt, bigger: true));
    public void SmallerText() => SetTextSize(ReaderMetrics.SteppedFontSize(ReaderPrefs.FontSizePt, bigger: false));

    /// <summary>The same per-device text size as the Aa menu and Settings → Theme
    /// &amp; typography; an open reader re-lays out from the key change.</summary>
    private void SetTextSize(double value)
    {
        ReaderPrefs.FontSizePt = value;
        LibrarySyncManager.QueueBackupShared(AppHost.Library);
        Announce($"Text size {value:0} points");
    }

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
        // While the 17+ gate is up only the shortcuts that change how the window
        // looks (zoom, full screen) work; the rest would open tabs, go back or
        // change reader settings behind it (#203).
        void Add(VirtualKey key, VirtualKeyModifiers mods, Action action, bool duringAgeGate = false)
        {
            var accel = new KeyboardAccelerator { Key = key, Modifiers = mods };
            accel.Invoked += (_, a) =>
            {
                a.Handled = true;
                if (duringAgeGate || !Views.Account.ContentSafetyViews.AgeGateActive) action();
            };
            RootElement.KeyboardAccelerators.Add(accel);
        }
        foreach (var item in SidebarItems.All)
        {
            if (item.Shortcut() is not { } shortcut) continue;
            Add(shortcut.Key, shortcut.Modifiers, () => Select(item));
        }
        // As on the Mac: Ctrl with the Plus key (VK_OEM_PLUS, = on US layouts),
        // the Minus key or the number pad's changes the reader's text size
        // (⌘+ / ⌘−); with Shift too it zooms the interface (⇧⌘+ / ⇧⌘−).
        var ctrlShift = VirtualKeyModifiers.Control | VirtualKeyModifiers.Shift;
        Add((VirtualKey)187, VirtualKeyModifiers.Control, BiggerText);   // Ctrl+= / Ctrl++
        Add(VirtualKey.Add, VirtualKeyModifiers.Control, BiggerText);
        Add((VirtualKey)189, VirtualKeyModifiers.Control, SmallerText);  // Ctrl+-
        Add(VirtualKey.Subtract, VirtualKeyModifiers.Control, SmallerText);
        Add((VirtualKey)187, ctrlShift, ZoomIn, duringAgeGate: true);
        Add(VirtualKey.Add, ctrlShift, ZoomIn, duringAgeGate: true);
        Add((VirtualKey)189, ctrlShift, ZoomOut, duringAgeGate: true);
        Add(VirtualKey.Subtract, ctrlShift, ZoomOut, duringAgeGate: true);
        Add(VirtualKey.Number0, VirtualKeyModifiers.Control, ResetZoom, duringAgeGate: true);
        Add(VirtualKey.NumberPad0, VirtualKeyModifiers.Control, ResetZoom, duringAgeGate: true);
        Add(VirtualKey.Left, VirtualKeyModifiers.Menu, () => GoBack());
        Add(VirtualKey.GoBack, VirtualKeyModifiers.None, () => GoBack());
        Add(VirtualKey.F11, VirtualKeyModifiers.None, ToggleFullScreen, duringAgeGate: true);

        // Keys offered to the screen on top first (reader page turns), unless
        // a text box has focus.
        RootElement.PreviewKeyDown += (_, e) =>
        {
            // Behind the 17+ gate keys only reach the gate itself (#203).
            if (Views.Account.ContentSafetyViews.AgeGateActive) return;
            if (FocusManager.GetFocusedElement(RootElement.XamlRoot) is TextBox or PasswordBox or AutoSuggestBox or RichEditBox) return;
            var mods = CurrentModifiers();
            if (Navigator.Current?.HandleKey(e.Key, mods) == true) { e.Handled = true; return; }
            if (e.Key == VirtualKey.V && mods == VirtualKeyModifiers.Control) { e.Handled = AppHost.PasteImport(); return; }
            // Esc goes back, and on a tab's root still lets the screen leave a
            // mode first (Recently Viewed's edit mode); GoBack returns false when
            // there's nothing to leave, so Esc then reaches whatever else wants it (#206).
            if (e.Key is VirtualKey.Escape or VirtualKey.GamepadB && mods == VirtualKeyModifiers.None)
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
                _restoredBounds = rect;
                // Reopen maximized when it closed maximized, on the display the
                // normal bounds are on, and un-maximize to those bounds (#206).
                _maximizeWhenShown = _isMaximized = KeyValueStores.Default.GetBool(MaximizedKey);
                return;
            }
        }
        // First launch: a comfortable reading window centred on the screen.
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var width = Math.Min(1280, (int)(area.Width * 0.85));
        var height = Math.Min(860, (int)(area.Height * 0.85));
        var initial = new RectInt32(area.X + (area.Width - width) / 2, area.Y + (area.Height - height) / 2, width, height);
        AppWindow.MoveAndResize(initial);
        _restoredBounds = initial;
    }

    /// <summary>Maximizes the window when it closed maximized last time. Called
    /// by App.OnLaunched right after <c>Activate()</c>: Maximize() on a hidden
    /// window would show it before then (#206).</summary>
    public void MaximizeIfItWasMaximized()
    {
        if (!_maximizeWhenShown) return;
        _maximizeWhenShown = false;
        if (AppWindow.Presenter is OverlappedPresenter overlapped) overlapped.Maximize();
    }

    /// <summary>Saves the normal bounds, and whether the window was last
    /// maximized (closing minimized or full screen keeps the state before).</summary>
    private void SaveBounds()
    {
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Restored })
        {
            var p = AppWindow.Position;
            var s = AppWindow.Size;
            _restoredBounds = new RectInt32(p.X, p.Y, s.Width, s.Height);
            _isMaximized = false;
        }
        else if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Maximized })
        {
            _isMaximized = true;
        }
        KeyValueStores.Default.SetBool(MaximizedKey, _isMaximized);
        if (_restoredBounds is { } r)
            KeyValueStores.Default.SetString(BoundsKey, $"{r.X},{r.Y},{r.Width},{r.Height}");
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
