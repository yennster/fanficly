import Foundation
import SwiftSoup
import SwiftUI

enum HTMLToAttributed {
    nonisolated(unsafe) private static let cache = NSCache<NSString, AnyObject>()
    
    private final class AttributedStringWrapper: NSObject {
        let value: AttributedString
        init(_ value: AttributedString) {
            self.value = value
        }
    }

    private final class ParagraphsWrapper: NSObject, @unchecked Sendable {
        let value: [AttributedString]
        init(_ value: [AttributedString]) {
            self.value = value
        }
    }

    nonisolated(unsafe) private static let paragraphsCache = NSCache<NSString, ParagraphsWrapper>()

    /// The whole body as one AttributedString (paragraphs joined by blank lines).
    static func convert(_ html: String) -> AttributedString {
        let nsHtml = html as NSString
        if let cached = cache.object(forKey: nsHtml) as? AttributedStringWrapper {
            return cached.value
        }
        
        let paragraphs = convertParagraphs(html)
        var out = AttributedString()
        for (i, para) in paragraphs.enumerated() {
            if i > 0 { out.append(AttributedString("\n\n")) }
            out.append(para)
        }
        
        cache.setObject(AttributedStringWrapper(out), forKey: nsHtml)
        return out
    }

    /// The body split into individual paragraphs, so the reader can render
    /// and track each one (for precise reading-position restore).
    /// With `includeImages`, each `<img>` becomes its own paragraph slot — a
    /// one-character placeholder carrying the image URL (see
    /// `imageAttachmentURL(in:)`) that the reader renders as an image view.
    /// Off (the default) drops images entirely, the historical behavior.
    static func convertParagraphs(_ html: String, includeImages: Bool = false) -> [AttributedString] {
        // The two modes produce different paragraph arrays, so they must not
        // share cache entries.
        let cacheKey = (includeImages ? "img|" : "txt|") + html as NSString
        if let cached = paragraphsCache.object(forKey: cacheKey) {
            return cached.value
        }

        guard let doc = try? SwiftSoup.parseBodyFragment(html),
              let body = doc.body() else {
            let stripped = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            let result = stripped.isEmpty ? [] : [AttributedString(stripped)]
            paragraphsCache.setObject(ParagraphsWrapper(result), forKey: cacheKey)
            return result
        }
        var ctx = RenderContext(includeImages: includeImages)
        let children = body.getChildNodes()
        for child in children {
            renderNode(child, into: &ctx, style: InlineStyle())
        }
        let result = ctx.finish()
        paragraphsCache.setObject(ParagraphsWrapper(result), forKey: cacheKey)
        return result
    }

    /// The image URL when `paragraph` is an image slot emitted by
    /// `convertParagraphs(_:includeImages:)`, else nil. An image slot is a
    /// single object-replacement character whose run carries `imageURL`.
    static func imageAttachmentURL(in paragraph: AttributedString) -> URL? {
        // O(1) reject for prose: no real paragraph starts with U+FFFC. Only
        // then pay for the (single-character) full comparison.
        guard paragraph.characters.first == "\u{FFFC}",
              String(paragraph.characters) == imagePlaceholder else { return nil }
        return paragraph.runs.first?.imageURL
    }

    /// U+FFFC OBJECT REPLACEMENT CHARACTER — the placeholder text of an image
    /// slot. Story text can't produce it: it never survives HTML parsing as
    /// meaningful prose, and we only emit it ourselves.
    private static let imagePlaceholder = "\u{FFFC}"

    /// Resolves an `<img src>` to a fetchable URL: protocol-relative sources
    /// get https, `http` upgrades to `https` (ATS blocks plain http anyway),
    /// and anything else that isn't absolute http(s) is rejected — `data:`
    /// URIs, and also root-relative paths: those would resolve to
    /// archiveofourown.org, and image loads bypass the AO3 throttle and
    /// identifying User-Agent while carrying the session cookie, so we never
    /// point them at AO3 itself. (Authors host work images externally.)
    static func resolvedImageURL(fromSrc src: String) -> URL? {
        let trimmed = src.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var absolute = trimmed
        if trimmed.hasPrefix("//") {
            absolute = "https:" + trimmed
        } else if trimmed.lowercased().hasPrefix("http://") {
            absolute = "https://" + trimmed.dropFirst("http://".count)
        }
        guard let url = URL(string: absolute),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              host.lowercased() != "archiveofourown.org" else { return nil }
        return url
    }

    /// One speech string per *rendered* paragraph — same count and order as
    /// `convertParagraphs` (what `ChapterContentView` displays) — so the TTS
    /// narrator and the karaoke highlight share a paragraph index. Scene-break
    /// separators become "" (they occupy an index but aren't read aloud); soft
    /// line breaks are flattened and list bullets dropped so the synthesizer
    /// reads clean prose. The controller skips the empty entries when speaking.
    /// Pass the same `includeImages` the reader renders with, so indices stay
    /// aligned; image slots become "" (unspoken) like scene breaks.
    static func speechParagraphs(_ html: String, includeImages: Bool = false) -> [String] {
        convertParagraphs(html, includeImages: includeImages).map { para in
            if imageAttachmentURL(in: para) != nil { return "" }
            let s = String(para.characters)
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "•", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return s == "· · ·" ? "" : s
        }
    }

    private struct InlineStyle {
        var bold = false
        var italic = false
        var underline = false
        var strike = false
    }

