using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>The work page's kudos form, as AO3 renders it (<c>form_for(:kudo, …)</c>
/// in otwarchive's <c>comments/_commentable.html.erb</c>), and AO3's <c>/kudos.js</c> answers.</summary>
public class KudosParserTests
{
    [Fact]
    public void FormFieldsCaptureTheHiddenInputs()
    {
        var fields = KudosParser.FormFields("""
            <html><body><ul class="work navigation actions">
              <li><form id="new_kudo" action="/kudos" accept-charset="UTF-8" method="post">
                <input type="hidden" name="authenticity_token" value="TOK" autocomplete="off" />
                <input value="12345" autocomplete="off" type="hidden" name="kudo[commentable_id]" id="kudo_commentable_id" />
                <input value="Work" autocomplete="off" type="hidden" name="kudo[commentable_type]" id="kudo_commentable_type" />
                <input type="submit" name="commit" value="Kudos ♥" id="kudo_submit" />
              </form></li>
            </ul></body></html>
            """);
        Assert.NotNull(fields);
        Assert.Equal("TOK", fields["authenticity_token"]);
        Assert.Equal("12345", fields["kudo[commentable_id]"]);
        Assert.Equal("Work", fields["kudo[commentable_type]"]);
        Assert.False(fields.ContainsKey("commit"));
    }

    [Fact]
    public void NoFormFieldsWithoutTheKudosButton()
    {
        // Your own work, or a creator who blocked you: AO3 leaves the form out.
        Assert.Null(KudosParser.FormFields("""<html><body><form id="new_comment"></form></body></html>"""));
        Assert.Null(KudosParser.FormFields("""<form id="new_kudo"><input type="hidden" name="authenticity_token" value="T"></form>"""));
    }

    [Fact]
    public void ErrorMessageReadsAO3sJson()
    {
        Assert.Equal("You have already left kudos here. :)",
            KudosParser.ErrorMessage("""{"error_message":"You have already left kudos here. :)"}"""));
        Assert.Null(KudosParser.ErrorMessage("Retry later"));
        Assert.Null(KudosParser.ErrorMessage("""{"error_message":"  "}"""));
        Assert.Null(KudosParser.ErrorMessage("[]"));
    }

    [Fact]
    public void OnlyTheDuplicateAnswerIsAlreadyLeft()
    {
        Assert.True(KudosParser.IsAlreadyLeft("You have already left kudos here. :)"));
        Assert.False(KudosParser.IsAlreadyLeft("You can't leave kudos on your own work."));
        Assert.False(KudosParser.IsAlreadyLeft("Sorry, you have been blocked by one or more of this work's creators."));
    }
}

/// <summary><see cref="KudosGiver"/> sends one kudo per click, remembers it per
/// account so the menu item reads "Kudos Left", and turns AO3's refusals into
/// what the screen shows (the Swift app's <c>KudosGiverTests</c>).</summary>
public class KudosGiverTests
{
    private readonly InMemoryKeyValueStore _store = new();

    [Fact]
    public async Task LeavingKudosRemembersTheWorkForThatAccount()
    {
        var client = new StubAO3Client();
        var giver = new KudosGiver(_store);
        var result = await giver.LeaveAsync(7, "reader", client);

        Assert.Equal([7], client.KudosCalls);
        Assert.True(giver.HasLeft);
        Assert.Equal("Kudos left", result?.Title);
        Assert.True(KudosStore.HasLeft(7, "Reader", _store));
        Assert.False(KudosStore.HasLeft(7, "someone-else", _store));
        Assert.False(KudosStore.HasLeft(8, "reader", _store));
    }

    [Fact]
    public async Task ASecondClickSendsNothing()
    {
        var client = new StubAO3Client();
        var giver = new KudosGiver(_store);
        await giver.LeaveAsync(7, "reader", client);
        Assert.Null(await giver.LeaveAsync(7, "reader", client));
        Assert.Equal([7], client.KudosCalls);
    }

    [Fact]
    public void RememberedKudosShowOnTheNextScreen()
    {
        KudosStore.MarkLeft(7, "reader", _store);
        KudosStore.MarkLeft(9, "reader", _store);
        var giver = new KudosGiver(_store);
        giver.Refresh(7, "reader");
        Assert.True(giver.HasLeft);
        giver.Refresh(7, null);
        Assert.False(giver.HasLeft);
        Assert.True(KudosStore.HasLeft(9, "reader", _store));
    }

    [Fact]
    public async Task SignedOutSendsNothing()
    {
        var client = new StubAO3Client();
        var giver = new KudosGiver(_store);
        Assert.Null(await giver.LeaveAsync(7, null, client));
        Assert.Empty(client.KudosCalls);
        Assert.False(giver.HasLeft);
    }

    [Fact]
    public async Task AlreadyLeftOnAO3IsRemembered()
    {
        var client = new StubAO3Client { KudosOutcome = KudosOutcome.AlreadyLeft };
        var giver = new KudosGiver(_store);
        var result = await giver.LeaveAsync(7, "reader", client);

        Assert.True(giver.HasLeft);
        Assert.Equal("Kudos already left", result?.Title);
        Assert.True(KudosStore.HasLeft(7, "reader", _store));
    }

    [Fact]
    public async Task ARefusalShowsAO3sReasonAndRemembersNothing()
    {
        var client = new StubAO3Client { KudosError = AO3Exception.Rejected("You can't leave kudos on your own work.") };
        var giver = new KudosGiver(_store);
        var result = await giver.LeaveAsync(7, "reader", client);

        Assert.False(giver.HasLeft);
        Assert.False(giver.IsSending);
        Assert.Equal("You can't leave kudos on your own work.", result?.Message);
        Assert.False(KudosStore.HasLeft(7, "reader", _store));
    }

    [Fact]
    public async Task AnExpiredSessionOffersSignIn()
    {
        var client = new StubAO3Client { KudosError = AO3Exception.Unauthorized() };
        var result = await new KudosGiver(_store).LeaveAsync(7, "reader", client);
        Assert.True(result?.NeedsSignIn);
    }
}
