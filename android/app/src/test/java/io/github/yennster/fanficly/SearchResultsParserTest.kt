package io.github.yennster.fanficly

import io.github.yennster.fanficly.net.parse.SearchResultsParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Fixture-based parser tests — the Kotlin port of the iOS
 * `SearchResultsParserTests`. Pure HTML in, typed values out, no network.
 */
class SearchResultsParserTest {

    private val sampleHtml = """
        <ol class="work index group">
          <li id="work_42" class="work blurb group">
            <div class="header module">
              <h4 class="heading">
                <a href="/works/42">A Test Work</a> by
                <a rel="author" href="/users/Tester/pseuds/Tester">Tester</a>
              </h4>
              <h5 class="fandoms heading"><a class="tag" href="/tags/Test/works">Test Fandom</a></h5>
              <ul class="required-tags">
                <li><span class="text">Teen And Up Audiences</span></li>
                <li><span class="text">No Archive Warnings Apply</span></li>
                <li><span class="text">M/M</span></li>
              </ul>
            </div>
            <blockquote class="summary"><p>A summary.</p></blockquote>
            <ul class="tags commas">
              <li class="relationships"><a class="tag" href="#">A/B</a></li>
              <li class="characters"><a class="tag" href="#">Character C</a></li>
              <li class="freeforms"><a class="tag" href="#">Fluff</a></li>
            </ul>
            <dl class="stats">
              <dd class="language">English</dd>
              <dd class="words">12,345</dd>
              <dd class="chapters">3/5</dd>
              <dd class="kudos">1,234</dd>
              <dd class="hits">9,999</dd>
            </dl>
          </li>
        </ol>
        <ol class="pagination actions">
          <li><span class="current">1</span></li>
          <li><a href="?page=2">2</a></li>
        </ol>
    """.trimIndent()

    @Test
    fun parsesWorkBlurb() {
        val results = SearchResultsParser.parse(sampleHtml)
        assertEquals(1, results.works.size)
        val w = results.works.first()
        assertEquals(42, w.id)
        assertEquals("A Test Work", w.title)
        assertEquals("Tester", w.author)
        assertEquals("Tester", w.authorUsername)
        assertEquals("Test Fandom", w.fandoms.first())
        assertEquals("Teen And Up Audiences", w.rating)
        assertTrue(w.warnings.contains("No Archive Warnings Apply"))
        assertEquals(12_345, w.wordCount)
        assertEquals(1_234, w.kudos)
        assertEquals(3, w.chapterCount)
        assertEquals(5, w.totalChapters)
    }

    @Test
    fun readsPagination() {
        val results = SearchResultsParser.parse(sampleHtml)
        assertEquals(1, results.currentPage)
        assertEquals(2, results.totalPages)
    }

    @Test
    fun extractsWorkIdFromHref() {
        assertEquals(123, SearchResultsParser.workId("/works/123"))
        assertEquals(123, SearchResultsParser.workId("/works/123/chapters/456"))
        assertNull(SearchResultsParser.workId("/series/9"))
    }

    @Test
    fun parsesAuthorLogin() {
        assertEquals("HoweverSheWrites", SearchResultsParser.authorLogin("/users/HoweverSheWrites/pseuds/HoweverSheWrites"))
        assertEquals("", SearchResultsParser.authorLogin(""))
    }
}
