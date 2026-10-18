using System.Text.RegularExpressions;
using AngleSharp.Dom;

namespace Fanficly.Core;

/// <summary>Parses a full work page (<c>?view_full_work=true</c>): metadata plus every
/// chapter's HTML.</summary>
public static partial class WorkPageParser
{
    public static AO3WorkPayload Parse(string html, int workId) => Parse(HtmlDom.Parse(html), workId);

    /// <summary>Parses a work page in AO3's default view, one chapter to a page.
    /// The chapter is numbered by its place in the page's chapter menu, which is
    /// the order the whole-work page lists chapters in, so the two number alike.</summary>
    public static AO3WorkChapterPage ParseChapterPage(string html, int workId)
    {
        var doc = HtmlDom.Parse(html);
        var payload = Parse(doc, workId);
        var ids = ChapterIndexIds(doc);
        if (payload.Chapters is [var only] && ids.Count > 1)
        {
            var div = doc.SelectFirst("div.chapter[id^='chapter-']");
            var ownId = div is null ? null : ChapterAoId(div);
            int? position = ownId is { } id && ids.IndexOf(id) is >= 0 and var at ? at + 1 : null;
            // Otherwise AO3's own numbering: <div class="chapter" id="chapter-3">.
            if (position is null && div is not null
                && HtmlDom.ParseSwiftInt(div.Attr("id")["chapter-".Length..]) is { } n && n >= 1 && n <= ids.Count)
                position = n;
            var index = position ?? 1;
            payload = payload with { Chapters = [only with { Index = index, AoId = ownId ?? ids[index - 1] }] };
        }
        var expected = Math.Max(Math.Max(ids.Count, payload.Summary.ChapterCount), 1);
        return new AO3WorkChapterPage(payload, ids, IsWholeWork: payload.Chapters.Count >= expected);
    }

    private static AO3WorkPayload Parse(IDocument doc, int workId)
    {
        // Strip AO3's screen-reader-only landmark headings ("Chapter Text",
        // "Work Text", "Notes", etc.) so they don't render in the body.
        foreach (var landmark in doc.Select("h3.landmark, .landmark.heading")) landmark.Remove();

        var title = FirstNonEmptyText(doc,
            "#workskin .preface.group h2.title.heading",
            "#workskin h2.title.heading",
            "h2.title.heading",
            "h2.title");

        var author = ParseAuthor(doc);

        // First byline link's /users/<login> segment, for "more by this author".
        var authorHref = doc.SelectFirst("h3.byline a")?.Attr("href")
            ?? doc.SelectFirst("dl.work.meta dd.creator a")?.Attr("href")
            ?? "";
        var authorUsername = SearchResultsParser.AuthorLogin(authorHref);

        var meta = doc.SelectFirst("dl.work.meta.group");
        var rating = meta?.SelectFirst("dd.rating a.tag")?.Text() ?? "Not Rated";
        var warnings = Texts(meta, "dd.warning a.tag");
        var categories = Texts(meta, "dd.category a.tag");
        var fandoms = Texts(meta, "dd.fandom a.tag");
        var relationships = Texts(meta, "dd.relationship a.tag");
        var characters = Texts(meta, "dd.character a.tag");
        var freeforms = Texts(meta, "dd.freeform a.tag");
        var language = meta?.SelectFirst("dd.language")?.Text().TrimSwiftWhitespaces() ?? "English";

        var statsDl = meta?.SelectFirst("dl.stats");
        var wordCount = ParseInt(statsDl?.SelectFirst("dd.words")?.Text() ?? "0");
        var kudos = ParseInt(statsDl?.SelectFirst("dd.kudos")?.Text() ?? "0");
        var hits = ParseInt(statsDl?.SelectFirst("dd.hits")?.Text() ?? "0");

        var (chapterCount, totalChapters) = HtmlDom.ParseChapterFraction(statsDl?.SelectFirst("dd.chapters")?.Text() ?? "1/1");
        var isComplete = totalChapters is not null && chapterCount == totalChapters;

        var summary = doc.SelectFirst("#workskin .summary blockquote.userstuff, .summary blockquote.userstuff").InnerHtml();

        var chapters = ParseChapters(doc);

        var publishedAt = HtmlDom.ParseDate(statsDl?.SelectFirst("dd.published")?.Text() ?? "", "yyyy-MM-dd");
        var updatedAt = HtmlDom.ParseDate(statsDl?.SelectFirst("dd.status")?.Text() ?? "", "yyyy-MM-dd") ?? publishedAt;

        var summaryRecord = new AO3WorkSummary
        {
            Id = workId,
            Title = title,
            Author = author,
            AuthorUsername = authorUsername,
            Summary = summary,
            Rating = rating,
            Warnings = warnings,
            Categories = categories,
            Fandoms = fandoms,
            Characters = characters,
            Relationships = relationships,
            Freeforms = freeforms,
            WordCount = wordCount,
            ChapterCount = chapterCount,
            TotalChapters = totalChapters,
            Language = language,
            Kudos = kudos,
            Hits = hits,
            IsComplete = isComplete,
            UpdatedAt = updatedAt,
        };
        return new AO3WorkPayload(summaryRecord, chapters);
    }

