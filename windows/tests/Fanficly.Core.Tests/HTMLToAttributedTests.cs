using Fanficly.Core;

namespace Fanficly.Core.Tests;

public class HTMLToAttributedTests
{
    [Fact]
    public void PlainParagraphsHaveBreaks()
    {
        var s = HTMLToAttributed.Convert("<p>Hello.</p><p>World.</p>").Text;
        Assert.Contains("Hello.", s);
        Assert.Contains("World.", s);
        Assert.Contains("\n\n", s);
    }

    [Fact]
    public void SpeechParagraphsSplitsAndCleans()
    {
        var paras = HTMLToAttributed.SpeechParagraphs("<p>Hello.</p><p>World.</p>");
        Assert.Equal(["Hello.", "World."], paras);
    }

    [Fact]
    public void SpeechParagraphsStaysIndexAlignedWithRenderedParagraphs()
    {
        const string html = "<p>One.</p><hr><ul><li>a</li><li>b</li></ul>";
        var rendered = HTMLToAttributed.ConvertParagraphs(html);
        var speech = HTMLToAttributed.SpeechParagraphs(html);
        // Same count as what the reader renders — the karaoke highlight relies
        // on a 1:1 paragraph index.
        Assert.Equal(rendered.Count, speech.Count);
        // The "· · ·" scene break becomes an empty (unspoken) entry; bullets
        // are stripped but the paragraph keeps its slot.
        Assert.DoesNotContain(speech, s => s.Contains('•'));
        Assert.DoesNotContain("· · ·", speech);
        Assert.Contains("", speech); // the separator's slot
        Assert.Contains("One.", speech);
        Assert.Contains("a", speech);
    }

    [Fact]
    public void SpeechParagraphsFlattensSoftBreaks()
    {
        Assert.Equal(["Line 1 Line 2"], HTMLToAttributed.SpeechParagraphs("<p>Line 1<br>Line 2</p>"));
    }

    [Fact]
    public void ItalicHasInlineIntent()
    {
        var output = HTMLToAttributed.Convert("<p>He said <em>hello</em>.</p>");
        var italic = output.Runs.FirstOrDefault(r => r.IsItalic);
        Assert.NotNull(italic);
        Assert.Equal("hello", italic.Text);
    }

    [Fact]
    public void BoldHasInlineIntent()
    {
        var output = HTMLToAttributed.Convert("<p>Run <strong>fast</strong>.</p>");
        var bold = output.Runs.FirstOrDefault(r => r.IsBold);
        Assert.NotNull(bold);
        Assert.Equal("fast", bold.Text);
    }

    [Fact]
    public void BrBecomesNewline()
    {
        Assert.Contains("Line 1\nLine 2", HTMLToAttributed.Convert("Line 1<br>Line 2").Text);
    }

    [Fact]
    public void BlockquoteIsBlockLevel()
    {
        var s = HTMLToAttributed.Convert("Before<blockquote>Quote</blockquote>After").Text;
        Assert.Contains("Before", s);
        Assert.Contains("Quote", s);
        Assert.Contains("After", s);
        Assert.True(s.Contains("\n\nQuote\n\n") || s.Contains("Before\n\nQuote"));
    }

    [Fact]
    public void HeadingBecomesItsOwnParagraph()
    {
        var s = HTMLToAttributed.Convert("<h2>Title</h2><p>Body.</p>").Text;
        Assert.Contains("Title", s);
        Assert.Contains("Body.", s);
        Assert.Contains("Title\n\nBody.", s);
    }

    [Fact]
    public void ListItemsBullet()
    {
        var s = HTMLToAttributed.Convert("<ul><li>One</li><li>Two</li></ul>").Text;
        Assert.Contains("•", s);
        Assert.Contains("One", s);
        Assert.Contains("Two", s);
    }

    [Fact]
    public void HorizontalRuleSceneBreak()
    {
        var s = HTMLToAttributed.Convert("<p>Before</p><hr><p>After</p>").Text;
        Assert.Contains("·", s);
        Assert.Contains("Before", s);
        Assert.Contains("After", s);
    }

