import Foundation

/// Chapter titles and openings as the reader shows them, the way Apple Books
/// shows a chapter: its title once, readable. Some stories carry markup that
/// was escaped twice, so "&amp;amp;" in the page reads as "&amp;" on screen,
/// and many open the chapter's text with its title again, which the reader's
/// own chapter heading already shows. Pure, so it's unit-tested.
enum ReaderChapterText {
    /// The chapter as the reader shows it: the title decoded and without
    /// AO3's "Chapter N:" prefix, and an opening paragraph that only repeats
    /// the title (or "Chapter N") taken out of the text.
    ///
    /// The reader takes its chapters through this once, so its paragraph
    /// indices (pagination, narration, saved places) all count without the
    /// repeated line.
    static func cleaned(_ chapter: AO3ChapterPayload) -> AO3ChapterPayload {
        let title = self.title(chapter.title, index: chapter.index)
        let body = removingRepeatedTitle(fromHTML: chapter.bodyHTML, rawTitle: chapter.title, title: title,
                                         index: chapter.index)
        guard title != chapter.title || body != chapter.bodyHTML else { return chapter }
        return AO3ChapterPayload(index: chapter.index, title: title, bodyHTML: body, aoId: chapter.aoId)
    }

    /// A chapter title as the reader shows it: leftover entities decoded
    /// ("The Decree &amp; Draco's Hunt" → "The Decree & Draco's Hunt") and
    /// this chapter's own "Chapter N:" prefix dropped, as the reader's heading
    /// shows the number itself (an author's "Chapter 2: …" reaches the reader
    /// as AO3's "Chapter 2: Chapter 2: …" with one gone, and an EPUB's section
    /// titles keep theirs). Another number is the author's: chapter 2 titled
    /// "Chapter 1" after a prologue keeps it. Just "Chapter N" is no title.
    static func title(_ raw: String, index: Int) -> String {
        var title = decodingLeftoverEntities(raw).trimmingCharacters(in: .whitespaces)
        let prefix = "^Chapter\\s+\(index)(?!\\d)\\s*[:.\\-\u{2013}\u{2014}]?\\s*"
        for _ in 0..<2 {
            guard let range = title.range(of: prefix, options: [.regularExpression, .caseInsensitive]) else { break }
            title = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return title
    }

    // MARK: - Entities

    private static let entityPattern = try? NSRegularExpression(
        pattern: "&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|amp|lt|gt|quot|apos|nbsp);")

    /// Decodes HTML character references left in text whose markup was
    /// escaped twice: "&amp;" reads as "&", "&#39;" as "'". Text without them
    /// comes back as it was.
    static func decodingLeftoverEntities(_ text: String) -> String {
        guard text.contains("&"), let regex = entityPattern else { return text }
        var current = text
        // "&amp;amp;" escaped three times takes a second pass; stop there.
        for _ in 0..<3 {
            let ns = current as NSString
            let matches = regex.matches(in: current, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { break }
            var out = ""
            var last = 0
            for match in matches {
                out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let name = ns.substring(with: match.range(at: 1))
                out += character(forEntity: name) ?? ns.substring(with: match.range)
                last = match.range.location + match.range.length
            }
            out += ns.substring(from: last)
            if out == current { break }
            current = out
        }
        return current
    }

    private static func character(forEntity name: String) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        default:
            let digits = name.dropFirst()
            let value = digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            return value.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
        }
    }

    // MARK: - A repeated title

    /// The first paragraph or heading in the markup, with only wrappers
    /// (`<div>`, `<section>`, …) and blank text before it.
    private static let firstBlockPattern = try? NSRegularExpression(
        pattern: "<(p|h[1-6]|center)\\b[^>]*>(.*?)</\\1\\s*>",
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    private static let tagPattern = try? NSRegularExpression(pattern: "<[^>]*>")

    /// How far into the markup the opening paragraph is looked for: a
    /// title repeated at the top sits in its first few hundred characters.
    private static let searchLimit = 4000

    /// The markup without its opening paragraph when that paragraph only
    /// repeats the chapter's title, "Chapter N", or both ("Chapter 2: The
    /// Decree", "2. The Decree"). Anything else comes back unchanged.
    static func removingRepeatedTitle(fromHTML html: String, rawTitle: String, title: String, index: Int) -> String {
        guard let regex = firstBlockPattern else { return html }
        let ns = html as NSString
        let searchRange = NSRange(location: 0, length: min(ns.length, searchLimit))
        guard let match = regex.firstMatch(in: html, range: searchRange) else { return html }
        // Only wrappers' tags and blank text before it: it opens the chapter.
        let before = plainText(ns.substring(to: match.range.location))
        guard before.isEmpty else { return html }
        let paragraph = plainText(ns.substring(with: match.range(at: 2)))
        // Set out as a heading, or naming the chapter's number: a plain line
        // that equals the title can be the story's first words (chapter "Run"
        // opening on "Run!").
        let looksLikeHeading = !ns.substring(with: match.range(at: 1)).lowercased().hasPrefix("p")
            || isSetOut(ns.substring(with: match.range))
            || comparable(paragraph).hasPrefix(comparable("chapter \(index)"))
            || comparable(paragraph).hasPrefix("\(index)")
        guard looksLikeHeading, repeatsTitle(paragraph, rawTitle: rawTitle, title: title, index: index) else { return html }
        return ns.replacingCharacters(in: match.range, with: "")
    }

    /// Whether `paragraph` says only what the reader's chapter heading says.
    static func repeatsTitle(_ paragraph: String, rawTitle: String, title: String, index: Int) -> Bool {
        let said = comparable(paragraph)
        guard !said.isEmpty else { return false }
        var headings = ["chapter \(index)"]
        for name in [title, decodingLeftoverEntities(rawTitle)] where !comparable(name).isEmpty {
            headings += [name, "chapter \(index) \(name)", "\(index) \(name)"]
        }
        return headings.contains { comparable($0) == said }
    }

    private static let setOutPattern = try? NSRegularExpression(
        pattern: "^<p\\b[^>]*(align\\s*=\\s*[\"']?center|text-align\\s*:\\s*center)[^>]*>|^<p\\b[^>]*>\\s*<(b|strong|em|i|u|big)\\b[^>]*>.*</\\2\\s*>\\s*</p\\s*>$",
        options: [.caseInsensitive, .dotMatchesLineSeparators])

    /// A paragraph centred, or all in bold, italics or underline: set out as a heading.
    private static func isSetOut(_ paragraphHTML: String) -> Bool {
        guard let setOutPattern else { return false }
        return setOutPattern.firstMatch(in: paragraphHTML,
                                        range: NSRange(location: 0, length: (paragraphHTML as NSString).length)) != nil
    }

    /// Text with its tags dropped, entities decoded and whitespace trimmed.
    private static func plainText(_ html: String) -> String {
        var text = html
        if let tagPattern {
            text = tagPattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                                       withTemplate: " ")
        }
        return decodingLeftoverEntities(text)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{00A0}")))
    }

    /// Letters and digits only, lowercased and without accents, so "Chapter
    /// 2: The Decree & Draco’s Hunt" and "CHAPTER 2 – The Decree & Draco's
    /// Hunt" compare equal.
    private static func comparable(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }
}
