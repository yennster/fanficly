namespace Fanficly.Core;

/// <summary>Opens a work's reader at the widget's position:
/// <c>fanficly://resume/&lt;workId&gt;?chapter=&lt;n&gt;&amp;paragraph=&lt;m&gt;</c>.</summary>
public sealed record ResumeWorkRoute(int WorkId, ReadingAnchor? Anchor);

/// <summary>
/// Decides which anchor (if any) a widget-resume tap may install as reading
/// progress. The rule: a resume tap must never move saved progress backwards.
///
/// The URL anchor is a snapshot baked into the widget, and widget refreshes are
/// budget-throttled — the widget can lag hours behind the last save. The
/// widget-store payload is rewritten on every progress save, so when both exist
/// the store entry is at least as fresh as the URL. And because a progress save
/// stamps the local record and the widget payload with the same date, a store
/// entry only reads <i>strictly</i> fresher when it came from somewhere else
/// (progress synced from another device) — exactly the one case that may
/// override local progress.
/// </summary>
public static class ResumeProgressPolicy
{
    public static ReadingAnchor? AnchorToInstall(
        ReadingAnchor? routeAnchor,
        ReadingAnchor? widgetAnchor,
        DateTimeOffset? widgetFreshness,
        DateTimeOffset? existingUpdatedAt)
    {
        if (existingUpdatedAt is not { } existing)
        {
            // No local progress — seed from whatever we have, preferring the
            // store payload over the possibly-stale URL snapshot.
            return widgetAnchor ?? routeAnchor;
        }
        // Local progress exists. Only a strictly fresher widget-store entry may
        // move it; the URL anchor carries no timestamp, so it never can. When the
        // fresher store payload has no chapter there is nothing safe to install —
        // navigate and let the local progress win.
        if (widgetFreshness is not { } freshness || freshness <= existing) return null;
        return widgetAnchor;
    }

    /// <summary>The widget-store entry if it is for <paramref name="workId"/>
    /// (the store holds only the last-read work), else null.</summary>
    public static WidgetStoryProgress? MatchingWidgetProgress(int workId, WidgetStoryProgress? widgetProgress) =>
        widgetProgress?.Id == workId ? widgetProgress : null;

    /// <summary>The store entry's position, clamped like the route's (chapter ≥ 1,
    /// paragraph ≥ 0); null when it carries no chapter.</summary>
    public static ReadingAnchor? WidgetAnchor(WidgetStoryProgress? progress) =>
        progress?.Chapter is { } chapter ? new ReadingAnchor(Math.Max(chapter, 1), Math.Max(progress.Paragraph ?? 0, 0)) : null;

    /// <summary>What RootView's <c>installResumeProgressIfAvailable</c> computes:
    /// the anchor to install for a resume tap, given the widget store's current
    /// entry (<see cref="WidgetProgressStore.Load"/>) and when the work's local
    /// progress was last saved (null when it has none).</summary>
    public static ReadingAnchor? AnchorToInstall(
        ResumeWorkRoute route, WidgetStoryProgress? widgetProgress, DateTimeOffset? existingUpdatedAt)
    {
        var matching = MatchingWidgetProgress(route.WorkId, widgetProgress);
        return AnchorToInstall(route.Anchor, WidgetAnchor(matching), matching?.FreshnessDate, existingUpdatedAt);
    }
}

/// <summary>
/// Where a reader opens a work (#160). Reading chapter 20 on one device and then
/// opening the story on another that last saw chapter 12 used to open at 12 and,
/// on close, stamp 12 as the newest place, so the widget, the synced last-read
/// entry and the next backup merge all went back to 12. The synced entry wins by
/// the widget tap's rule (<see cref="ResumeProgressPolicy"/>): only when it is for
/// this work and strictly newer than the local save, which stamps both stores
/// with the same date, so this device's own saves always tie.
/// </summary>
public static class OpeningProgressPolicy
{
    public static ReadingAnchor? Anchor(
        int workId, ReadingAnchor? local, DateTimeOffset? localUpdatedAt, WidgetStoryProgress? synced)
    {
        var matching = ResumeProgressPolicy.MatchingWidgetProgress(workId, synced);
        return ResumeProgressPolicy.AnchorToInstall(
            null, ResumeProgressPolicy.WidgetAnchor(matching), matching?.FreshnessDate,
            local is null ? null : localUpdatedAt) ?? local;
    }
}

/// <summary>Keeps a reader from saving the place it opened at until the reader
/// moves (#160). A save stamps the place as the newest read anywhere, so closing a
/// story you only glanced at must not re-stamp it over a newer place another
/// device saved since. Once a different place is offered, the opened one is a real
/// place again: moving away and back saves it.</summary>
public struct OpenedAnchorGate(ReadingAnchor? openedAnchor)
{
    public ReadingAnchor? OpenedAnchor { get; private set; } = openedAnchor;

    /// <summary>Whether <paramref name="anchor"/> is worth saving. Call it for
    /// every save the reader attempts, before any throttling, so a move away is
    /// never missed.</summary>
    public bool AllowsSave(ReadingAnchor anchor)
    {
        if (anchor != OpenedAnchor) OpenedAnchor = null;
        return anchor != OpenedAnchor;
    }
}
