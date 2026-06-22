package io.github.yennster.fanficly.net.parse

import io.github.yennster.fanficly.model.AO3Subscription
import org.jsoup.Jsoup
import org.jsoup.nodes.Element

/**
 * Parses the logged-in user's `/users/<name>/subscriptions` page into typed
 * [AO3Subscription]s (works, series, users) — the Kotlin port of iOS
 * `SubscriptionsParser`. AO3's markup varies, so it scopes to any subscription
 * container and classifies each entry by its primary link's path.
 */
object SubscriptionsParser {

    fun parse(html: String): List<AO3Subscription> {
        val doc = Jsoup.parse(html)
        val seen = HashSet<String>()
        val results = mutableListOf<AO3Subscription>()

        val containers = doc.select(
            "dl.subscription, ul.subscription, dl.subscriptions, ul.subscriptions, ol.subscription, ol.subscriptions",
        )
        val scopes: List<Element> = if (containers.isEmpty()) listOf(doc.body() ?: doc) else containers

        for (scope in scopes) {
            val entries = scope.select("dt, li.subscription, li.work, li.series, li.user")
            val entrySource: List<Element> = if (entries.isEmpty()) listOf(scope) else entries
            for (entry in entrySource) {
                val links = entry.select("a[href]")
                val primary = pickPrimaryLink(links) ?: continue
                val parsed = classify(primary.attr("href")) ?: continue
                if (!seen.add(parsed.key)) continue
                results += AO3Subscription(
                    kind = parsed.kind,
                    resourceId = parsed.id,
                    title = primary.text().trim(),
                    author = authorFromEntry(links, primary),
                )
            }
        }
        return results
    }

    private fun pickPrimaryLink(links: List<Element>): Element? =
        links.firstOrNull { classify(it.attr("href")) != null && !it.attr("href").contains("/comments") }

    private fun authorFromEntry(links: List<Element>, primary: Element): String? {
        for (link in links) {
            if (link === primary) continue
            if (link.attr("href").startsWith("/users/")) {
                val text = link.text().trim()
                if (text.isNotEmpty()) return text
            }
        }
        return null
    }

    private data class Classified(val kind: AO3Subscription.Kind, val id: String) {
        val key: String get() = "${kind.slug}:$id"
    }

    private fun classify(href: String): Classified? {
        val trimmed = href.substringBefore('?').trim('/')
        val parts = trimmed.split("/").filter { it.isNotEmpty() }
        if (parts.size < 2) return null
        return when (parts[0]) {
            "works" -> Classified(AO3Subscription.Kind.WORK, parts[1])
            "series" -> Classified(AO3Subscription.Kind.SERIES, parts[1])
            "users" -> if (parts.size == 2 || (parts.size >= 3 && parts[2] == "pseuds")) {
                Classified(AO3Subscription.Kind.USER, parts[1])
            } else null
            else -> null
        }
    }
}
