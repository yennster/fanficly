package io.github.yennster.fanficly

import io.github.yennster.fanficly.net.parse.MediaCategoryParser
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Port of the iOS `MediaCategoryParserTests` — fandom list + trailing counts. */
class MediaCategoryParserTest {

    private val html = """
        <ol class="tags index group">
          <li><a href="/tags/Harry%20Potter%20-%20J.%20K.%20Rowling/works">Harry Potter - J. K. Rowling</a> (123,456)</li>
          <li><a href="/tags/Marvel%20Cinematic%20Universe/works">Marvel Cinematic Universe</a> (98,765)</li>
          <li><a href="/tags/Some%20Tag/works">Some Tag</a></li>
          <li><a href="/tags/Marvel%20Cinematic%20Universe/works">Marvel Cinematic Universe</a> (98,765)</li>
          <li><a href="/media/Anime/fandoms">Not a fandom link</a></li>
        </ol>
    """.trimIndent()

    @Test fun parsesFandomsWithCountsAndDedupes() {
        val fandoms = MediaCategoryParser.parse(html)
        // 3 unique /tags/.../works links (MCU appears twice → deduped); media link skipped.
        assertEquals(3, fandoms.size)
        val hp = fandoms.first { it.canonicalName == "Harry Potter - J. K. Rowling" }
        assertEquals(123456, hp.workCount)
        val mcu = fandoms.first { it.canonicalName == "Marvel Cinematic Universe" }
        assertEquals(98765, mcu.workCount)
    }

    @Test fun missingCountIsNull() {
        val fandoms = MediaCategoryParser.parse(html)
        assertNull(fandoms.first { it.canonicalName == "Some Tag" }.workCount)
    }

    @Test fun sortsWithLocaleCollationNotCodePoints() {
        val accented = """
            <ol>
              <li><a href="/tags/Cafz/works">Cafz</a></li>
              <li><a href="/tags/Caf%C3%A9/works">Café</a></li>
            </ol>
        """.trimIndent()
        val names = MediaCategoryParser.parse(accented).map { it.canonicalName }
        // Locale collation folds 'é'→'e', so "Café" (e < z) precedes "Cafz".
        // A raw UTF-16 code-point sort would wrongly place "Café" (é=0xE9 > 'z') last.
        assertEquals(listOf("Café", "Cafz"), names)
    }

    @Test fun trailingCountParsesGroupedDigits() {
        assertEquals(123456, MediaCategoryParser.trailingCount("Harry Potter - J. K. Rowling (123,456)"))
        assertNull(MediaCategoryParser.trailingCount("No parens here"))
        assertNull(MediaCategoryParser.trailingCount("Empty ()"))
    }
}
