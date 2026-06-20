package io.github.yennster.fanficly.ui.reader

import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.nodes.Node
import org.jsoup.nodes.TextNode

/**
 * Turns a chapter's AO3 HTML into a list of styled paragraph [AnnotatedString]s
 * — the Kotlin port of iOS `HTMLToAttributed.paragraphs`. Block elements (`p`,
 * `div`, headings, list items, `blockquote`) become separate paragraphs;
 * `<br>` becomes a line break; `<em>/<i>`, `<strong>/<b>`, and `<hr>` (rendered
 * as a centered scene break) are honored inline. Everything else degrades to
 * plain text.
 */
object HtmlRender {

    fun paragraphs(html: String): List<AnnotatedString> {
        if (html.isBlank()) return emptyList()
        val body = Jsoup.parseBodyFragment(html).body()
        val out = mutableListOf<AnnotatedString>()
        collectBlocks(body, out)
        return out.filter { it.text.isNotBlank() || it.text == SCENE_BREAK }
    }

    private val BLOCK_TAGS = setOf(
        "p", "div", "blockquote", "li", "h1", "h2", "h3", "h4", "h5", "h6", "pre",
    )

    private fun collectBlocks(element: Element, out: MutableList<AnnotatedString>) {
        // If this element directly contains block children, recurse into them.
        val hasBlockChildren = element.children().any { it.tagName() in BLOCK_TAGS || it.tagName() == "ul" || it.tagName() == "ol" }
        if (hasBlockChildren) {
            for (child in element.childNodes()) {
                when (child) {
                    is Element -> when (child.tagName()) {
                        "hr" -> out += AnnotatedString(SCENE_BREAK)
                        "ul", "ol" -> collectBlocks(child, out)
                        in BLOCK_TAGS -> {
                            if (child.children().any { it.tagName() in BLOCK_TAGS }) {
                                collectBlocks(child, out)
                            } else {
                                val styled = renderInline(child)
                                if (styled.text.isNotBlank()) out += styled
                            }
                        }
                        else -> {
                            val styled = renderInline(child)
                            if (styled.text.isNotBlank()) out += styled
                        }
                    }
                    is TextNode -> {
                        val t = child.text().trim()
                        if (t.isNotEmpty()) out += AnnotatedString(t)
                    }
                }
            }
        } else {
            when {
                element.tagName() == "hr" -> out += AnnotatedString(SCENE_BREAK)
                else -> {
                    val styled = renderInline(element)
                    if (styled.text.isNotBlank()) out += styled
                }
            }
        }
    }

    private fun renderInline(element: Element): AnnotatedString = buildAnnotatedString {
        appendNode(element, this)
    }

    private fun appendNode(node: Node, builder: androidx.compose.ui.text.AnnotatedString.Builder) {
        when (node) {
            is TextNode -> builder.append(node.text())
            is Element -> when (node.tagName()) {
                "br" -> builder.append("\n")
                "hr" -> builder.append("\n$SCENE_BREAK\n")
                "em", "i" -> builder.withStyle(SpanStyle(fontStyle = FontStyle.Italic)) {
                    node.childNodes().forEach { appendNode(it, builder) }
                }
                "strong", "b" -> builder.withStyle(SpanStyle(fontWeight = FontWeight.Bold)) {
                    node.childNodes().forEach { appendNode(it, builder) }
                }
                else -> node.childNodes().forEach { appendNode(it, builder) }
            }
        }
    }

    const val SCENE_BREAK = "* * *"
}