    private static string ParseAuthor(IDocument doc)
    {
        if (doc.SelectFirst("h3.byline") is { } byline)
        {
            var nonEmpty = byline.Select("a").Select(a => a.Text()).Where(t => t.Length > 0).ToList();
            if (nonEmpty.Count > 0) return string.Join(", ", nonEmpty);
            var txt = byline.Text().TrimSwiftWhitespaces();
            if (txt.Length > 0)
            {
                if (txt.ToLowerInvariant().StartsWith("by ", StringComparison.Ordinal))
                    return txt[3..].TrimSwiftWhitespaces();
                return txt;
            }
        }
        if (doc.SelectFirst("dl.work.meta dd.creator a, dl.work.meta dd.creator") is { } creator)
            return creator.Text().TrimSwiftWhitespaces();
        return "Anonymous";
    }

    private static List<AO3ChapterPayload> ParseChapters(IDocument doc)
    {
        // Ordered AO3 chapter ids (from the jump menu / index) so each rendered
        // chapter can map sequence → id for per-chapter comments.
        var orderedIds = ChapterIndexIds(doc);
        int? IdAt(int index) => index < orderedIds.Count ? orderedIds[index] : null;

        var nestedChapters = doc.Select("div.chapter[id^='chapter-']");
        if (nestedChapters.Count > 0)
        {
            return nestedChapters.Select((div, index) => new AO3ChapterPayload(
                index + 1,
                CleanChapterTitle(div.SelectFirst("h3.title")?.Text() ?? "", index + 1),
                div.SelectFirst("div.userstuff").InnerHtml(),
                ChapterAoId(div) ?? IdAt(index))).ToList();
        }

        var workskinChapters = doc.Select("#workskin > div.chapter, #workskin div[role='article']");
        if (workskinChapters.Count > 0)
        {
            return workskinChapters.Select((div, index) => new AO3ChapterPayload(
                index + 1,
                CleanChapterTitle(div.SelectFirst("h3.title, h2.title")?.Text() ?? "", index + 1),
                div.SelectFirst("div.userstuff").InnerHtml(),
                ChapterAoId(div) ?? IdAt(index))).ToList();
        }

        if (doc.SelectFirst("#workskin .userstuff, div#chapters div.userstuff, div#chapters") is { } single)
            return [new AO3ChapterPayload(1, "", single.InnerHtml(), IdAt(0))];

        return [];
    }

    /// <summary>A chapter's AO3 id from its heading link — full-work view links each
    /// chapter title to <c>/works/&lt;id&gt;/chapters/&lt;chapterId&gt;</c>.</summary>
    private static int? ChapterAoId(IElement div)
    {
        if (div.SelectFirst("h3.title a[href], h3.landmark.heading a[href]") is { } heading
            && ChapterId(heading.Attr("href")) is { } id)
            return id;
        if (div.SelectFirst("a[href*='/chapters/']") is { } link && ChapterId(link.Attr("href")) is { } id2)
            return id2;
        return null;
    }