    [Fact]
    public void UnderlineAndStrike()
    {
        Assert.Contains(HTMLToAttributed.Convert("<u>under</u>").Runs, r => r.IsUnderlined);
        Assert.Contains(HTMLToAttributed.Convert("<s>strike</s>").Runs, r => r.IsStrikethrough);
    }

    [Fact]
    public void ConvertParagraphsSplitsBlocks()
    {
        var paras = HTMLToAttributed.ConvertParagraphs("<p>First.</p><p>Second.</p><p>Third.</p>");
        Assert.Equal(3, paras.Count);
        Assert.Equal("First.", paras[0].Text);
        Assert.Equal("Third.", paras[2].Text);
    }

    [Fact]
    public void EmptyHTMLProducesNoParagraphs()
    {
        Assert.Empty(HTMLToAttributed.ConvertParagraphs(""));
        Assert.Empty(HTMLToAttributed.ConvertParagraphs("<p></p><p>  </p>"));
    }

    // MARK: - Embedded images (the "Show images in stories" setting)

    [Fact]
    public void ImagesDroppedByDefault()
    {
        // includeImages defaults to false — the historical behavior.
        const string html = "<p>Before.</p><img src=\"https://example.com/a.png\"><p>After.</p>";
        var paras = HTMLToAttributed.ConvertParagraphs(html);
        Assert.Equal(2, paras.Count);
        Assert.All(paras, p => Assert.Null(HTMLToAttributed.ImageAttachmentUrl(p)));
    }

    [Fact]
    public void ImageBecomesStandaloneSlotWhenEnabled()
    {
        const string html = "<p>Before.</p><img src=\"https://example.com/a.png\"><p>After.</p>";
        var paras = HTMLToAttributed.ConvertParagraphs(html, includeImages: true);
        Assert.Equal(3, paras.Count);
        Assert.Equal("Before.", paras[0].Text);
        Assert.Equal(new Uri("https://example.com/a.png"), HTMLToAttributed.ImageAttachmentUrl(paras[1]));
        Assert.Equal(ReaderParagraphKind.Image, paras[1].Kind);
        Assert.Equal("After.", paras[2].Text);
    }

    [Fact]
    public void InlineImageSplitsItsParagraph()
    {
        const string html = "<p>Look: <img src=\"https://example.com/a.png\"> amazing.</p>";
        var paras = HTMLToAttributed.ConvertParagraphs(html, includeImages: true);
        Assert.Equal(3, paras.Count);
        Assert.Equal("Look:", paras[0].Text);
        Assert.NotNull(HTMLToAttributed.ImageAttachmentUrl(paras[1]));
        Assert.Equal("amazing.", paras[2].Text);
    }

    [Fact]
    public void SpeechSkipsImageSlotsAndStaysAligned()
    {
        const string html = "<p>Before.</p><img src=\"https://example.com/a.png\"><p>After.</p>";
        var rendered = HTMLToAttributed.ConvertParagraphs(html, includeImages: true);
        var speech = HTMLToAttributed.SpeechParagraphs(html, includeImages: true);
        Assert.Equal(rendered.Count, speech.Count); // speech must stay index-aligned
        Assert.Equal(["Before.", "", "After."], speech); // image slots are unspoken
    }

    [Fact]
    public void ImageCacheKeysDoNotCollide()
    {
        // The same HTML converted with and without images must not share a
        // cache entry (regression: keying the cache on the HTML alone).
        const string html = "<p>Text.</p><img src=\"https://example.com/b.png\">";
        Assert.Equal(2, HTMLToAttributed.ConvertParagraphs(html, includeImages: true).Count);
        Assert.Single(HTMLToAttributed.ConvertParagraphs(html, includeImages: false));
        Assert.Equal(2, HTMLToAttributed.ConvertParagraphs(html, includeImages: true).Count);
    }

