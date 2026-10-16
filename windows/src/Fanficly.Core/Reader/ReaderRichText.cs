using System.Collections.ObjectModel;
using System.Text;

namespace Fanficly.Core;

/// <summary>The inline formatting a run of story text carries — everything
/// <see cref="HTMLToAttributed"/> sets (Swift: <c>inlinePresentationIntent</c>
/// strongly-emphasized / emphasized, <c>underlineStyle</c>, <c>strikethroughStyle</c>).</summary>
[Flags]
public enum ReaderInlineStyle
{
    None = 0,
    /// <summary><c>&lt;strong&gt;</c>, <c>&lt;b&gt;</c>.</summary>
    Bold = 1,
    /// <summary><c>&lt;em&gt;</c>, <c>&lt;i&gt;</c>, <c>&lt;cite&gt;</c>.</summary>
    Italic = 2,
    /// <summary><c>&lt;u&gt;</c>, and every link run (so a themed foreground can't hide it).</summary>
    Underline = 4,
    /// <summary><c>&lt;s&gt;</c>, <c>&lt;strike&gt;</c>, <c>&lt;del&gt;</c>.</summary>
    Strikethrough = 8,
}

/// <summary>One run of text with uniform attributes — the platform-neutral
/// stand-in for an <c>AttributedString</c> run. The WinUI reader renders each
/// run as one <c>Run</c>/<c>Hyperlink</c> inline.</summary>
/// <param name="Text">The run's characters.</param>
/// <param name="Style">Bold / italic / underline / strikethrough.</param>
/// <param name="Link">An openable https link (only from <c>includeLinks</c> conversions).</param>
/// <param name="ImageUrl">Set only on an image slot's placeholder run (see
/// <see cref="HTMLToAttributed.ImageAttachmentUrl"/>).</param>
public sealed record ReaderRun(string Text, ReaderInlineStyle Style = ReaderInlineStyle.None,
                               Uri? Link = null, Uri? ImageUrl = null)
{
    public bool IsBold => Style.HasFlag(ReaderInlineStyle.Bold);
    public bool IsItalic => Style.HasFlag(ReaderInlineStyle.Italic);
    public bool IsUnderlined => Style.HasFlag(ReaderInlineStyle.Underline);
    public bool IsStrikethrough => Style.HasFlag(ReaderInlineStyle.Strikethrough);

    internal bool HasSameAttributes(ReaderRun other) =>
        Style == other.Style && Equals(Link, other.Link) && Equals(ImageUrl, other.ImageUrl);
}

/// <summary>What a rendered paragraph is, derived from its text the same way
/// the Swift reader tells them apart (it has no separate block types).</summary>
public enum ReaderParagraphKind
{
    /// <summary>Ordinary prose (also headings and blockquotes, which the Swift
    /// renders as plain paragraphs).</summary>
    Text,
    /// <summary>An <c>&lt;hr&gt;</c>: the text "· · ·" (drawn as an ordinary paragraph), never spoken.</summary>
    SceneBreak,
    /// <summary>An <c>&lt;li&gt;</c>: its text starts with "•  ".</summary>
    ListItem,
    /// <summary>An image slot: render <see cref="ReaderRichText.ImageUrl"/> at
    /// <see cref="ReaderInlineImage.SlotHeight"/>, never as text.</summary>
    Image,
}

/// <summary>Immutable rich text: a list of <see cref="ReaderRun"/>s — the C#
/// stand-in for Swift's <c>AttributedString</c>. Adjacent runs with identical
/// attributes are coalesced and empty runs dropped, as AttributedString does,
/// so two texts with the same characters and formatting compare equal.
/// Offsets are UTF-16 code units.</summary>
public sealed class ReaderRichText : IEquatable<ReaderRichText>
{
    public static readonly ReaderRichText Empty = new([]);

    private readonly ReaderRun[] _runs;

    public ReaderRichText(string text, ReaderInlineStyle style = ReaderInlineStyle.None)
        : this([new ReaderRun(text, style)]) { }

    public ReaderRichText(IEnumerable<ReaderRun> runs)
    {
        var list = new List<ReaderRun>();
        foreach (var run in runs)
        {
            if (run.Text.Length == 0) continue;
            if (list.Count > 0 && list[^1].HasSameAttributes(run))
                list[^1] = list[^1] with { Text = list[^1].Text + run.Text };
            else
                list.Add(run);
        }
        _runs = list.ToArray();
        Runs = new ReadOnlyCollection<ReaderRun>(_runs);
        Text = string.Concat(_runs.Select(r => r.Text));
    }