    /// <summary>Ordered chapter ids from the chapter jump <c>&lt;select id="selected_id"&gt;</c>
    /// (its option values are chapter ids) or, failing that, the chapter index
    /// links — so multi-chapter works map sequence → AO3 chapter id.</summary>
    private static List<int> ChapterIndexIds(IDocument doc)
    {
        var options = doc.Select("select#selected_id option");
        if (options.Count > 0)
        {
            var ids = options.Select(o => HtmlDom.ParseSwiftInt(o.Attr("value").TrimSwiftWhitespaces()))
                .OfType<int>().ToList();
            if (ids.Count > 0) return ids;
        }
        var links = doc.Select("#chapter_index a[href*='/chapters/'], ol.chapter.index a[href*='/chapters/']");
        if (links.Count > 0)
        {
            var ids = links.Select(a => ChapterId(a.Attr("href"))).OfType<int>().ToList();
            if (ids.Count > 0) return ids;
        }
        return [];
    }

    [GeneratedRegex(@"/chapters/(\d+)")]
    private static partial Regex ChapterHrefRegex();

    /// <summary>Extracts <c>123</c> from a <c>/works/9/chapters/123</c> style href.</summary>
    public static int? ChapterId(string href)
    {
        var m = ChapterHrefRegex().Match(href);
        return m.Success ? HtmlDom.ParseSwiftInt(m.Groups[1].Value) : null;
    }

    [GeneratedRegex(@"^Chapter\s+\d+\s*:?\s*")]
    private static partial Regex ChapterPrefixRegex();

    [GeneratedRegex(@"^Chapter\s+\d+$")]
    private static partial Regex BareChapterRegex();

    /// <summary>AO3 prefixes each chapter heading with "Chapter N: ". Strip that so
    /// the UI can render the chapter number itself, and treat a bare "Chapter N"
    /// (author gave no real title) as no title at all.</summary>
    public static string CleanChapterTitle(string raw, int index)
    {
        var t = raw.TrimSwiftWhitespaces();
        var m = ChapterPrefixRegex().Match(t);
        if (m.Success) t = t[m.Length..].TrimSwiftWhitespaces();
        // What remains being just "Chapter N" (any number) means no real title.
        return BareChapterRegex().IsMatch(t) ? "" : t;
    }

    private static string FirstNonEmptyText(IDocument doc, params string[] selectors)
    {
        foreach (var sel in selectors)
        {
            if (doc.SelectFirst(sel) is not { } el) continue;
            var text = el.Text().TrimSwiftWhitespaces();
            if (text.Length > 0) return text;
        }
        return "";
    }

    private static List<string> Texts(IElement? scope, string selector) =>
        scope?.Select(selector).Select(e => e.Text()).ToList() ?? [];

    private static int ParseInt(string s) =>
        HtmlDom.ParseSwiftInt(s.Replace(",", "", StringComparison.Ordinal).TrimSwiftWhitespaces()) ?? 0;
}

/// <summary>The page's top-level new-comment form: where it posts and its hidden
/// fields (CSRF token, the <c>commentable</c> fields, the default pseud).</summary>
public sealed record CommentForm(Uri Action, IReadOnlyDictionary<string, string> Fields);

/// <summary>Parses the comment thread (and the comment-form pseud id) from a work
/// page fetched with <c>?show_comments=true</c>. Comments nest via <c>ol.thread</c>
/// inside each <c>li.comment</c>; depth drives the reply indentation in the UI.</summary>
public static class CommentsParser
{
    public static IReadOnlyList<AO3Comment> Parse(string html)
    {
        var doc = HtmlDom.Parse(html);
        // Select comment <li>s directly rather than scoping to a container first.
        // AO3 renders an (empty) #comments wrapper *before* #comments_placeholder,
        // so picking "the first comments container" landed on the wrong, empty one
        // and found nothing. The `comment_<id>` on each <li> is the reliable marker
        // (and means pagination / other list items are ignored).
        return doc.Select("li.comment[id^='comment_']").Select(ParseComment).OfType<AO3Comment>().ToList();
    }

