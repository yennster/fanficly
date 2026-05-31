import Foundation
import SwiftSoup
import SwiftUI

enum HTMLToAttributed {
    static func convert(_ html: String) -> AttributedString {
        guard let doc = try? SwiftSoup.parseBodyFragment(html),
              let body = doc.body() else {
            return AttributedString(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
        }
        var ctx = RenderContext()
        let children = (try? body.getChildNodes()) ?? []
        for child in children {
            renderNode(child, into: &ctx, style: InlineStyle())
        }
        return ctx.output
    }

    private struct InlineStyle {
        var bold = false
        var italic = false
        var underline = false
        var strike = false
    }

    /// Accumulates output while collapsing whitespace and ensuring at most
    /// one blank line between blocks — so AO3's empty `<p>` scene breaks
    /// and source-indentation whitespace don't create big vertical gaps.
    private struct RenderContext {
        var output = AttributedString()
        private var pendingParagraph = false

        mutating func append(_ fragment: AttributedString) {
            guard !fragment.characters.isEmpty else { return }
            flushParagraph()
            output.append(fragment)
        }

        /// A <br> — a single soft line break within a paragraph.
        mutating func softBreak() {
            guard !output.characters.isEmpty else { return }
            if trailingNewlines() < 2 {
                output.append(AttributedString("\n"))
            }
        }

        /// End of a block element — request a paragraph break before the
        /// next text, without stacking up if several blocks end in a row.
        mutating func paragraphBreak() {
            if !output.characters.isEmpty { pendingParagraph = true }
        }

        private mutating func flushParagraph() {
            guard pendingParagraph else { return }
            switch trailingNewlines() {
            case 0: output.append(AttributedString("\n\n"))
            case 1: output.append(AttributedString("\n"))
            default: break
            }
            pendingParagraph = false
        }

        private func trailingNewlines() -> Int {
            var count = 0
            for ch in output.characters.reversed() {
                if ch == "\n" { count += 1; if count >= 2 { break } } else { break }
            }
            return count
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
            for child in (try? el.getChildNodes()) ?? [] {
                renderNode(child, into: &ctx, style: next)
            }
            ctx.paragraphBreak()
            return
        case "li":
            ctx.paragraphBreak()
            ctx.append(AttributedString("•  "))
            for child in (try? el.getChildNodes()) ?? [] {
                renderNode(child, into: &ctx, style: next)
            }
            ctx.paragraphBreak()
            return
        default:
            break
        }

        for child in (try? el.getChildNodes()) ?? [] {
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