    /// <summary>The coalesced runs, in order.</summary>
    public IReadOnlyList<ReaderRun> Runs { get; }

    /// <summary>All the characters (Swift: <c>String(attributed.characters)</c>).</summary>
    public string Text { get; }

    public int Length => Text.Length;
    public bool IsEmpty => Text.Length == 0;

    /// <summary>The image URL when this is an image slot, else null.</summary>
    public Uri? ImageUrl => HTMLToAttributed.ImageAttachmentUrl(this);

    public ReaderParagraphKind Kind =>
        ImageUrl is not null ? ReaderParagraphKind.Image
        : Text == HTMLToAttributed.SceneBreakText ? ReaderParagraphKind.SceneBreak
        : Text.StartsWith(HTMLToAttributed.ListBullet, StringComparison.Ordinal) ? ReaderParagraphKind.ListItem
        : ReaderParagraphKind.Text;

    /// <summary>Each run with the offset of its first character.</summary>
    public IEnumerable<(int Start, ReaderRun Run)> RunsWithOffsets()
    {
        var offset = 0;
        foreach (var run in _runs)
        {
            yield return (offset, run);
            offset += run.Text.Length;
        }
    }

    /// <summary>The characters in <c>[start, end)</c>, keeping their formatting.</summary>
    public ReaderRichText Slice(int start, int end)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(start);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(end, Length);
        ArgumentOutOfRangeException.ThrowIfGreaterThan(start, end);
        if (start == 0 && end == Length) return this;
        var parts = new List<ReaderRun>();
        foreach (var (runStart, run) in RunsWithOffsets())
        {
            var runEnd = runStart + run.Text.Length;
            var from = Math.Max(start, runStart);
            var to = Math.Min(end, runEnd);
            if (from < to) parts.Add(run with { Text = run.Text.Substring(from - runStart, to - from) });
        }
        return new ReaderRichText(parts);
    }

    /// <summary>The characters from <paramref name="start"/> to the end.</summary>
    public ReaderRichText Slice(int start) => Slice(start, Length);

    public ReaderRichText Append(ReaderRichText other) =>
        other.IsEmpty ? this : IsEmpty ? other : new ReaderRichText(_runs.Concat(other._runs));

    public static ReaderRichText Concat(IEnumerable<ReaderRichText> parts) =>
        new(parts.SelectMany(p => p._runs));

    public bool Equals(ReaderRichText? other) =>
        other is not null && (ReferenceEquals(this, other) ||
                              (Text == other.Text && _runs.AsSpan().SequenceEqual(other._runs)));

    public override bool Equals(object? obj) => obj is ReaderRichText other && Equals(other);
    public override int GetHashCode() => Text.GetHashCode(StringComparison.Ordinal);
    public static bool operator ==(ReaderRichText? a, ReaderRichText? b) => a is null ? b is null : a.Equals(b);
    public static bool operator !=(ReaderRichText? a, ReaderRichText? b) => !(a == b);
    public override string ToString() => Text;

    /// <summary>A mutable builder used by the converter.</summary>
    internal sealed class Builder
    {
        private readonly List<ReaderRun> _runs = [];
        private readonly StringBuilder _text = new();

        public int Length => _text.Length;
        public bool IsEmpty => _text.Length == 0;
        public char this[int index] => _text[index];

        public void Append(ReaderRichText fragment)
        {
            foreach (var run in fragment.Runs) Append(run);
        }

        public void Append(ReaderRun run)
        {
            if (run.Text.Length == 0) return;
            _runs.Add(run);
            _text.Append(run.Text);
        }

        public void Clear()
        {
            _runs.Clear();
            _text.Clear();
        }

        /// <summary>The built text with leading and trailing "\n"/" " removed.</summary>
        public ReaderRichText ToTrimmed()
        {
            var start = 0;
            while (start < _text.Length && _text[start] is '\n' or ' ') start++;
            var end = _text.Length;
            while (end > start && _text[end - 1] is '\n' or ' ') end--;
            return new ReaderRichText(_runs).Slice(start, end);
        }
    }
}
