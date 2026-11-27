using Fanficly.App.Shell;
using Fanficly.App.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace Fanficly.App.Views.Library;

/// <summary>A folder import's progress card (#418; Swift: <c>EPUBFolderImportBanner</c>):
/// spinner, "Importing 37 of 212…" over a bar, Cancel. Installed once in the
/// window's message area, so it shows wherever the user is; hidden while no
/// folder import runs.</summary>
public static class EpubImportBanner
{
    /// <summary>Adds the card to <paramref name="host"/> and returns it.</summary>
    public static FrameworkElement Attach(Panel host)
    {
        var banner = Create();
        host.Children.Add(banner);
        return banner;
    }

    private static FrameworkElement Create()
    {
        var container = new Border
        {
            Padding = new Thickness(14),
            CornerRadius = new CornerRadius(8),
            Background = Theme.CardBackground,
            BorderBrush = Theme.CardStroke,
            BorderThickness = new Thickness(1),
            MaxWidth = 420,
            HorizontalAlignment = HorizontalAlignment.Center,
            Margin = new Thickness(16, 8, 16, 4),
            Visibility = Visibility.Collapsed,
            Shadow = new Microsoft.UI.Xaml.Media.ThemeShadow(),
        };
        AutomationProperties.SetAutomationId(container, "import.banner");
        AutomationProperties.SetLandmarkType(container, AutomationLandmarkType.Custom);
        AutomationProperties.SetLocalizedLandmarkType(container, "Import");

        var spinner = new ProgressRing { IsActive = true, Width = 20, Height = 20 }.A11yHidden();
        var title = UI.UI.Text("", Theme.Style.Footnote, maxLines: UI.UI.LineLimit(1));
        title.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        var bar = new ProgressBar { Minimum = 0, Maximum = 1, MinHeight = 4 };
        var group = new AccessibleGroup("", UI.UI.VStack(4, title, bar));
        var cancel = UI.UI.Button("Cancel", EpubImporter.CancelFolderImport);
        cancel.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        AutomationProperties.SetAutomationId(cancel, "import.cancel");
        AutomationProperties.SetHelpText(cancel, "Stops the import. Stories already imported stay in your Library.");

        var grid = UI.UI.Grid("Auto,*,Auto", columnSpacing: 12);
        grid.Children.Add(spinner.Also(s => s.VerticalAlignment = VerticalAlignment.Center).Col(0));
        grid.Children.Add(group.Col(1));
        grid.Children.Add(cancel.Also(c => c.VerticalAlignment = VerticalAlignment.Center).Col(2));
        container.Child = grid;

        void Update()
        {
            if (EpubImporter.FolderProgress is not { } p)
            {
                container.Visibility = Visibility.Collapsed;
                spinner.IsActive = false;
                return;
            }
            container.Visibility = Visibility.Visible;
            spinner.IsActive = true;
            title.Text = p.Total == 0 ? "Looking for EPUB files…" : $"Importing {p.Done} of {p.Total}…";
            bar.Maximum = Math.Max(p.Total, 1);
            bar.Value = p.Done;
            bar.IsIndeterminate = p.Total == 0;
            group.AccessibleName = p.Total == 0 ? "Looking for EPUB files" : $"Importing EPUBs, {p.Done} of {p.Total} done";
        }

        container.Loaded += (_, _) =>
        {
            EpubImporter.FolderProgressChanged -= Update;
            EpubImporter.FolderProgressChanged += Update;
            Update();
        };
        container.Unloaded += (_, _) => EpubImporter.FolderProgressChanged -= Update;
        Update();
        return container;
    }
}
