package io.github.yennster.fanficly

import io.github.yennster.fanficly.model.AO3Subscription
import io.github.yennster.fanficly.net.parse.SubscriptionsParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of the iOS `SubscriptionsParserTests` — works/series/users + author + dedupe. */
class SubscriptionsParserTest {

    private val html = """
        <dl class="subscription">
          <dt>
            <a href="/works/12345">A Subscribed Work</a> by <a href="/users/someauthor">someauthor</a>
          </dt>
          <dt>
            <a href="/series/678">A Subscribed Series</a>
          </dt>
          <dt>
            <a href="/users/coolwriter/pseuds/coolwriter">coolwriter</a>
          </dt>
          <dt>
            <a href="/works/12345">A Subscribed Work</a> by <a href="/users/someauthor">someauthor</a>
          </dt>
        </dl>
    """.trimIndent()

    @Test fun parsesWorkSeriesAndUser() {
        val subs = SubscriptionsParser.parse(html)
        // 3 unique (the duplicate work is deduped).
        assertEquals(3, subs.size)

        val work = subs.first { it.kind == AO3Subscription.Kind.WORK }
        assertEquals("12345", work.resourceId)
        assertEquals("A Subscribed Work", work.title)
        assertEquals("someauthor", work.author)
        assertEquals("work:12345", work.key)

        assertTrue(subs.any { it.kind == AO3Subscription.Kind.SERIES && it.resourceId == "678" })
        val user = subs.first { it.kind == AO3Subscription.Kind.USER }
        assertEquals("coolwriter", user.resourceId)
    }

    @Test fun seriesAndUserHaveNoAuthor() {
        val subs = SubscriptionsParser.parse(html)
        assertNull(subs.first { it.kind == AO3Subscription.Kind.SERIES }.author)
        assertNull(subs.first { it.kind == AO3Subscription.Kind.USER }.author)
    }

    @Test fun emptyHtmlYieldsNoSubscriptions() {
        assertTrue(SubscriptionsParser.parse("<html><body>No subs</body></html>").isEmpty())
    }
}
