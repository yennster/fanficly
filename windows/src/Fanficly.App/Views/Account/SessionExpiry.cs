using Fanficly.App.UI;
using Fanficly.Core;
using Microsoft.UI.Xaml;

namespace Fanficly.App.Views.Account;

/// <summary>
/// What an expired AO3 session looks like (#131): signed in on this PC, but AO3
/// answered with its login page, or a listing rendered for a guest (which leaves
/// out restricted works). Retrying can't help, so these offer "Sign In Again",
/// which opens the sign-in form with the username filled in.
/// </summary>
internal static class SessionExpiry
{
    public const string Title = "Your AO3 session expired";
    public const string ActionTitle = "Sign In Again";
    public const string Message = "AO3 signed you out. Sign in again to keep using your AO3 account here.";
    public const string ListingMessage = "AO3 signed you out, so it only sent the works a guest can see. Sign in again to see restricted works too.";

    /// <summary>Passes a works listing through, throwing <see cref="GuestListing"/>
    /// when AO3 rendered it for a guest while signed in (and marking the session
    /// expired): showing it would quietly drop every restricted work.</summary>
    public static AO3SearchResults Check(AO3SearchResults results) =>
        AppHost.Auth.NoteListing(results) ? throw new GuestListing() : results;

    /// <summary>Whether a failure means the session expired, noting it on
    /// <see cref="AppHost.Auth"/> (a guest listing, or Unauthorized while signed in).</summary>
    public static bool Explains(Exception error) => error is GuestListing || AppHost.Auth.NoteFailure(error);

    /// <summary>What to say for a failure <see cref="Explains"/> accepted.</summary>
    public static string MessageFor(Exception error) => error is GuestListing ? ListingMessage : Message;

    /// <summary>A listing AO3 rendered for a guest while signed in.</summary>
    public sealed class GuestListing() : Exception(ListingMessage);

    /// <summary>The full-page state: the message and a Sign In Again button.</summary>
    public static FrameworkElement EmptyState(string message = Message) =>
        UI.UI.EmptyState("person.crop.circle.badge.questionmark", Title, message, ActionTitle, Routes.OpenLogin)
            .Id("session.expired");
}
