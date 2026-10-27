import Foundation
import SwiftData
import UserNotifications
import os

@MainActor
struct SubscriptionPoller {
    let client: any AO3ClientProtocol
    let context: ModelContext
    /// AO3 username for syncing account subscriptions; nil when logged out
    /// (locally-followed works are still polled).
    let username: String?
    private let logger = Logger(subsystem: "io.github.yennster.fanficly", category: "SubscriptionPoller")

    func syncSubscriptionList() async throws -> [AO3Subscription] {
        guard let username else { return [] }
        let fresh = try await client.fetchSubscriptions(username: username)
        let freshKeys = Set(fresh.map(\.key))

        let descriptor = FetchDescriptor<SubscriptionRecord>()
        let existing = (try? context.fetch(descriptor)) ?? []
        let existingByKey = Dictionary(uniqueKeysWithValues: existing.map { ($0.key, $0) })

        for sub in fresh {
            if let rec = existingByKey[sub.key] {
                rec.displayName = sub.title
                rec.authorName = sub.author ?? rec.authorName
            } else {
                let rec = SubscriptionRecord(
                    key: sub.key,
                    kind: sub.kind.rawValue,
                    displayName: sub.title,
                    authorName: sub.author ?? ""
                )
                context.insert(rec)
            }
        }
        // Fail closed on pruning: an empty fetch with records on hand is far
        // more likely a stale session or markup drift than a mass
        // unsubscribe, and a wrong delete also destroys the
        // lastSeenChapterCount baselines new-chapter alerts compare against.
        // (The parser already throws on a login page; this guards the rest.)
        if !fresh.isEmpty {
            for rec in existing where !freshKeys.contains(rec.key) {
                context.delete(rec)
            }
        }
        try? context.save()
        return fresh
    }

    func checkForNewChapters() async -> Int {
        var notifyCount = 0
        for rec in workSubscriptionRecords() {
            notifyCount += await checkWorkSubscription(rec)
        }
        try? context.save()
        return notifyCount
    }

    /// Poll locally-followed works (no AO3 login required) for new chapters.
    func checkFollowedWorks() async -> Int {
        var notifyCount = 0
        for work in followedWorks() {
            notifyCount += await checkFollowedWork(work)
        }
        try? context.save()
        return notifyCount
    }

    /// Poll locally-followed authors (no AO3 login required) for newly
    /// published works, notifying once per new work.
    func checkFollowedAuthors() async -> Int {
        var notifyCount = 0
        for author in followedAuthors() {
            notifyCount += await checkFollowedAuthor(author)
        }
        try? context.save()
        return notifyCount
    }

    /// One unit of poll work, ordered by how stale its last check is. A work
    /// that's both AO3-subscribed and locally followed is one target, so a
    /// poll fetches each work once (#148).
    private enum PollTarget {
        case work(id: Int, subscription: SubscriptionRecord?, followed: Work?)
        case followedAuthor(FollowedAuthor)

        var lastCheckedAt: Date? {
            switch self {
            case .work(_, let rec, let work):
                // The staler of the two; a record never checked goes first.
                [rec.map { $0.lastCheckedAt ?? .distantPast },
                 work.map { $0.lastCheckedAt ?? .distantPast }].compactMap { $0 }.min()
            case .followedAuthor(let author): author.lastCheckedAt
            }
        }
    }

    func runFullPoll() async -> Int {
        do {
            _ = try await syncSubscriptionList()
        } catch {
            logger.warning("Subscriptions list fetch failed: \(error.localizedDescription, privacy: .public)")
        }

        // Interleave all three record kinds oldest-check-first rather than a
        // fixed subs → works → authors order. Every check costs one throttled
        // (1 req/s) request and a BGAppRefreshTask only gets ~30s, so a fixed
        // order permanently starves the last category once the earlier ones
        // outgrow the budget; oldest-first means whatever was cut off last
        // time is exactly what runs first this time.
        var targets = workTargets(subscriptions: username != nil ? workSubscriptionRecords() : [],
                                  followed: followedWorks())
        targets += followedAuthors().map(PollTarget.followedAuthor)
        targets.sort { ($0.lastCheckedAt ?? .distantPast) < ($1.lastCheckedAt ?? .distantPast) }

        var total = 0
        for target in targets {
            // The BG scheduler cancels us at expiry — stop cleanly and keep
            // the progress saved so far.
            if Task.isCancelled { break }
            switch target {
            case .work(let id, let rec, let work):
                total += await checkWork(id: id, subscription: rec, followed: work)
            case .followedAuthor(let author): total += await checkFollowedAuthor(author)
            }
            // Save after every record so an expiring BG task keeps its
            // lastCheckedAt stamps — they drive the rotation.
            try? context.save()
        }
        WidgetDataStore.updateAll(context: context)
        return total
    }

