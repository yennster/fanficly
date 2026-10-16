using System.Collections.ObjectModel;
using System.Text.RegularExpressions;
using AngleSharp.Dom;
using AngleSharp.Html.Parser;

namespace Fanficly.Core;

/// <summary>AO3 story/summary HTML → <see cref="ReaderRichText"/> paragraphs the
/// reader renders and tracks one by one. Port of the Swift <c>HTMLToAttributed</c>.</summary>
public static partial class HTMLToAttributed
{
    /// <summary>U+FFFC OBJECT REPLACEMENT CHARACTER — the placeholder text of an image
    /// slot. Story text can't produce it: it never survives HTML parsing as
    /// meaningful prose, and we only emit it ourselves.</summary>
    internal const string ImagePlaceholder = "\uFFFC";

    /// <summary>What an <c>&lt;hr&gt;</c> renders as.</summary>
    public const string SceneBreakText = "· · ·";

    /// <summary>What every <c>&lt;li&gt;</c> paragraph starts with.</summary>
    public const string ListBullet = "•  ";

    private static readonly LruCache<ReaderRichText> ConvertCache = new(256);
    private static readonly LruCache<IReadOnlyList<ReaderRichText>> ParagraphsCache = new(128);

    /// <summary>The whole body as one rich text (paragraphs joined by blank
    /// lines). Used by <see cref="HTMLText"/> (summaries, notes, comments) —
    /// hyperlinks are enabled here, but NOT in the reader's chapter-body path
    /// (<see cref="ConvertParagraphs"/> default): the reader has tap-to-turn /
    /// tap-to-toggle gestures that tappable links inside the story text would
    /// fight with. Cached; caching is transparent.</summary>
    public static ReaderRichText Convert(string html)
    {
        if (ConvertCache.TryGet(html, out var cached)) return cached;

        var paragraphs = ConvertParagraphs(html, includeLinks: true);
        var parts = new List<ReaderRichText>();
        for (var i = 0; i < paragraphs.Count; i++)
        {
            if (i > 0) parts.Add(new ReaderRichText("\n\n"));
            parts.Add(paragraphs[i]);
        }
        var result = ReaderRichText.Concat(parts);
        ConvertCache.Set(html, result);
        return result;
    }

    /// <summary>The body split into individual paragraphs, so the reader can render
    /// and track each one (for precise reading-position restore).
    /// With <paramref name="includeImages"/>, each <c>&lt;img&gt;</c> becomes its own
    /// paragraph slot — a one-character placeholder carrying the image URL (see
    /// <see cref="ImageAttachmentUrl"/>) that the reader renders as an image view.
    /// Off (the default) drops images entirely, the historical behavior.</summary>
    public static IReadOnlyList<ReaderRichText> ConvertParagraphs(string html, bool includeImages = false,
                                                                  bool includeLinks = false)
    {
        // The modes produce different paragraph arrays, so they must not
        // share cache entries.
        var cacheKey = (includeImages ? "img|" : "txt|") + (includeLinks ? "lnk|" : "") + html;
        if (ParagraphsCache.TryGet(cacheKey, out var cached)) return cached;

        IReadOnlyList<ReaderRichText> result;
        INodeList nodes;
        try
        {
            var parser = new HtmlParser();
            var document = parser.ParseDocument("");
            nodes = parser.ParseFragment(html, document.Body!);
        }
        catch (Exception e) when (e is not OutOfMemoryException)
        {
            var stripped = TagRegex().Replace(html, "");
            result = stripped.Length == 0 ? [] : new ReadOnlyCollection<ReaderRichText>([new ReaderRichText(stripped)]);
            ParagraphsCache.Set(cacheKey, result);
            return result;
        }

        var ctx = new RenderContext(includeImages, includeLinks);
        foreach (var child in nodes) RenderNode(child, ctx, default);
        result = new ReadOnlyCollection<ReaderRichText>(ctx.Finish());
        ParagraphsCache.Set(cacheKey, result);
        return result;
    }