    /// Accumulates the body into discrete paragraphs, collapsing whitespace
    /// so AO3's empty `<p>` scene breaks and source indentation don't create
    /// empty paragraphs or big gaps.
    private struct RenderContext {
        let includeImages: Bool
        private var paragraphs: [AttributedString] = []
        private var current = AttributedString()
        private var pendingParagraph = false

        init(includeImages: Bool = false) {
            self.includeImages = includeImages
        }

        /// Emit an image as its own paragraph slot (an inline `<img>` splits
        /// the surrounding text into separate paragraphs around it).
        mutating func appendImage(url: URL) {
            paragraphBreak()
            var placeholder = AttributedString(HTMLToAttributed.imagePlaceholder)
            placeholder.imageURL = url
            append(placeholder)
            paragraphBreak()
        }

        mutating func append(_ fragment: AttributedString) {
            guard !fragment.characters.isEmpty else { return }
            flushParagraph()
            current.append(fragment)
        }

        /// A <br> — a single soft line break within the current paragraph.
        mutating func softBreak() {
            guard !current.characters.isEmpty else { return }
            if trailingNewlines(current) < 2 {
                current.append(AttributedString("\n"))
            }
        }

        /// End of a block element — finish the current paragraph (if any).
        /// Coalesces so several empty blocks in a row don't add empties.
        mutating func paragraphBreak() {
            if !current.characters.isEmpty { pendingParagraph = true }
        }

        private mutating func flushParagraph() {
            guard pendingParagraph else { return }
            let trimmed = trimmedParagraph(current)
            if !trimmed.characters.isEmpty { paragraphs.append(trimmed) }
            current = AttributedString()
            pendingParagraph = false
        }

        mutating func finish() -> [AttributedString] {
            let trimmed = trimmedParagraph(current)
            if !trimmed.characters.isEmpty { paragraphs.append(trimmed) }
            current = AttributedString()
            return paragraphs
        }

        private func trailingNewlines(_ s: AttributedString) -> Int {
            var count = 0
            for ch in s.characters.reversed() {
                if ch == "\n" { count += 1; if count >= 2 { break } } else { break }
            }
            return count
        }

        private func trimmedParagraph(_ s: AttributedString) -> AttributedString {
            var result = s
            while let first = result.characters.first, first == "\n" || first == " " {
                result.removeSubrange(result.startIndex..<result.characters.index(after: result.startIndex))
            }
            while let last = result.characters.last, last == "\n" || last == " " {
                result.removeSubrange(result.characters.index(before: result.endIndex)..<result.endIndex)
            }
            return result
        }
    }

    private static func renderNode(_ node: Node, into ctx: inout RenderContext, style: InlineStyle) {
        if let textNode = node as? TextNode {
            let raw = textNode.getWholeText().replacingOccurrences(of: "\u{00A0}", with: " ")
            let collapsed = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if collapsed.trimmingCharacters(in: .whitespaces).isEmpty {
                return  // whitespace-only (indentation / empty scene-break paragraph)
            }
            ctx.append(styled(collapsed, style: style))
            return
        }
        guard let el = node as? Element else { return }
        let tag = el.tagName().lowercased()
        var next = style

        switch tag {
        case "br":
            ctx.softBreak()
            return
        case "img":
            if ctx.includeImages,
               let src = try? el.attr("src"),
               let url = resolvedImageURL(fromSrc: src) {
                ctx.appendImage(url: url)
            }
            return
        case "hr":
            ctx.paragraphBreak()
            ctx.append(AttributedString("· · ·"))
            ctx.paragraphBreak()
            return
        case "strong", "b":            next.bold = true
        case "em", "i", "cite":        next.italic = true
        case "u":                      next.underline = true
        case "s", "strike", "del":     next.strike = true
        case "p", "div", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6":
            ctx.paragraphBreak()
            for child in el.getChildNodes() {
                renderNode(child, into: &ctx, style: next)
            }
            ctx.paragraphBreak()
            return
        case "li":
            ctx.paragraphBreak()
            ctx.append(AttributedString("•  "))
            for child in el.getChildNodes() {
                renderNode(child, into: &ctx, style: next)
            }
            ctx.paragraphBreak()
            return
        default:
            break
        }

        for child in el.getChildNodes() {
            renderNode(child, into: &ctx, style: next)
        }
    }

    private static func styled(_ string: String, style: InlineStyle) -> AttributedString {
        var fragment = AttributedString(string)
        if style.bold && style.italic {
            fragment.inlinePresentationIntent = [.stronglyEmphasized, .emphasized]
        } else if style.bold {
            fragment.inlinePresentationIntent = .stronglyEmphasized
        } else if style.italic {
            fragment.inlinePresentationIntent = .emphasized
        }
        if style.underline { fragment.underlineStyle = .single }
        if style.strike { fragment.strikethroughStyle = .single }
        return fragment
    }

    /// Splits an AttributedString into individual sentence slices using locale-aware options.
    static func splitIntoSentences(_ attributed: AttributedString) -> [AttributedString] {
        let string = String(attributed.characters)
        var result: [AttributedString] = []
        
        string.enumerateSubstrings(in: string.startIndex..<string.endIndex, options: .bySentences) { substring, range, _, _ in
            guard let substring = substring, !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if let attrRange = Range(range, in: attributed) {
                result.append(AttributedString(attributed[attrRange]))
            }
        }
        
        if result.isEmpty && !attributed.characters.isEmpty {
            result.append(attributed)
        }
        return result
    }
}
