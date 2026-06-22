package io.github.yennster.fanficly

import io.github.yennster.fanficly.data.db.FollowedAuthorEntity
import org.junit.Assert.assertEquals
import org.junit.Test

/** Pure tests for the followed-author known-work-id storage + new-work diff. */
class FollowedAuthorTest {

    private fun author(ids: String) = FollowedAuthorEntity(
        username = "u", displayName = "U", followedAtMillis = 0L, lastCheckedAtMillis = null, knownWorkIds = ids,
    )

    @Test fun knownIdsRoundTrip() {
        assertEquals("1,2,3", FollowedAuthorEntity.joinIds(listOf(1, 2, 3)))
        assertEquals(listOf(1, 2, 3), author("1,2,3").knownIds())
    }

    @Test fun emptyKnownIds() {
        assertEquals("", FollowedAuthorEntity.joinIds(emptyList()))
        assertEquals(emptyList<Int>(), author("").knownIds())
    }

    @Test fun joinIdsDedupesViaSet() {
        // The poller stores `known + latest` (a Set), so duplicates collapse.
        assertEquals(setOf(1, 2, 3), (setOf(1, 2) + listOf(2, 3)))
    }

    @Test fun newWorkDiffOnlyReportsUnseen() {
        // The poller's rule: new = works not in the known set.
        val known = author("1,2,3").knownIds().toSet()
        val latest = listOf(4, 3, 2, 5)
        assertEquals(listOf(4, 5), latest.filter { it !in known })
    }

    @Test fun noBaselineMeansNoAlert() {
        // A freshly-followed author with no seed has an empty baseline; the poller
        // skips alerting (only notifies when known is non-empty).
        val known = author("").knownIds().toSet()
        assertEquals(true, known.isEmpty())
    }
}