    /// <summary>The image URL when <paramref name="paragraph"/> is an image slot
    /// emitted by <see cref="ConvertParagraphs"/> with <c>includeImages</c>, else
    /// null. An image slot is a single object-replacement character whose run
    /// carries the image URL.</summary>
    public static Uri? ImageAttachmentUrl(ReaderRichText paragraph)
    {
        // O(1) reject for prose: no real paragraph starts with U+FFFC.
        var text = paragraph.Text;
        if (text.Length == 0 || text[0] != '\uFFFC' || text != ImagePlaceholder) return null;
        return paragraph.Runs.Count > 0 ? paragraph.Runs[0].ImageUrl : null;
    }

    /// <summary>Resolves an <c>&lt;img src&gt;</c> to a fetchable URL: protocol-relative
    /// sources get https, <c>http</c> upgrades to <c>https</c>, and anything else
    /// that isn't absolute http(s) is rejected — <c>data:</c> URIs, and also
    /// root-relative paths: those would resolve to archiveofourown.org, and image
    /// loads bypass the AO3 throttle and identifying User-Agent while carrying the
    /// session cookie, so we never point them at AO3 itself. (Authors host work
    /// images externally.)</summary>
    public static Uri? ResolvedImageUrl(string src)
    {
        var trimmed = src.Trim();
        if (trimmed.Length == 0) return null;
        var absolute = trimmed;
        if (trimmed.StartsWith("//", StringComparison.Ordinal))
            absolute = "https:" + trimmed;
        else if (trimmed.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
            absolute = "https://" + trimmed["http://".Length..];
        if (!IsHttpsWithHost(absolute, out var url)) return null;
        // AO3 and its subdomains (www.) would get the session cookie.
        var host = url.Host;
        return host.Equals("archiveofourown.org", StringComparison.OrdinalIgnoreCase)
               || host.EndsWith(".archiveofourown.org", StringComparison.OrdinalIgnoreCase) ? null : url;
    }

    /// <summary>Resolves an <c>&lt;a href&gt;</c> to an openable URL: protocol-relative
    /// hrefs get https, <c>http</c> upgrades to <c>https</c>, and root-relative paths
    /// resolve against archiveofourown.org (links to other works/users/tags are
    /// common in notes and comments). Anything that doesn't yield an absolute
    /// https URL — <c>javascript:</c>, <c>data:</c>, <c>mailto:</c>, fragments,
    /// scheme-less relatives — is rejected: the text still renders, just not as a link.</summary>
    public static Uri? ResolvedLinkUrl(string href)
    {
        var trimmed = href.Trim();
        if (trimmed.Length == 0) return null;
        var absolute = trimmed;
        if (trimmed.StartsWith("//", StringComparison.Ordinal))
            absolute = "https:" + trimmed;
        else if (trimmed.StartsWith('/'))
            absolute = "https://archiveofourown.org" + trimmed;
        else if (trimmed.StartsWith("http://", StringComparison.OrdinalIgnoreCase))
            absolute = "https://" + trimmed["http://".Length..];
        return IsHttpsWithHost(absolute, out var url) ? url : null;
    }

    private static bool IsHttpsWithHost(string absolute, out Uri url)
    {
        if (Uri.TryCreate(absolute, UriKind.Absolute, out var parsed)
            && parsed.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase)
            && !string.IsNullOrEmpty(parsed.Host))
        {
            url = parsed;
            return true;
        }
        url = null!;
        return false;
    }