    [Fact]
    public void ImageURLResolution()
    {
        Assert.Equal(new Uri("https://example.com/a.png"), HTMLToAttributed.ResolvedImageUrl("https://example.com/a.png"));
        // Protocol-relative sources get https.
        Assert.Equal(new Uri("https://example.com/a.png"), HTMLToAttributed.ResolvedImageUrl("//example.com/a.png"));
        // Plain http upgrades to https.
        Assert.Equal(new Uri("https://example.com/a.png"), HTMLToAttributed.ResolvedImageUrl("http://example.com/a.png"));
        // Non-fetchable sources are rejected.
        Assert.Null(HTMLToAttributed.ResolvedImageUrl("data:image/png;base64,AAAA"));
        Assert.Null(HTMLToAttributed.ResolvedImageUrl("javascript:alert(1)"));
        Assert.Null(HTMLToAttributed.ResolvedImageUrl(""));
        Assert.Null(HTMLToAttributed.ResolvedImageUrl("   "));
        Assert.Null(HTMLToAttributed.ResolvedImageUrl("https://"));
        // AO3 itself is never an image target: image loads bypass the AO3
        // throttle and User-Agent while carrying the session cookie, so
        // root-relative paths and archiveofourown.org hosts are rejected.
        Assert.Null(HTMLToAttributed.ResolvedImageUrl("/attachments/a.png"));
        Assert.Null(HTMLToAttributed.ResolvedImageUrl("https://archiveofourown.org/a.png"));
        Assert.Null(HTMLToAttributed.ResolvedImageUrl("https://www.archiveofourown.org/a.png"));
    }

    [Fact]
    public void ImageWithUnusableSrcIsDroppedEvenWhenEnabled()
    {
        const string html = "<p>Before.</p><img src=\"data:image/png;base64,AAAA\"><p>After.</p>";
        Assert.Equal(2, HTMLToAttributed.ConvertParagraphs(html, includeImages: true).Count);
    }

    [Fact]
    public void StripsHtmlTagsWhenUnknown()
    {
        Assert.Contains("Visible", HTMLToAttributed.Convert("<span class='foo'>Visible</span>").Text);
    }

    [Fact]
    public void EmptyParagraphsDoNotStackBlankLines()
    {
        // AO3 fics use empty <p> / whitespace paragraphs for scene breaks.
        var s = HTMLToAttributed.Convert("<p>First.</p><p></p><p>&nbsp;</p><p>Second.</p>").Text;
        Assert.Contains("First.", s);
        Assert.Contains("Second.", s);
        Assert.DoesNotContain("\n\n\n", s); // should never have 3+ consecutive newlines
    }

    [Fact]
    public void SourceWhitespaceCollapsed()
    {
        Assert.Contains("Hello world.", HTMLToAttributed.Convert("<p>Hello    \n    world.</p>").Text);
    }

    [Fact]
    public void NestedFormatting()
    {
        var output = HTMLToAttributed.Convert("<p><strong><em>both</em></strong></p>");
        Assert.Contains(output.Runs, r => r.IsBold && r.IsItalic);
    }

    [Fact]
    public void SplitIntoSentencesPreservesFormatting()
    {
        var text = HTMLToAttributed.Convert("<p>First sentence. <em>Second sentence is italicized.</em> Third sentence.</p>");
        var sentences = HTMLToAttributed.SplitIntoSentences(text);
        Assert.Equal(3, sentences.Count);
        Assert.Equal("First sentence. ", sentences[0].Text);
        Assert.Equal("Second sentence is italicized. ", sentences[1].Text);
        Assert.Equal("Third sentence.", sentences[2].Text);
        Assert.Contains(sentences[1].Runs, r => r.IsItalic);
    }

    [Fact]
    public void ConvertCachingIsTransparent()
    {
        const string html = "<p>Test caching <strong>formatting</strong>.</p>";
        var firstResult = HTMLToAttributed.Convert(html);
        var secondResult = HTMLToAttributed.Convert(html);
        Assert.Equal(firstResult, secondResult);
    }

    // MARK: - Hyperlinks

    [Fact]
    public void AnchorCarriesLinkInConvert()
    {
        var output = HTMLToAttributed.Convert("<p>See <a href=\"https://example.com/fic\">this fic</a> too.</p>");
        var linkRun = output.Runs.FirstOrDefault(r => r.Link is not null);
        Assert.NotNull(linkRun);
        Assert.Equal(new Uri("https://example.com/fic"), linkRun.Link);
        Assert.Equal("this fic", linkRun.Text);
        // Link runs are underlined so a themed foreground can't hide them.
        Assert.True(linkRun.IsUnderlined);
    }

