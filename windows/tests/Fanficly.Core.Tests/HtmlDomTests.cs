using Fanficly.Core;

namespace Fanficly.Core.Tests;

/// <summary>Pins <see cref="HtmlDom.Text"/> to SwiftSoup's <c>Element.text()</c>, which
/// every parser's output (and the ported fixtures) depends on.</summary>
public class HtmlDomTests
{
    private static string BodyText(string html) => HtmlDom.Parse(html).Body.Text();

    [Fact]
    public void CollapsesWhitespaceAndTrims()
    {
        Assert.Equal("a b c", BodyText("<p>  a \n\t b   c  </p>"));
    }

    [Fact]
    public void NbspCollapsesLikeASpace()
    {
        Assert.Equal("a b", BodyText("<span>a&nbsp;&nbsp; b</span>"));
    }

    [Fact]
    public void BlockElementsAndBrAreSeparatedBySpaces()
    {
        Assert.Equal("one two three four", BodyText("<div>one</div><p>two</p> three<br>four"));
        // SwiftSoup adds the space only where a block *starts*, not where it ends.
        Assert.Equal("one twothree", BodyText("<div>one</div><p>two</p>three"));
        Assert.Equal("ab", BodyText("<span>a</span><span>b</span>"));
    }

    [Fact]
    public void InlineMarkupKeepsWordsTogether()
    {
        Assert.Equal("Bella poured the latte. It was hot.", BodyText("<p>Bella poured the latte. <em>It was hot.</em></p>"));
    }

    [Fact]
    public void PreKeepsItsWhitespace()
    {
        Assert.Equal("x   a\n  b", BodyText("<span>x </span><pre>  a\n  b</pre>"));
    }

    [Fact]
    public void ScriptAndStyleAreNotText()
    {
        Assert.Equal("a b", BodyText("a<script>var x = 1;</script><style>p{}</style>b"));
    }

    [Fact]
    public void SelectIncludesTheRootLikeJsoup()
    {
        var li = HtmlDom.Parse("<ol><li class='current'>2</li></ol>").QuerySelector("li")!;
        Assert.Single(li.Select(".current"));
    }

    [Fact]
    public void ParseSwiftIntIsStrict()
    {
        Assert.Equal(12, HtmlDom.ParseSwiftInt("12"));
        Assert.Equal(-3, HtmlDom.ParseSwiftInt("-3"));
        Assert.Null(HtmlDom.ParseSwiftInt(" 12"));
        Assert.Null(HtmlDom.ParseSwiftInt("1,2"));
        Assert.Null(HtmlDom.ParseSwiftInt(""));
        Assert.Null(HtmlDom.ParseSwiftInt("99999999999"));
    }
}
