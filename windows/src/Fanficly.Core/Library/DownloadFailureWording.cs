namespace Fanficly.Core;

/// <summary>
/// Says which step of a download for offline reading failed (#205): getting
/// the story's text from AO3, or the EPUB after it. Used by the Library's
/// Download, the saved reader's Save Offline and the work page's Download.
/// </summary>
public static class DownloadFailureWording
{
    /// <param name="textSaved">The story's text reads offline: saved by this
    /// download or kept from an earlier one.</param>
    /// <param name="fetchingEpub">The failure came from the EPUB step.</param>
    /// <param name="reason">The exception's message.</param>
    public static string For(bool textSaved, bool fetchingEpub, string reason)
    {
        if (!fetchingEpub) return $"Couldn't get the story's text from AO3, so nothing was saved: {reason}";
        return textSaved
            ? $"The text is saved for offline reading, but the EPUB download failed: {reason}"
            : $"The EPUB download failed: {reason}";
    }
}
