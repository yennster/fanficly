using System.Globalization;
using Fanficly.App.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;
using Windows.Foundation;
using Windows.Storage;
using Windows.Storage.Streams;

namespace Fanficly.App.Views.Library;

/// <summary>
/// A panel Narrator reads as one element with its own name and no children —
/// SwiftUI's <c>.accessibilityElement(children: .ignore)</c> +
/// <c>.accessibilityLabel(...)</c> (stat tiles, bar rows, the progress banner).
/// </summary>
public sealed partial class AccessibleGroup : Grid
{
    public AutomationControlType ControlType { get; set; } = AutomationControlType.Text;

    public AccessibleGroup(string name, UIElement? child = null)
    {
        AutomationProperties.SetName(this, name);
        if (child is not null) Children.Add(child);
    }

    public string AccessibleName
    {
        get => AutomationProperties.GetName(this);
        set => AutomationProperties.SetName(this, value);
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new GroupPeer(this);

    private sealed partial class GroupPeer(AccessibleGroup owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => owner.ControlType;
        protected override string GetClassNameCore() => nameof(AccessibleGroup);
        protected override bool IsContentElementCore() => true;
        protected override bool IsControlElementCore() => true;
        protected override IList<AutomationPeer>? GetChildrenCore() => null;
    }
}

/// <summary>Foundation's <c>.relative(presentation: .named)</c>: "now", "5 minutes
/// ago", "yesterday", "last week", "3 months ago".</summary>
public static class RelativeDate
{
    public static string Named(DateTimeOffset date, DateTimeOffset? now = null)
    {
        var reference = now ?? DateTimeOffset.Now;
        var past = date <= reference;
        var span = past ? reference - date : date - reference;
        string Phrase(int n, string unit, string lastWord, string nextWord)
        {
            if (n == 1) return past ? $"{lastWord} {unit}" : $"{nextWord} {unit}";
            return past ? $"{n} {unit}s ago" : $"in {n} {unit}s";
        }
        if (span.TotalSeconds < 60) return "now";
        if (span.TotalMinutes < 60)
        {
            var m = (int)span.TotalMinutes;
            return past ? (m == 1 ? "1 minute ago" : $"{m} minutes ago") : (m == 1 ? "in 1 minute" : $"in {m} minutes");
        }
        // Calendar days from here on, like Foundation's named presentation.
        var days = (int)Math.Abs((reference.LocalDateTime.Date - date.LocalDateTime.Date).TotalDays);
        if (days == 0)
        {
            var h = (int)span.TotalHours;
            return past ? (h == 1 ? "1 hour ago" : $"{h} hours ago") : (h == 1 ? "in 1 hour" : $"in {h} hours");
        }
        if (days == 1) return past ? "yesterday" : "tomorrow";
        if (days < 7) return past ? $"{days} days ago" : $"in {days} days";
        if (days < 30) return Phrase(days / 7, "week", "last", "next");
        if (days < 365) return Phrase(Math.Max(1, days / 30), "month", "last", "next");
        return Phrase(Math.Max(1, days / 365), "year", "last", "next");
    }
}

/// <summary>
/// Windows' share sheet (the Swift <c>ShareLink</c> / <c>ShareSheet</c>):
/// DataTransferManager for this window, filled when Windows asks.
///
/// Every share in the app goes through <see cref="Share"/>. Each call hooks one
/// handler that unhooks itself after the request it was made for, and drops any
/// handler a previous share left behind, so a share never carries the link,
/// text or file of an earlier one (#166).
/// </summary>
public static class ShareService
{
    private static nint WindowHandle => WinRT.Interop.WindowNative.GetWindowHandle(MainWindow.Current);

    /// <summary>The handler of the share in flight, until Windows asks for its data.</summary>
    private static (DataTransferManager Manager, TypedEventHandler<DataTransferManager, DataRequestedEventArgs> Handler)? _pending;

