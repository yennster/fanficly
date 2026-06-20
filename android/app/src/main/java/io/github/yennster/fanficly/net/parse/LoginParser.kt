package io.github.yennster.fanficly.net.parse

import org.jsoup.Jsoup

/**
 * Scrapes AO3's form-based login — the Kotlin port of iOS `LoginParser`.
 * AO3 exposes the CSRF token as either `<meta name="csrf-token">` or a hidden
 * `<input name="authenticity_token">`; the logged-in nav reveals the username.
 */
object LoginParser {

    fun authenticityToken(html: String): String? {
        val doc = Jsoup.parse(html)
        doc.selectFirst("meta[name=csrf-token]")?.attr("content")?.takeIf { it.isNotEmpty() }?.let { return it }
        doc.selectFirst("input[name=authenticity_token]")?.attr("value")?.takeIf { it.isNotEmpty() }?.let { return it }
        return null
    }

    /** The logged-in user's name from the greeting / user nav, or null. */
    fun currentUsername(html: String): String? {
        val doc = Jsoup.parse(html)
        // AO3's logged-in header links to /users/<name>; the greeting reads "Hi, <name>!".
        doc.selectFirst("#greeting a[href^=/users/]")?.let {
            val href = it.attr("href")
            val name = href.removePrefix("/users/").substringBefore('/')
            if (name.isNotEmpty()) return name
        }
        doc.selectFirst("a#user-info, ul.user a[href^=/users/]")?.let {
            val name = it.attr("href").removePrefix("/users/").substringBefore('/')
            if (name.isNotEmpty()) return name
        }
        return null
    }

    /** True if the response is still showing the login form (credentials rejected). */
    fun hasLoginForm(html: String): Boolean {
        val doc = Jsoup.parse(html)
        return doc.selectFirst("form#new_user, input[name=user[login]]") != null
    }

    /** An explicit AO3 error flash, if present. */
    fun detectLoginFailure(html: String): String? {
        val doc = Jsoup.parse(html)
        val flash = doc.selectFirst(".flash.error, .error")?.text()?.trim()
        return flash?.takeIf { it.isNotEmpty() }
    }
}
