using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>Tapping a poller notification must open what it's about: the work
/// with new chapters, an author's single new work, or the author's page when
/// several arrived at once. The route rides in the toast's arguments, which
/// Windows stores as a launch string and hands back on tap.</summary>
public class NotificationRouteTests
{
    private static readonly AuthorRef Author = new("some_login", "Some Pseud");

    /// <summary>Encode → launch string (as the toast stores it) → decode.</summary>
    private static NotificationRoute? Delivered(IReadOnlyDictionary<string, string> arguments)
    {
        var launch = string.Join(";", arguments.Select(kv => $"{Escape(kv.Key)}={Escape(kv.Value)}"));
        return NotificationRoute.FromArguments(NotificationRoute.ParseLaunchArguments(launch));
    }

    private static string Escape(string s) => s.Replace("%", "%25").Replace(";", "%3B").Replace("=", "%3D");

    private static NotificationRoute? Route(params (string Key, string Value)[] arguments) =>
        NotificationRoute.FromArguments(arguments.ToDictionary(a => a.Key, a => a.Value));

    [Fact]
    public void EveryRouteSurvivesDelivery()
    {
        NotificationRoute[] routes =
        [
            new NotificationRoute.NewChapters(12345),
            new NotificationRoute.NewWork(67890),
            new NotificationRoute.NewWorks(Author),
            // Pseuds can hold anything, including the launch string's separators.
            new NotificationRoute.NewWorks(new AuthorRef("odd_login", "A;B=C %41 ünïcode")),
        ];
        foreach (var route in routes)
        {
            Assert.Equal(route, Delivered(route.ToArguments()));
            Assert.Equal(route, NotificationRoute.FromLaunchArguments(route.ToLaunchArguments()));
        }
    }

    // Notifications posted before taps were routed carried only the work id, for
    // chapter alerts and single new works alike. Tapping one still opens the work.
    [Fact]
    public void LegacyWorkIdOnlyPayload_OpensTheWork()
    {
        Assert.Equal(new NotificationRoute.NewChapters(4242), Delivered(new Dictionary<string, string> { ["workId"] = "4242" }));
    }

    [Fact]
    public void IgnoresUnrelatedKeys()
    {
        Assert.Equal(new NotificationRoute.NewWork(7), Route(("aps", "{\"alert\":\"hi\"}"), ("kind", "newWork"), ("workId", "7")));
    }

    [Fact]
    public void PayloadWithNothingToOpen_IsNil()
    {
        Assert.Null(Route());
        // The Swift case was a string work id where an integer belongs; toast
        // arguments are all strings, so the equivalent is one that isn't a number.
        Assert.Null(Route(("workId", "12345x")));
        Assert.Null(Route(("workId", " 12345")));
        Assert.Null(Route(("kind", "newWork")));
        Assert.Null(Route(("kind", "newWorks")));
        Assert.Null(Route(("kind", "newWorks"), ("authorUsername", "")));
    }

    [Fact]
    public void NewWorksWithoutDisplayName_FallsBackToUsername()
    {
        var route = Route(("kind", "newWorks"), ("authorUsername", "some_login"), ("authorName", ""));
        Assert.Equal(new NotificationRoute.NewWorks(new AuthorRef("some_login", "some_login")), route);
    }

    // Opened with no tab showing yet (a cold launch), Back should land somewhere related.
    [Fact]
    public void LandingTab()
    {
        Assert.Equal(SidebarItem.Library, new NotificationRoute.NewChapters(1).LandingTab(workIsSaved: true));
        Assert.Equal(SidebarItem.Subscriptions, new NotificationRoute.NewChapters(1).LandingTab(workIsSaved: false));
        Assert.Equal(SidebarItem.Authors, new NotificationRoute.NewWork(1).LandingTab(workIsSaved: false));
        Assert.Equal(SidebarItem.Authors, new NotificationRoute.NewWorks(Author).LandingTab(workIsSaved: false));
        Assert.Equal("authors", SidebarItem.Authors.RawValue());
        Assert.Equal(SidebarItem.RecentlyViewed, SidebarItemExtensions.ParseSidebarItem("recentlyViewed"));
    }

    [Fact]
    public void ArgumentsUseTheSwiftKeys()
    {
        Assert.Equal(
            new Dictionary<string, string> { ["kind"] = "newChapters", ["workId"] = "12345" },
            new NotificationRoute.NewChapters(12345).ToArguments());
        Assert.Equal(
            new Dictionary<string, string> { ["kind"] = "newWorks", ["authorUsername"] = "some_login", ["authorName"] = "Some Pseud" },
            new NotificationRoute.NewWorks(Author).ToArguments());
        Assert.Equal(12345, new NotificationRoute.NewChapters(12345).TargetWorkId);
        Assert.Null(new NotificationRoute.NewWorks(Author).TargetWorkId);
    }

    // MARK: - What the poller actually posts
    // test_newChapterNotification_opensTheWork, test_singleNewWorkNotification_opensTheWork
    // and test_severalNewWorksNotification_opensTheAuthor exercise
    // SubscriptionPoller.newChapterContent/newWorkContent (the subscriptions
    // poller worker's area).
}