    /// <summary>One speech string per <i>rendered</i> paragraph — same count and order
    /// as <see cref="ConvertParagraphs"/> (what the reader displays) — so the TTS
    /// narrator and the karaoke highlight share a paragraph index. Scene-break
    /// separators become "" (they occupy an index but aren't read aloud); soft
    /// line breaks are flattened and list bullets dropped so the synthesizer reads
    /// clean prose. The narrator skips the empty entries. Pass the same
    /// <paramref name="includeImages"/> the reader renders with, so indices stay
    /// aligned; image slots become "" (unspoken) like scene breaks.</summary>
    public static IReadOnlyList<string> SpeechParagraphs(string html, bool includeImages = false) =>
        ConvertParagraphs(html, includeImages).Select(para =>
        {
            if (ImageAttachmentUrl(para) is not null) return "";
            var s = para.Text.Replace("\n", " ").Replace("•", "").Trim();
            return s == SceneBreakText ? "" : s;
        }).ToArray();

    /// <summary>Splits rich text into sentence slices (Unicode sentence boundaries,
    /// like Foundation's <c>.bySentences</c>), keeping their formatting. Each slice
    /// keeps its trailing spaces; whitespace-only slices are dropped. Text with no
    /// sentence comes back whole.</summary>
    public static IReadOnlyList<ReaderRichText> SplitIntoSentences(ReaderRichText attributed)
    {
        var result = new List<ReaderRichText>();
        foreach (var (start, end) in SentenceSegmenter.Sentences(attributed.Text))
        {
            if (string.IsNullOrWhiteSpace(attributed.Text[start..end])) continue;
            result.Add(attributed.Slice(start, end));
        }
        if (result.Count == 0 && !attributed.IsEmpty) result.Add(attributed);
        return result;
    }

    // MARK: - Rendering

    private readonly record struct InlineStyle(ReaderInlineStyle Style, Uri? Link)
    {
        public InlineStyle With(ReaderInlineStyle flag) => this with { Style = Style | flag };
    }

    /// <summary>Accumulates the body into discrete paragraphs, collapsing whitespace
    /// so AO3's empty <c>&lt;p&gt;</c> scene breaks and source indentation don't
    /// create empty paragraphs or big gaps.</summary>
    private sealed class RenderContext(bool includeImages, bool includeLinks)
    {
        public bool IncludeImages { get; } = includeImages;
        public bool IncludeLinks { get; } = includeLinks;
        private readonly List<ReaderRichText> _paragraphs = [];
        private readonly ReaderRichText.Builder _current = new();
        private bool _pendingParagraph;

        /// <summary>Emit an image as its own paragraph slot (an inline <c>&lt;img&gt;</c>
        /// splits the surrounding text into separate paragraphs around it).</summary>
        public void AppendImage(Uri url)
        {
            ParagraphBreak();
            Append(new ReaderRun(ImagePlaceholder, ImageUrl: url));
            ParagraphBreak();
        }

        public void Append(ReaderRun fragment)
        {
            if (fragment.Text.Length == 0) return;
            FlushParagraph();
            _current.Append(fragment);
        }

        /// <summary>A <c>&lt;br&gt;</c> — a single soft line break within the current paragraph.</summary>
        public void SoftBreak()
        {
            if (_current.IsEmpty) return;
            if (TrailingNewlines() < 2) _current.Append(new ReaderRun("\n"));
        }

        /// <summary>End of a block element — finish the current paragraph (if any).
        /// Coalesces so several empty blocks in a row don't add empties.</summary>
        public void ParagraphBreak()
        {
            if (!_current.IsEmpty) _pendingParagraph = true;
        }

        private void FlushParagraph()
        {
            if (!_pendingParagraph) return;
            var trimmed = _current.ToTrimmed();
            if (!trimmed.IsEmpty) _paragraphs.Add(trimmed);
            _current.Clear();
            _pendingParagraph = false;
        }

        public ReaderRichText[] Finish()
        {
            var trimmed = _current.ToTrimmed();
            if (!trimmed.IsEmpty) _paragraphs.Add(trimmed);
            _current.Clear();
            return _paragraphs.ToArray();
        }

        private int TrailingNewlines()
        {
            var count = 0;
            for (var i = _current.Length - 1; i >= 0 && _current[i] == '\n'; i--)
            {
                count++;
                if (count >= 2) break;
            }
            return count;
        }
    }

