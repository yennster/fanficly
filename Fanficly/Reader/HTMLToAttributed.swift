import Foundation
import SwiftSoup
import SwiftUI

enum HTMLToAttributed {
    /// The whole body as one AttributedString (paragraphs joined by blank lines).
    static func convert(_ html: String) -> AttributedString {
        let paragraphs = convertParagraphs(html)
        var out = AttributedString()
        for (i, para) in paragraphs.enumerated() {
            if i > 0 { out.append(AttributedString("\n\n")) }
            out.append(para)
        }
        return out
    }

    /// The body split into individual paragraphs, so the reader can render
    /// and track each one (for precise reading-position restore).
    static func convertParagraphs(_ html: String) -> [AttributedString] {
        guard let doc = try? SwiftSoup.parseBodyFragment(html),
              let body = doc.body() else {
            let stripped = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            return stripped.isEmpty ? [] : [AttributedString(stripped)]
        }
        var ctx = RenderContext()
        let children = body.getChildNodes()
        for child in children {
            renderNode(child, into: &ctx, style: InlineStyle())
        }
        return ctx.finish()
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
        private var paragraphs: [AttributedString] = []
        private var current = AttributedString()
        private var pendingParagraph = false

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
}
