import Foundation
import SwiftSoup
import SwiftUI

enum HTMLToAttributed {
    static func convert(_ html: String) -> AttributedString {
        guard let doc = try? SwiftSoup.parseBodyFragment(html),
              let body = doc.body() else {
            return AttributedString(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
        }
        var output = AttributedString()
        let children = (try? body.getChildNodes()) ?? []
        for child in children {
            renderNode(child, into: &output, style: InlineStyle(), depth: 0)
        }
        while output.characters.last == "\n" || output.characters.last == " " {
            output.removeSubrange(output.index(beforeCharacter: output.endIndex) ..< output.endIndex)
        }
        return output
    }

    private struct InlineStyle {
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var monospaced = false
        var blockquote = false
    }

    private static func renderNode(
        _ node: Node,
        into output: inout AttributedString,
        style: InlineStyle,
        depth: Int
    ) {
        if let textNode = node as? TextNode {
            var raw = textNode.getWholeText()
            raw = raw.replacingOccurrences(of: "\u{00A0}", with: " ")
            if raw.isEmpty { return }
            var fragment = AttributedString(raw)
            if style.bold && style.italic {
                fragment.inlinePresentationIntent = [.stronglyEmphasized, .emphasized]
            } else if style.bold {
                fragment.inlinePresentationIntent = .stronglyEmphasized
            } else if style.italic {
                fragment.inlinePresentationIntent = .emphasized
            }
            if style.underline {
                fragment.underlineStyle = .single
            }
            if style.strike {
                fragment.strikethroughStyle = .single
            }
            output.append(fragment)
            return
        }
        guard let el = node as? Element else { return }
        let tag = el.tagName().lowercased()
        var nextStyle = style

        switch tag {
        case "br":
            output.append(AttributedString("\n"))
            return
        case "hr":
            ensureBlockBreak(&output)
            output.append(AttributedString("· · ·\n\n"))
            return
        case "strong", "b":
            nextStyle.bold = true
        case "em", "i", "cite":
            nextStyle.italic = true
        case "u":
            nextStyle.underline = true
        case "s", "strike", "del":
            nextStyle.strike = true
        case "code", "tt":
            nextStyle.monospaced = true
        case "blockquote":
            ensureBlockBreak(&output)
            nextStyle.blockquote = true
            for child in (try? el.getChildNodes()) ?? [] {
                renderNode(child, into: &output, style: nextStyle, depth: depth + 1)
            }
            ensureBlockBreak(&output)
            return
        case "p", "div":
            for child in (try? el.getChildNodes()) ?? [] {
                renderNode(child, into: &output, style: nextStyle, depth: depth + 1)
            }
            ensureBlockBreak(&output)
            return
        case "h1", "h2", "h3", "h4", "h5", "h6":
            ensureBlockBreak(&output)
            nextStyle.bold = true
            for child in (try? el.getChildNodes()) ?? [] {
                renderNode(child, into: &output, style: nextStyle, depth: depth + 1)
            }
            ensureBlockBreak(&output)
            return
        case "li":
            output.append(AttributedString("• "))
            for child in (try? el.getChildNodes()) ?? [] {
                renderNode(child, into: &output, style: nextStyle, depth: depth + 1)
            }
            output.append(AttributedString("\n"))
            return
        case "ul", "ol":
            ensureBlockBreak(&output)
            for child in (try? el.getChildNodes()) ?? [] {
                renderNode(child, into: &output, style: nextStyle, depth: depth + 1)
            }
            ensureBlockBreak(&output)
            return
        default:
            break
        }

        for child in (try? el.getChildNodes()) ?? [] {
            renderNode(child, into: &output, style: nextStyle, depth: depth + 1)
        }
    }

    private static func ensureBlockBreak(_ output: inout AttributedString) {
        let suffix = String(output.characters.suffix(2))
        if suffix.hasSuffix("\n\n") { return }
        if suffix.hasSuffix("\n") {
            output.append(AttributedString("\n"))
        } else if !output.characters.isEmpty {
            output.append(AttributedString("\n\n"))
        }
    }
}

private extension AttributedString {
    func index(beforeCharacter index: AttributedString.Index) -> AttributedString.Index {
        characters.index(before: index)
    }
}