    private static void RenderNode(INode node, RenderContext ctx, InlineStyle style)
    {
        if (node is IText textNode)
        {
            var raw = textNode.Data.Replace('\u00A0', ' ');
            var collapsed = WhitespaceRegex().Replace(raw, " ");
            // Whitespace-only (indentation / empty scene-break paragraph).
            if (collapsed.Trim(' ', '\t').Length == 0) return;
            ctx.Append(Styled(collapsed, style));
            return;
        }
        if (node is not IElement el) return;
        var tag = el.LocalName.ToLowerInvariant();
        var next = style;

        switch (tag)
        {
            case "br":
                ctx.SoftBreak();
                return;
            case "img":
                if (ctx.IncludeImages && ResolvedImageUrl(el.GetAttribute("src") ?? "") is { } imageUrl)
                    ctx.AppendImage(imageUrl);
                return;
            case "hr":
                ctx.ParagraphBreak();
                ctx.Append(new ReaderRun(SceneBreakText));
                ctx.ParagraphBreak();
                return;
            case "strong" or "b":
                next = next.With(ReaderInlineStyle.Bold);
                break;
            case "em" or "i" or "cite":
                next = next.With(ReaderInlineStyle.Italic);
                break;
            case "u":
                next = next.With(ReaderInlineStyle.Underline);
                break;
            case "s" or "strike" or "del":
                next = next.With(ReaderInlineStyle.Strikethrough);
                break;
            case "a":
                if (ctx.IncludeLinks && ResolvedLinkUrl(el.GetAttribute("href") ?? "") is { } linkUrl)
                    next = next with { Link = linkUrl };
                break;
            case "p" or "div" or "blockquote" or "h1" or "h2" or "h3" or "h4" or "h5" or "h6":
                ctx.ParagraphBreak();
                foreach (var child in el.ChildNodes) RenderNode(child, ctx, next);
                ctx.ParagraphBreak();
                return;
            case "li":
                ctx.ParagraphBreak();
                ctx.Append(new ReaderRun(ListBullet));
                foreach (var child in el.ChildNodes) RenderNode(child, ctx, next);
                ctx.ParagraphBreak();
                return;
        }

        foreach (var child in el.ChildNodes) RenderNode(child, ctx, next);
    }

    private static ReaderRun Styled(string text, InlineStyle style)
    {
        var flags = style.Style;
        // Underline links as well: HTMLText callers often override the text
        // color (themed reader summaries), which hides the link tint.
        if (style.Link is not null) flags |= ReaderInlineStyle.Underline;
        return new ReaderRun(text, flags, style.Link);
    }

    [GeneratedRegex("<[^>]+>")]
    private static partial Regex TagRegex();

    [GeneratedRegex(@"\s+")]
    private static partial Regex WhitespaceRegex();

    /// <summary>A small thread-safe least-recently-used cache (Swift used
    /// <c>NSCache</c>, which evicts under memory pressure).</summary>
    private sealed class LruCache<T>(int capacity)
    {
        private readonly Dictionary<string, LinkedListNode<(string Key, T Value)>> _map = new(StringComparer.Ordinal);
        private readonly LinkedList<(string Key, T Value)> _order = new();
        private readonly Lock _gate = new();

        public bool TryGet(string key, out T value)
        {
            lock (_gate)
            {
                if (_map.TryGetValue(key, out var node))
                {
                    _order.Remove(node);
                    _order.AddFirst(node);
                    value = node.Value.Value;
                    return true;
                }
            }
            value = default!;
            return false;
        }

        public void Set(string key, T value)
        {
            lock (_gate)
            {
                if (_map.TryGetValue(key, out var existing)) _order.Remove(existing);
                var node = _order.AddFirst((key, value));
                _map[key] = node;
                while (_map.Count > capacity)
                {
                    var last = _order.Last!;
                    _order.RemoveLast();
                    _map.Remove(last.Value.Key);
                }
            }
        }
    }
}