    /// <summary>Opens the share UI; <paramref name="fill"/> fills the request.
    /// When the share UI can't open, <paramref name="onFailure"/> runs instead
    /// (the default says so in the window).</summary>
    public static void Share(Action<DataRequest> fill, Action<Exception>? onFailure = null)
    {
        try
        {
            var hwnd = WindowHandle;
            var manager = DataTransferManagerInterop.GetForWindow(hwnd);
            Unhook();
            TypedEventHandler<DataTransferManager, DataRequestedEventArgs>? handler = null;
            handler = (sender, args) =>
            {
                sender.DataRequested -= handler;
                if (_pending is { } p && p.Handler == handler) _pending = null;
                fill(args.Request);
            };
            manager.DataRequested += handler;
            _pending = (manager, handler);
            DataTransferManagerInterop.ShowShareUIForWindow(hwnd);
        }
        catch (Exception e)
        {
            Unhook();
            AppHost.Log($"Share failed: {e.Message}");
            if (onFailure is not null) onFailure(e);
            else MainWindow.Current?.ShowMessage("Couldn't open Share", e.Message, InfoBarSeverity.Error);
        }
    }

    private static void Unhook()
    {
        if (_pending is not { } p) return;
        _pending = null;
        try { p.Manager.DataRequested -= p.Handler; }
        catch (Exception e) { AppHost.Log($"Share unhook failed: {e.Message}"); }
    }

    /// <summary>"Share Story…": the work's AO3 link with its title. Copies the
    /// link instead when the share UI isn't available.</summary>
    public static void ShareWork(int workId, string title)
    {
        var url = new Uri($"https://archiveofourown.org/works/{workId}");
        Share(request =>
        {
            request.Data.Properties.Title = title;
            request.Data.Properties.Description = $"Check out this story: {title}";
            request.Data.SetWebLink(url);
            request.Data.SetText($"Check out this story: {title}\n{url}");
        }, _ =>
        {
            var package = new DataPackage();
            package.SetText(url.ToString());
            Clipboard.SetContent(package);
            MainWindow.Current?.ShowMessage("Link copied", title, InfoBarSeverity.Success);
        });
    }

    /// <summary>Shares a file (an exported work).</summary>
    public static void ShareFile(StorageFile file, string title) =>
        Share(request =>
        {
            request.Data.Properties.Title = title.Length == 0 ? file.Name : title;
            request.Data.Properties.Description = file.Name;
            request.Data.SetStorageItems(new IStorageItem[] { file });
        });

    /// <summary>Shares a PNG (written to a temp file first, so apps that take
    /// files and apps that take bitmaps both get it).</summary>
    public static async Task ShareImageAsync(byte[] png, string fileName, string title)
    {
        try
        {
            var path = Path.Combine(Path.GetTempPath(), "Fanficly", SafeFileName(fileName) + ".png");
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            await File.WriteAllBytesAsync(path, png);
            var file = await StorageFile.GetFileFromPathAsync(path);
            Share(request =>
            {
                request.Data.Properties.Title = title;
                request.Data.SetStorageItems(new IStorageItem[] { file });
                request.Data.SetBitmap(RandomAccessStreamReference.CreateFromFile(file));
            });
        }
        catch (Exception e)
        {
            AppHost.Log($"Share image failed: {e.Message}");
            MainWindow.Current?.ShowMessage("Couldn't share the image", e.Message, InfoBarSeverity.Error);
        }
    }

    public static string SafeFileName(string name)
    {
        var invalid = Path.GetInvalidFileNameChars();
        var cleaned = new string(name.Select(c => invalid.Contains(c) ? '-' : c).ToArray()).Trim();
        return cleaned.Length == 0 ? "Fanficly" : cleaned;
    }
}

internal static class Plural
{
    public static string Stories(int n) => n == 1 ? "1 story" : $"{n.ToString("N0", CultureInfo.CurrentCulture)} stories";
}
