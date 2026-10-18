using Fanficly.App.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.UI;

/// <summary>Alerts, confirmations, text prompts and sheets (SwiftUI's .alert /
/// .confirmationDialog / .sheet) as Fluent ContentDialogs. Only one dialog can
/// be open at a time; a second request waits for the first to close.</summary>
public static class Dialogs
{
    private static readonly SemaphoreSlim OneAtATime = new(1, 1);

    public static async Task<ContentDialogResult> ShowAsync(ContentDialog dialog)
    {
        await OneAtATime.WaitAsync();
        try
        {
            dialog.XamlRoot = MainWindow.Current.XamlRoot;
            dialog.RequestedTheme = MainWindow.Current.RootElement.ActualTheme;
            dialog.Style ??= Application.Current.Resources["DefaultContentDialogStyle"] as Style;
            return await dialog.ShowAsync();
        }
        finally
        {
            OneAtATime.Release();
        }
    }

    public static Task<ContentDialogResult> AlertAsync(string title, string? message = null, string ok = "OK") =>
        ShowAsync(new ContentDialog
        {
            Title = title,
            Content = message is null ? null : UI.Text(message),
            CloseButtonText = ok,
            DefaultButton = ContentDialogButton.Close,
        });

    /// <summary>Returns true when the user confirmed.</summary>
    public static async Task<bool> ConfirmAsync(string title, string? message, string confirm, bool destructive = false, string cancel = "Cancel")
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = message is null ? null : UI.Text(message),
            PrimaryButtonText = confirm,
            CloseButtonText = cancel,
            DefaultButton = destructive ? ContentDialogButton.Close : ContentDialogButton.Primary,
        };
        if (destructive)
        {
            var style = new Style(typeof(Button));
            style.Setters.Add(new Setter(Control.ForegroundProperty, Theme.Danger));
            dialog.PrimaryButtonStyle = style;
        }
        return await ShowAsync(dialog) == ContentDialogResult.Primary;
    }

    /// <summary>A one-line text prompt; null when cancelled or left empty.</summary>
    public static async Task<string?> PromptAsync(string title, string placeholder, string confirm = "Save", string initial = "", string? message = null)
    {
        var box = new TextBox { PlaceholderText = placeholder, Text = initial, MinWidth = 300 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(box, placeholder);
        var content = UI.VStack(10, message is null ? null : UI.Secondary(message, Theme.Style.Body), box);
        var dialog = new ContentDialog
        {
            Title = title,
            Content = content,
            PrimaryButtonText = confirm,
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        box.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = box.Text.Trim().Length > 0;
        dialog.IsPrimaryButtonEnabled = initial.Trim().Length > 0;
        dialog.Opened += (_, _) => { box.Focus(FocusState.Programmatic); box.SelectAll(); };
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter && box.Text.Trim().Length > 0) { e.Handled = true; dialog.Hide(); confirmed = true; }
        };
        confirmed = false;
        var result = await ShowAsync(dialog);
        var text = box.Text.Trim();
        return (result == ContentDialogResult.Primary || confirmed) && text.Length > 0 ? text : null;
    }

    private static bool confirmed;

    /// <summary>A wide dialog for sheet-like content (filters, move-to-folder):
    /// the content scrolls; primary/close buttons are optional.</summary>
    public static Task<ContentDialogResult> SheetAsync(string title, UIElement content, string? primary = null, string close = "Done",
                                                      double width = 640, string? secondary = null)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = new ScrollViewer
            {
                Content = content,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollMode = ScrollMode.Disabled,
                Padding = new Thickness(0, 0, 12, 0),
            },
            PrimaryButtonText = primary ?? "",
            SecondaryButtonText = secondary ?? "",
            CloseButtonText = close,
            DefaultButton = primary is null ? ContentDialogButton.Close : ContentDialogButton.Primary,
            FullSizeDesired = false,
        };
        dialog.Resources["ContentDialogMaxWidth"] = width;
        dialog.Resources["ContentDialogMinWidth"] = Math.Min(width, 320);
        dialog.Resources["ContentDialogMaxHeight"] = 900.0;
        return ShowAsync(dialog);
    }
}