    [Fact]
    public void LinkURLResolution()
    {
        Assert.Equal(new Uri("https://example.com/a"), HTMLToAttributed.ResolvedLinkUrl("https://example.com/a"));
        // http upgrades to https.
        Assert.Equal(new Uri("https://example.com/a"), HTMLToAttributed.ResolvedLinkUrl("http://example.com/a"));
        // Protocol-relative gets https.
        Assert.Equal(new Uri("https://example.com/a"), HTMLToAttributed.ResolvedLinkUrl("//example.com/a"));
        // Root-relative resolves against AO3 (work/user links in notes).
        Assert.Equal(new Uri("https://archiveofourown.org/works/123"), HTMLToAttributed.ResolvedLinkUrl("/works/123"));
        // Unusable hrefs are rejected.
        Assert.Null(HTMLToAttributed.ResolvedLinkUrl("javascript:alert(1)"));
        Assert.Null(HTMLToAttributed.ResolvedLinkUrl("data:text/html,hi"));
        Assert.Null(HTMLToAttributed.ResolvedLinkUrl("mailto:a@b.c"));
        Assert.Null(HTMLToAttributed.ResolvedLinkUrl("#footnote1"));
        Assert.Null(HTMLToAttributed.ResolvedLinkUrl("works/123"));
        Assert.Null(HTMLToAttributed.ResolvedLinkUrl(""));
    }

    [Fact]
    public void RejectedAnchorStillRendersItsText()
    {
        var output = HTMLToAttributed.Convert("<p>Click <a href=\"javascript:alert(1)\">here</a> now.</p>");
        Assert.Contains("Click here now.", output.Text);
        Assert.DoesNotContain(output.Runs, r => r.Link is not null);
    }

    [Fact]
    public void ChapterBodyPathDropsLinksAndStaysAligned()
    {
        const string html = "<p>Read <a href=\"https://example.com\">this</a>.</p><p>Next.</p>";
        // The reader's chapter-body path (ConvertParagraphs default) must not
        // produce tappable links — they'd fight the tap-to-turn zones.
        var rendered = HTMLToAttributed.ConvertParagraphs(html);
        Assert.DoesNotContain(rendered, para => para.Runs.Any(r => r.Link is not null));
        // The anchor's text still renders and speech stays index-aligned.
        Assert.Equal("Read this.", rendered[0].Text);
        Assert.Equal(["Read this.", "Next."], HTMLToAttributed.SpeechParagraphs(html));
    }

    [Fact]
    public void LinkCacheKeysDoNotCollide()
    {
        const string html = "<p><a href=\"https://example.com\">link</a></p>";
        var without = HTMLToAttributed.ConvertParagraphs(html);
        var with = HTMLToAttributed.ConvertParagraphs(html, includeLinks: true);
        Assert.DoesNotContain(without[0].Runs, r => r.Link is not null);
        Assert.Contains(with[0].Runs, r => r.Link is not null);
        // Ask again in the original mode — must not get the linked variant back.
        var again = HTMLToAttributed.ConvertParagraphs(html);
        Assert.DoesNotContain(again[0].Runs, r => r.Link is not null);
    }

    // MARK: - Windows port additions

    [Fact]
    public void ParagraphKindsMatchWhatTheReaderDraws()
    {
        var paras = HTMLToAttributed.ConvertParagraphs("<p>Prose.</p><hr><ul><li>item</li></ul>");
        Assert.Equal([ReaderParagraphKind.Text, ReaderParagraphKind.SceneBreak, ReaderParagraphKind.ListItem],
                     paras.Select(p => p.Kind));
    }

    [Fact]
    public void SentencesKeepAbbreviationsDecimalsAndDialogueTogether()
    {
        string[] Split(string s) => HTMLToAttributed.SplitIntoSentences(new ReaderRichText(s)).Select(x => x.Text).ToArray();
        Assert.Equal(["It cost 3.5 dollars, e.g. a lot. ", "Then he left."], Split("It cost 3.5 dollars, e.g. a lot. Then he left."));
        Assert.Equal(["“Stay.” he said. ", "She went!"], Split("“Stay.” he said. She went!"));
        Assert.Equal(["Line one\n", "Line two"], Split("Line one\nLine two"));
        Assert.Equal(["no terminator"], Split("no terminator"));
    }
}
