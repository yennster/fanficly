using Fanficly.Core;
using Windows.UI.StartScreen;

namespace Fanficly.App.Platform;

/// <summary>
/// The taskbar / Start jump list: "Continue reading" the last story (the
/// widget's resume route) plus shortcuts to the main tabs.
/// </summary>
public static class JumpListService
{
    public static async Task RefreshAsync()
    {
        if (AppHost.IsDemoMode || !JumpList.IsSupported()) return;
        try
        {
            var list = await JumpList.LoadCurrentAsync();
            list.SystemGroupKind = JumpListSystemGroupKind.None;
            list.Items.Clear();

            if (WidgetProgressStore.Load() is { } last)
            {
                var uri = DeepLink.ResumeUri(last.Id, last.Chapter, last.Paragraph);
                var resume = JumpListItem.CreateWithArguments(uri.ToString(), $"Continue “{Trim(last.Title)}”");
                resume.Description = last.Author.Length > 0 ? $"by {last.Author} · {Math.Round(last.ClampedProgress * 100)}% read" : "";
                resume.GroupName = "Reading";
                resume.Logo = new Uri("ms-appx:///Assets/Square44x44Logo.targetsize-32.png");
                list.Items.Add(resume);
            }

            foreach (var item in new[] { SidebarItem.Search, SidebarItem.Library, SidebarItem.Popular, SidebarItem.Subscriptions })
            {
                var entry = JumpListItem.CreateWithArguments($"-tab {item.RawValue()}", item.Title());
                entry.GroupName = "Go to";
                list.Items.Add(entry);
            }
            await list.SaveAsync();
        }
        catch (Exception e)
        {
            AppHost.Log($"Jump list update failed: {e.Message}");
        }
    }

    private static string Trim(string title) => title.Length <= 40 ? title : title[..39] + "…";
}