    // MARK: - Per-record checks

    /// The work targets of a poll, one per AO3 work id: a subscription and a
    /// follow of the same work share a target, so the work is fetched once.
    private func workTargets(subscriptions: [SubscriptionRecord], followed: [Work]) -> [PollTarget] {
        var ids: [Int] = []
        var recs: [Int: SubscriptionRecord] = [:]
        var works: [Int: Work] = [:]
        for rec in subscriptions {
            guard let id = Self.workId(subscriptionKey: rec.key), recs[id] == nil else { continue }
            recs[id] = rec
            ids.append(id)
        }
        for work in followed where works[work.ao3Id] == nil {
            works[work.ao3Id] = work
            if recs[work.ao3Id] == nil { ids.append(work.ao3Id) }
        }
        return ids.map { PollTarget.work(id: $0, subscription: recs[$0], followed: works[$0]) }
    }

    /// The work id in a work subscription's key (`work:<id>`).
    private static func workId(subscriptionKey key: String) -> Int? {
        let parts = key.split(separator: ":")
        guard parts.count == 2 else { return nil }
        return Int(parts[1])
    }

    /// Check one AO3 work subscription for a new chapter (one throttled
    /// request). Returns the number of notifications posted.
    private func checkWorkSubscription(_ rec: SubscriptionRecord) async -> Int {
        guard let workId = Self.workId(subscriptionKey: rec.key) else {
            rec.lastCheckedAt = .now
            return 0
        }
        return await checkWork(id: workId, subscription: rec, followed: nil)
    }

    private func checkFollowedWork(_ work: Work) async -> Int {
        await checkWork(id: work.ao3Id, subscription: nil, followed: work)
    }

