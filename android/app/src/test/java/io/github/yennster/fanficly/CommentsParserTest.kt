package io.github.yennster.fanficly

import io.github.yennster.fanficly.net.parse.CommentsParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of the iOS `CommentsParserTests` — thread depth, guest comments, pseud id, form. */
class CommentsParserTest {

    // One top-level comment with a nested reply (depth 1), plus a guest comment.
    private val threadHtml = """
        <div id="comments_placeholder">
          <ol class="thread">
            <li class="comment group" id="comment_1" role="article">
              <h4 class="byline heading"><a href="/users/alice/pseuds/alice">alice</a></h4>
              <span class="posted datetime">10 Jun 2026</span>
              <blockquote class="userstuff"><p>Top-level comment.</p></blockquote>
            </li>
            <li>
              <ol class="thread">
                <li class="comment group" id="comment_2" role="article">
                  <h4 class="byline heading"><a href="/users/bob/pseuds/bob">bob</a></h4>
                  <span class="posted datetime">11 Jun 2026</span>
                  <blockquote class="userstuff"><p>A reply.</p></blockquote>
                </li>
              </ol>
            </li>
            <li class="comment group" id="comment_3" role="article">
              <h4 class="byline heading">Guest</h4>
              <span class="posted datetime">12 Jun 2026</span>
              <blockquote class="userstuff"><p>A guest comment.</p></blockquote>
            </li>
          </ol>
        </div>
    """.trimIndent()

    @Test fun parsesCommentsWithDepth() {
        val comments = CommentsParser.parse(threadHtml)
        assertEquals(3, comments.size)
        val top = comments.first { it.id == "1" }
        assertEquals("alice", top.commenterName)
        assertEquals("alice", top.commenterUsername)
        assertEquals(0, top.depth)
        assertTrue(top.bodyHtml.contains("Top-level comment"))

        val reply = comments.first { it.id == "2" }
        assertEquals(1, reply.depth)
    }

    @Test fun guestCommentHasNoUsername() {
        val guest = CommentsParser.parse(threadHtml).first { it.id == "3" }
        assertEquals("Guest", guest.commenterName)
        assertEquals("", guest.commenterUsername)
    }

    @Test fun defaultPseudIdReadsSelectedOption() {
        val formHtml = """
            <form action="/works/5/comments">
              <select name="comment[pseud_id]">
                <option value="100">main</option>
                <option value="200" selected>alt</option>
              </select>
              <textarea name="comment[comment_content]"></textarea>
            </form>
        """.trimIndent()
        assertEquals("200", CommentsParser.defaultPseudId(formHtml))
    }

    @Test fun newCommentFormCapturesActionAndHiddenFields() {
        val formHtml = """
            <form action="/works/5/chapters/9/comments" method="post">
              <input type="hidden" name="authenticity_token" value="TOK123">
              <input type="hidden" name="comment[commentable_id]" value="9">
              <input type="hidden" name="comment[commentable_type]" value="Chapter">
              <textarea name="comment[comment_content]"></textarea>
            </form>
        """.trimIndent()
        val form = CommentsParser.newCommentForm(formHtml)!!
        assertTrue(form.action.endsWith("/works/5/chapters/9/comments"))
        assertEquals("TOK123", form.fields["authenticity_token"])
        assertEquals("Chapter", form.fields["comment[commentable_type]"])
    }

    @Test fun noComposerReturnsNull() {
        assertNull(CommentsParser.newCommentForm("<div>no form here</div>"))
    }
}
