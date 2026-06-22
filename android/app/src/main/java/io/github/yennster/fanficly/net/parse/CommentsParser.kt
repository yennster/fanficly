package io.github.yennster.fanficly.net.parse

import io.github.yennster.fanficly.model.AO3Comment
import io.github.yennster.fanficly.net.AO3Endpoints
import org.jsoup.Jsoup
import org.jsoup.nodes.Element

/**
 * Parses the comment thread (and the comment-form pseud id / new-comment form)
 * from a work or chapter page fetched with `?show_comments=true` — the Kotlin
 * port of iOS `CommentsParser`. Comments nest via `ol.thread`; depth drives the
 * reply indentation in the UI.
 */
object CommentsParser {

    fun parse(html: String): List<AO3Comment> {
        val doc = Jsoup.parse(html)
        // Match each comment <li> by its `comment_<id>` directly — AO3 renders an
        // empty #comments wrapper before the real list, so scoping to "the first
        // container" finds nothing.
        return doc.select("li.comment[id^=comment_]").mapNotNull(::parseComment)
    }

    private fun parseComment(li: Element): AO3Comment? {
        val idAttr = li.id()
        if (!idAttr.startsWith("comment_")) return null
        val id = idAttr.removePrefix("comment_")
        if (id.isEmpty()) return null

        val byline = li.selectFirst("h4.byline, h4.heading.byline")
        val bylineAnchor = byline?.selectFirst("a")
        val username = SearchResultsParser.authorLogin(bylineAnchor?.attr("href") ?: "")
        val name = bylineAnchor?.text()?.takeIf { it.isNotEmpty() }
            ?: byline?.text()?.takeIf { it.isNotEmpty() }
            ?: "Anonymous"

        val dateText = li.selectFirst("span.posted.datetime, p.datetime")?.text() ?: ""
        // `.first()` is this comment's own body — it precedes nested replies' blockquotes.
        val bodyHtml = li.selectFirst("blockquote.userstuff")?.html() ?: ""

        // Reply depth: count ancestor `ol.thread`s and drop the outermost.
        var threadCount = 0
        var ancestor: Element? = li.parent()
        while (ancestor != null) {
            if (ancestor.tagName() == "ol" && ancestor.hasClass("thread")) threadCount++
            ancestor = ancestor.parent()
        }
        val depth = maxOf(0, threadCount - 1)

        return AO3Comment(id, name, username, dateText, bodyHtml, depth)
    }

    /** The user's default pseud id from the comment form's `<select>`; null when absent. */
    fun defaultPseudId(html: String): String? {
        val doc = Jsoup.parse(html)
        val select = doc.selectFirst("select[name='comment[pseud_id]']") ?: return null
        select.selectFirst("option[selected]")?.attr("value")?.takeIf { it.isNotEmpty() }?.let { return it }
        return select.selectFirst("option")?.attr("value")?.takeIf { it.isNotEmpty() }
    }

    data class NewCommentForm(val action: String, val fields: Map<String, String>)

    /**
     * The page's top-level new-comment form: its absolute action (AO3 encodes the
     * target chapter in it) plus hidden inputs (CSRF token, `commentable_*`) and
     * the default pseud — enough to replay AO3's own POST. Null when no composer
     * is present (e.g. logged out).
     */
    fun newCommentForm(html: String): NewCommentForm? {
        val doc = Jsoup.parse(html, AO3Endpoints.BASE.toString())
        val composers = doc.select("form[action*=/comments]").filter { hasCommentTextarea(it) }
        // Prefer the page-level composer over inline reply boxes nested in comments.
        val form = composers.firstOrNull { !isInsideComment(it) } ?: composers.firstOrNull() ?: return null

        val action = form.absUrl("action").ifEmpty { form.attr("action") }
        if (action.isEmpty()) return null

        val fields = LinkedHashMap<String, String>()
        for (input in form.select("input[type=hidden]")) {
            val name = input.attr("name")
            if (name.isNotEmpty()) fields[name] = input.attr("value")
        }
        defaultPseudId(html)?.let { fields["comment[pseud_id]"] = it }
        return NewCommentForm(action, fields)
    }

    private fun hasCommentTextarea(form: Element): Boolean =
        form.select("textarea").any { it.attr("name").contains("comment_content") }

    private fun isInsideComment(el: Element): Boolean {
        var node: Element? = el.parent()
        while (node != null) {
            if (node.tagName() == "li" && node.hasClass("comment")) return true
            node = node.parent()
        }
        return false
    }
}
