package io.github.yennster.fanficly.subscriptions

import android.content.Context
import io.github.yennster.fanficly.data.LibraryRepository
import io.github.yennster.fanficly.net.AO3Client

/**
 * Polls locally-followed works for new chapters and fires a local notification
 * per updated work — the Android port of the iOS `SubscriptionPoller`'s
 * `checkFollowedWorks`. Works fully logged-out (local follows need no AO3
 * account). A null `lastSeenChapterCount` means "no baseline yet", so the first
 * poll after following never alerts for the existing back catalogue.
 *
 * Polling AO3 account subscriptions / followed authors for new chapters/works is
 * a follow-up; the subscriptions list itself is viewable live (login-gated).
 */
class SubscriptionPoller(
    private val context: Context,
    private val client: AO3Client,
    private val repo: LibraryRepository,
) {
    suspend fun checkFollowedWorks(): Int {
        var notified = 0
        for (work in repo.followedWorks()) {
            val meta = runCatching { client.fetchWorkMetadata(work.ao3Id) }.getOrNull() ?: continue
            val lastSeen = work.lastSeenChapterCount
            if (lastSeen != null && meta.chapterCount > lastSeen) {
                Notifications.postNewChapter(context, work.ao3Id, work.title, lastSeen, meta.chapterCount)
                notified++
            }
            repo.setLastSeenChapterCount(work.ao3Id, meta.chapterCount)
        }
        return notified
    }

    /**
     * Poll locally-followed authors for newly-published works (login-free,
     * port of the iOS `checkFollowedAuthors`). Only notifies once there's a
     * baseline — a freshly-followed author is seeded with its current works at
     * follow time, so the first poll never alerts for the back catalogue.
     */
    suspend fun checkFollowedAuthors(): Int {
        var notified = 0
        for (author in repo.followedAuthors()) {
            if (author.username.isEmpty()) continue
            val result = runCatching { client.fetchAuthorWorks(author.username, 1) }.getOrNull() ?: continue
            val known = author.knownIds().toSet()
            if (known.isNotEmpty()) {
                val newWorks = result.works.filter { it.id !in known }
                if (newWorks.isNotEmpty()) {
                    Notifications.postNewWork(context, author.displayName, newWorks)
                    notified += newWorks.size
                }
            }
            repo.updateAuthorChecked(author.username, known + result.works.map { it.id }, System.currentTimeMillis())
        }
        return notified
    }

    suspend fun runFullPoll(): Int = checkFollowedWorks() + checkFollowedAuthors()
}
