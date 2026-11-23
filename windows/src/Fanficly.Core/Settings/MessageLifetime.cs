namespace Fanficly.Core;

/// <summary>
/// How long an in-app message (the window's InfoBars) stays up (#205). A
/// confirmation ("Downloaded", "Link copied") closes by itself; an error or a
/// warning stays until it's closed, so its reason can be read at any pace
/// (WCAG 2.2.1), as the Apple app's alerts wait for OK.
/// </summary>
public static class MessageLifetime
{
    /// <summary>The most messages on screen at once; a new one past it
    /// replaces the oldest, so errors that wait to be closed can't pile up
    /// over the window.</summary>
    public const int MaxMessages = 3;

    /// <summary>A confirmation's default time on screen.</summary>
    public const int DefaultSeconds = 4;

    /// <summary>Seconds before the message closes by itself, or null when it
    /// stays until closed. <paramref name="requested"/> is the caller's own
    /// time for a confirmation; an error or warning ignores it.</summary>
    public static int? Seconds(bool isProblem, int? requested = null) =>
        isProblem ? null : Math.Max(requested ?? DefaultSeconds, 1);

    /// <summary>A reason followed by more sentences, with the full stop an
    /// exception's message often leaves off.</summary>
    public static string Sentence(string reason)
    {
        var trimmed = reason.TrimEnd();
        return trimmed.Length == 0 || ".!?…".Contains(trimmed[^1]) ? trimmed : trimmed + ".";
    }
}