    private static AO3Comment? ParseComment(IElement li)
    {
        var idAttr = li.Attr("id"); // e.g. "comment_123456"
        if (!idAttr.StartsWith("comment_", StringComparison.Ordinal)) return null;
        var id = idAttr["comment_".Length..];
        if (id.Length == 0) return null;

        var byline = li.SelectFirst("h4.byline, h4.heading.byline");
        var bylineAnchor = byline?.SelectFirst("a");
        var username = SearchResultsParser.AuthorLogin(bylineAnchor.Attr("href"));
        string name;
        if (bylineAnchor?.Text() is { Length: > 0 } anchorText) name = anchorText;
        else if (byline?.Text() is { Length: > 0 } bylineText) name = bylineText;
        else name = "Anonymous";

        var dateText = li.SelectFirst("span.posted.datetime, p.datetime")?.Text() ?? "";
        // The first match is this comment's own body — it precedes any nested
        // replies' blockquotes in document order.
        var bodyHtml = li.SelectFirst("blockquote.userstuff").InnerHtml();

        // Reply depth from ancestor comment threads. AO3 wraps the whole list in
        // one <ol class="thread"> and nests each reply in a further
        // <ol class="thread"> (inside an *unclassed* wrapper <li>) — so a reply's
        // own <li.comment> is NOT a descendant of its parent's. Count ancestor
        // threads and drop the outermost (top-level) one.
        var threadCount = 0;
        for (var p = li.ParentElement; p is not null; p = p.ParentElement)
            if (p.LocalName == "ol" && p.ClassList.Contains("thread")) threadCount++;
        var depth = Math.Max(0, threadCount - 1);

        return new AO3Comment(id, name, username, dateText, bodyHtml, depth);
    }

    /// <summary>The user's default pseud id from the comment form's <c>&lt;select&gt;</c>, so a
    /// posted comment is attributed to the right pseud. Null when no selector is
    /// present (logged out, or AO3 will use the default pseud).</summary>
    public static string? DefaultPseudId(string html) => DefaultPseudId(HtmlDom.Parse(html));

    private static string? DefaultPseudId(IDocument doc)
    {
        if (doc.SelectFirst("select[name='comment[pseud_id]']") is not { } select) return null;
        if (select.SelectFirst("option[selected]")?.Attr("value") is { Length: > 0 } selected) return selected;
        if (select.SelectFirst("option")?.Attr("value") is { Length: > 0 } first) return first;
        return null;
    }

    /// <summary>The page's top-level new-comment form, so a post can replay AO3's own
    /// request rather than hardcoding it: AO3 encodes the target chapter in the
    /// form's <c>action</c> (<c>/works/&lt;id&gt;/chapters/&lt;cid&gt;/comments</c>), so capturing
    /// the action plus the form's hidden inputs (CSRF token, any <c>commentable</c>
    /// fields) and the default pseud is enough to post to the right chapter. Null
    /// when no composer is present (e.g. logged out). <paramref name="baseUri"/> resolves a
    /// relative action.</summary>
    public static CommentForm? NewCommentForm(string html, Uri baseUri)
    {
        var doc = HtmlDom.Parse(html);
        var composers = doc.Select("form[action*='/comments']").Where(HasCommentTextarea).ToList();
        // Prefer the page-level composer over inline reply boxes nested in comments.
        var form = composers.FirstOrDefault(f => !IsInsideComment(f)) ?? composers.FirstOrDefault();
        if (form is null) return null;

        var actionStr = form.Attr("action");
        if (actionStr.Length == 0 || !Uri.TryCreate(baseUri, actionStr, out var action)) return null;

        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var input in form.Select("input[type='hidden']"))
        {
            var name = input.Attr("name");
            if (name.Length == 0) continue;
            fields[name] = input.Attr("value");
        }
        if (DefaultPseudId(doc) is { } pseud) fields["comment[pseud_id]"] = pseud;
        return new CommentForm(action, fields);
    }

    private static bool HasCommentTextarea(IElement form) =>
        form.Select("textarea").Any(a => a.Attr("name").Contains("comment_content", StringComparison.Ordinal));

    private static bool IsInsideComment(IElement el)
    {
        for (var n = el.ParentElement; n is not null; n = n.ParentElement)
            if (n.LocalName == "li" && n.ClassList.Contains("comment")) return true;
        return false;
    }
}