    /// Check a work for new chapters with one throttled request of its light
    /// page, for its subscription, its follow or both, and post at most one
    /// alert. Returns the number of notifications posted.
    private func checkWork(id workId: Int, subscription rec: SubscriptionRecord?, followed work: Work?) async -> Int {
        // Stamp the attempt up front: a permanently-failing record (deleted
        // work, parse drift) must not stay "oldest" forever and hog the head
        // of the round-robin queue.
        defer {
            rec?.lastCheckedAt = .now
            work?.lastCheckedAt = .now
        }
        do {
            let meta = try await client.fetchWorkMetadata(id: workId)
            var notifyCount = 0
            // Against the higher baseline: chapters either record already
            // counted were alerted (or seen) then, and mustn't alert again.
            let lastSeen = [rec?.lastSeenChapterCount, work?.lastSeenChapterCount].compactMap { $0 }.max()
            if let lastSeen, meta.chapterCount > lastSeen {
                await postNewChapterNotification(
                    title: work?.title ?? rec?.displayName ?? "",
                    oldCount: lastSeen,
                    newCount: meta.chapterCount,
                    workId: workId
                )
                notifyCount = 1
            }
            rec?.lastSeenChapterCount = meta.chapterCount
            work?.lastSeenChapterCount = meta.chapterCount
            return notifyCount
        } catch {
            logger.warning("Skipping work \(workId): \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    private func checkFollowedAuthor(_ author: FollowedAuthor) async -> Int {
        defer { author.lastCheckedAt = .now }
        do {
            let result = try await client.fetchAuthorWorks(username: author.username, page: 1)
            // Signed in but served the guest page: the session expired. The
            // public works still alert; restricted ones aren't in the baseline
            // yet, so they alert once a signed-in poll sees them.
            if username != nil, result.servedAsGuest {
                logger.warning("Author \(author.username, privacy: .public) came back as a guest page: the AO3 session expired")
            }
            let latestIds = result.works.map(\.id)
            let known = Set(author.knownWorkIds)
            var notifyCount = 0
            let newWorks = Self.newlyPostedWorks(in: result.works, known: known)
            if !newWorks.isEmpty {
                await postNewWorkNotification(
                    author: author,
                    newWorks: newWorks
                )
                notifyCount = newWorks.count
            }
            author.knownWorkIds = Array(known.union(latestIds))
            return notifyCount
        } catch {
            logger.warning("Skipping author \(author.username, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    // MARK: - Record fetches

    private func workSubscriptionRecords() -> [SubscriptionRecord] {
        let descriptor = FetchDescriptor<SubscriptionRecord>(
            predicate: #Predicate { $0.kind == "work" }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func followedWorks() -> [Work] {
        let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.isFollowed == true })
        return (try? context.fetch(descriptor)) ?? []
    }

    private func followedAuthors() -> [FollowedAuthor] {
        let descriptor = FetchDescriptor<FollowedAuthor>()
        return ((try? context.fetch(descriptor)) ?? []).filter { !$0.username.isEmpty }
    }

    private func postNewWorkNotification(author: FollowedAuthor, newWorks: [AO3WorkSummary]) async {
        let content = Self.newWorkContent(
            authorUsername: author.username,
            authorName: author.displayName,
            newWorks: newWorks
        )
        let newestId = newWorks.first?.id ?? 0
        let request = UNNotificationRequest(
            identifier: "author-\(author.displayName)-newwork-\(newestId)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func postNewChapterNotification(title: String, oldCount: Int, newCount: Int, workId: Int) async {
        let content = Self.newChapterContent(title: title, oldCount: oldCount, newCount: newCount, workId: workId)
        let request = UNNotificationRequest(
            identifier: "work-\(workId)-update-\(newCount)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// The works on an author's first page that are newly posted since the
    /// baseline `known` was taken. AO3 lists an author's works by last update,
    /// so an older work we never saw (it was past page 1 at follow time) shows
    /// up unknown when it gets a chapter; alerting for it as a new work opened
    /// that old story. An unknown work is new when it's newer than every known
    /// one (AO3 work ids only grow) or has a single chapter, which an update
    /// can't leave it with — that still catches a new work with a lower id: a
    /// gift revealed from an anonymous collection, a long-held draft, or a
    /// restricted work a guest page left out. Empty with no baseline yet — a
    /// freshly-followed author is seeded at follow time, but a first poll must
    /// never alert for the whole back catalogue. Internal for tests.
    nonisolated static func newlyPostedWorks(in works: [AO3WorkSummary], known: Set<Int>) -> [AO3WorkSummary] {
        guard let newestKnown = known.max() else { return [] }
        return works.filter { !known.contains($0.id) && ($0.id > newestKnown || $0.chapterCount == 1) }
    }

    // MARK: - Notification content

    /// A followed author's new work(s). One work opens that work; several open
    /// the author's page. Internal for tests.
    nonisolated static func newWorkContent(
        authorUsername: String,
        authorName: String,
        newWorks: [AO3WorkSummary]
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = authorName
        if newWorks.count == 1, let work = newWorks.first {
            content.body = "New work: \(work.title)"
            content.userInfo = NotificationRoute.newWork(workId: work.id).userInfo
        } else {
            content.body = "\(newWorks.count) new works posted"
            content.userInfo = NotificationRoute.newWorks(
                author: AuthorRef(username: authorUsername, displayName: authorName)
            ).userInfo
        }
        content.sound = .default
        return content
    }

    /// New chapters on a followed or subscribed work; opens the work. Internal
    /// for tests.
    nonisolated static func newChapterContent(
        title: String,
        oldCount: Int,
        newCount: Int,
        workId: Int
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        let added = newCount - oldCount
        content.body = added == 1
            ? "1 new chapter posted (\(newCount) total)"
            : "\(added) new chapters posted (\(newCount) total)"
        content.sound = .default
        content.userInfo = NotificationRoute.newChapters(workId: workId).userInfo
        return content
    }
}

enum NotificationsAuthorization {
    static func request() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        @unknown default:
            return false
        }
    }

    /// Fire-and-forget request for the local-follow flow. Follows are the
    /// headline logged-out feature and their whole payoff is the poller's
    /// new-chapter/new-work notifications, so ask the moment the user first
    /// follows something — never gated on an AO3 login. Skipped in demo and
    /// unit-test runs so screenshot automation and tests never trip the
    /// system permission alert.
    @MainActor
    static func requestAfterFollow() {
        guard !FanficlyApp.isDemoMode, !FanficlyApp.isTestMode else { return }
        Task { _ = await request() }
    }
}
