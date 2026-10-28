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
    /// Holds when the account's subscriptions list was last synced (see
    /// `listSyncIsDue`); tests pass their own suite.
    var defaults: UserDefaults = .standard
    private let logger = Logger(subsystem: "io.github.yennster.fanficly", category: "SubscriptionPoller")

    /// How often a background poll re-reads the subscriptions list. The walk
    /// costs one throttled request per 20 subscriptions (up to 50), which on
    /// a big list is the whole ~30 s `BGAppRefreshTask` window, and the list
    /// rarely changes; the Subscriptions tab syncs it whenever it refreshes.
    static let listSyncInterval: TimeInterval = 24 * 60 * 60

    private var listSyncKey: String? {
        username.map { "subscriptions.listSyncedAt.\($0)" }
    }

    /// Whether `runFullPoll` should re-read the subscriptions list: signed in,
    /// and no sync (or attempt) for this account in `listSyncInterval`.
    func listSyncIsDue(now: Date = .now) -> Bool {
        guard let listSyncKey else { return false }
        guard let last = defaults.object(forKey: listSyncKey) as? Date else { return true }
        // A clock set back leaves a future stamp; don't let it block syncs.
        return last > now || now.timeIntervalSince(last) >= Self.listSyncInterval
    }

    private func stampListSync(_ date: Date = .now) {
        guard let listSyncKey else { return }
        defaults.set(date, forKey: listSyncKey)
    }

    func syncSubscriptionList() async throws -> [AO3Subscription] {
        guard let username else { return [] }
        let list = try await client.fetchSubscriptions(username: username)
        stampListSync()
        let fresh = list.subscriptions
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
        // A list cut off at the page ceiling is missing real subscriptions,
        // so it prunes nothing either.
        if !fresh.isEmpty, list.isComplete {
            for rec in existing where !freshKeys.contains(rec.key) {
                context.delete(rec)
            }
        }
        if !list.isComplete {
            logger.warning("Subscriptions list ran past the page ceiling; kept the records it didn't reach")
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

    /// Check saved searches with alerts on (#309) for newly posted works.
    func checkSavedSearchAlerts() async -> Int {
        var notifyCount = 0
        for search in alertingSearches() {
            if Task.isCancelled { break }
            notifyCount += await checkSavedSearch(search)
            try? context.save()
        }
        return notifyCount
    }

    /// The Search tab's check: alerting searches not checked for
    /// `SavedSearchAlerts.foregroundCheckInterval`, oldest first. The
    /// background refresh gets about 30 seconds, and an AO3 search often takes
    /// 20–30 seconds to answer, so there a search check is often cut off;
    /// this makes sure the feed still moves while the app is in use.
    func checkStaleSavedSearches(now: Date = .now) async -> Int {
        let stale = alertingSearches()
            .filter { now.timeIntervalSince($0.alertsLastCheckedAt ?? .distantPast) >= SavedSearchAlerts.foregroundCheckInterval }
            .filter { now.timeIntervalSince($0.alertsAttemptedAt ?? .distantPast) >= SavedSearchAlerts.foregroundRetryInterval }
            .sorted { ($0.alertsLastCheckedAt ?? .distantPast) < ($1.alertsLastCheckedAt ?? .distantPast) }
        var notifyCount = 0
        for search in stale {
            if Task.isCancelled { break }
            notifyCount += await checkSavedSearch(search)
            try? context.save()
        }
        return notifyCount
    }

    /// One unit of poll work, ordered by how stale its last check is. A work
    /// that's both AO3-subscribed and locally followed is one target, so a
    /// poll fetches each work once (#148).
    private enum PollTarget {
        case work(id: Int, subscription: SubscriptionRecord?, followed: Work?)
        case followedAuthor(FollowedAuthor)
        case savedSearch(SavedSearch)

        var lastCheckedAt: Date? {
            switch self {
            case .work(_, let rec, let work):
                // The staler of the two; a record never checked goes first.
                [rec.map { $0.lastCheckedAt ?? .distantPast },
                 work.map { $0.lastCheckedAt ?? .distantPast }].compactMap { $0 }.min()
            case .followedAuthor(let author): author.lastCheckedAt
            case .savedSearch(let search): search.alertsAttemptedAt ?? search.alertsLastCheckedAt
            }
        }
    }

    func runFullPoll() async -> Int {
        // At most once a day, so the window goes to the chapter checks below
        // (#150). Stamped before the walk: a list too long to finish in one
        // window would otherwise be retried, and cut off, on every run.
        if listSyncIsDue() {
            stampListSync()
            do {
                _ = try await syncSubscriptionList()
            } catch {
                logger.warning("Subscriptions list fetch failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Interleave every record kind oldest-check-first rather than a
        // fixed subs → works → authors order. Every check costs one throttled
        // (1 req/s) request and a BGAppRefreshTask only gets ~30s, so a fixed
        // order permanently starves the last category once the earlier ones
        // outgrow the budget; oldest-first means whatever was cut off last
        // time is exactly what runs first this time.
        var targets = workTargets(subscriptions: username != nil ? workSubscriptionRecords() : [],
                                  followed: followedWorks())
        targets += followedAuthors().map(PollTarget.followedAuthor)
        targets += alertingSearches().map(PollTarget.savedSearch)
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
            case .savedSearch(let search): total += await checkSavedSearch(search)
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
            guard let id = Self.workId(subscriptionKey: rec.key) else {
                // A key that names no work can't be checked; stamp it like a failed check.
                rec.lastCheckedAt = .now
                continue
            }
            guard recs[id] == nil else { continue }
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
            var newWorks = Self.newlyPostedWorks(in: result.works, known: known)
            var undated: Set<Int> = []
            if known.isEmpty {
                (newWorks, undated) = await worksPostedSinceFollow(result.works, followedAt: author.followedAt)
            }
            if !newWorks.isEmpty {
                await postNewWorkNotification(
                    author: author,
                    newWorks: newWorks
                )
                notifyCount = newWorks.count
            }
            author.knownWorkIds = Array(known.union(latestIds).subtracting(undated))
            return notifyCount
        } catch {
            logger.warning("Skipping author \(author.username, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    /// No baseline: Follow was tapped before the author's list loaded (or
    /// they had no public works yet), so nothing on page 1 is known. A work
    /// last updated well before the follow was already there. A later one may
    /// be new or an old work that got a chapter, so its work page's published
    /// date decides: one request for each. AO3 dates are days, shown to guests
    /// in UTC, so "later" starts the day before the follow day: a work posted
    /// just after a follow east of UTC can carry the previous date. The cost is
    /// at worst an alert for a work posted shortly before the follow.
    ///
    /// Works that couldn't be dated (an error page, or the poll ran out of
    /// time) come back in `undated` and stay out of the baseline. Once the
    /// rest is the baseline, the next poll judges them by the id rule in
    /// `newlyPostedWorks`; with nothing dated, the next poll dates them again.
    private func worksPostedSinceFollow(
        _ works: [AO3WorkSummary],
        followedAt: Date
    ) async -> (posted: [AO3WorkSummary], undated: Set<Int>) {
        let calendar = Calendar.current
        let followDay = calendar.startOfDay(for: followedAt)
        let since = calendar.date(byAdding: .day, value: -1, to: followDay) ?? followDay
        var posted: [AO3WorkSummary] = []
        var undated: Set<Int> = []
        for work in works {
            guard let updatedAt = work.updatedAt, updatedAt >= since else { continue }
            if Task.isCancelled {
                undated.insert(work.id)
                continue
            }
            do {
                let meta = try await client.fetchWorkMetadata(id: work.id)
                if let publishedAt = meta.publishedAt {
                    if publishedAt >= since { posted.append(work) }
                } else {
                    undated.insert(work.id)
                }
            } catch {
                logger.warning("Couldn't date work \(work.id): \(error.localizedDescription, privacy: .public)")
                undated.insert(work.id)
            }
        }
        return (posted, undated)
    }

    /// Run a saved search with alerts on, newest posted first (one throttled
    /// request), and alert for works posted since its baseline. The first
    /// check after alerts go on only takes the baseline. Only a check that
    /// reads the results counts as one (`alertsLastCheckedAt`): one that's cut
    /// off, fails, comes back stale or gets a guest page leaves the baseline
    /// and the last check alone.
    func checkSavedSearch(_ search: SavedSearch) async -> Int {
        let name = search.name
        let prompt = search.prompt
        let changedAt = search.alertsChangedAt
        let checkedBefore = search.alertsLastCheckedAt
        let filters = SavedSearchAlerts.filters(prompt: prompt)
        search.alertsAttemptedAt = .now
        // Saved so the re-read below sees this search even when it was just
        // inserted and not saved yet.
        try? context.save()
        let result: AO3SearchResults
        do {
            result = try await client.search(filters: filters, page: 1)
        } catch {
            logger.warning("Skipping saved search \(name, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return 0
        }
        // An AO3 search can take half a minute: if the search was deleted,
        // edited or its alerts switched (off, or off and on again) meanwhile,
        // these results are stale. The background refresh has its own
        // context, so the search is read again from the store, where the
        // Search tab's edits are.
        guard isCurrent(search, name: name, prompt: prompt, changedAt: changedAt) else { return 0 }
        // Signed in but served the guest page: the session expired, and the
        // results leave out restricted works. Recording them would mark the
        // public ones seen ahead of the restricted ones, which then never alert.
        if username != nil, result.servedAsGuest {
            logger.warning("Saved search \(name, privacy: .private) came back as a guest page: the AO3 session expired")
            return 0
        }
        let fresh = SavedSearchAlerts.newMatches(
            in: result.works,
            known: Set(search.alertKnownWorkIds),
            baselined: search.alertsBaselineAt != nil,
            lastCheckedAt: checkedBefore
        )
        if search.alertsBaselineAt == nil { search.alertsBaselineAt = .now }
        search.alertKnownWorkIds = SavedSearchAlerts.baseline(search.alertKnownWorkIds, adding: result.works.map(\.id))
        search.alertsLastCheckedAt = .now
        guard !fresh.isEmpty else { return 0 }
        // The same rules as the results list: hidden works, blocked tags
        // and authors (except ones the search names) and, when that setting is
        // on, Mature and Explicit works never alert.
        let shown = visible(fresh, searchedWith: filters)
        guard !shown.isEmpty else { return 0 }
        let alreadyNew = Set(search.alertNewWorkIds)
        search.alertNewWorkIds += shown.map(\.id).filter { !alreadyNew.contains($0) }
        await postSavedSearchNotification(search: search, newWorks: shown)
        return shown.count
    }

    /// Whether `search` still exists with the prompt and alert switch a check
    /// started with, both in this context and in the store.
    private func isCurrent(_ search: SavedSearch, name: String, prompt: String, changedAt: Date?) -> Bool {
        guard search.modelContext != nil, !search.isDeleted else { return false }
        let descriptor = FetchDescriptor<SavedSearch>(predicate: #Predicate { $0.name == name })
        guard let stored = (try? ModelContext(context.container).fetch(descriptor))?.first else { return false }
        return stored.alertsEnabled && stored.prompt == prompt && Self.sameMoment(stored.alertsChangedAt, changedAt)
            && search.alertsEnabled && search.prompt == prompt && Self.sameMoment(search.alertsChangedAt, changedAt)
    }

    /// Dates equal to the millisecond, as a store round trip may round them.
    private static func sameMoment(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): abs(a.timeIntervalSince(b)) < 0.001
        default: false
        }
    }

    private func visible(_ works: [AO3WorkSummary], searchedWith filters: AO3SearchFilters) -> [AO3WorkSummary] {
        let hidden = (try? context.fetch(FetchDescriptor<HiddenWork>())) ?? []
        let blocked = (try? context.fetch(FetchDescriptor<BlockedTerm>())) ?? []
        let filterMature = UserDefaults.standard.object(forKey: ContentControl.filterMatureKey) as? Bool ?? true
        return ContentFilter.apply(works, hiddenIds: HiddenWorkStore.ids(hidden), filterMature: filterMature,
                                   blocklist: Blocklist(blocked).lifting(filters))
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

    /// At most `SavedSearchAlerts.maxAlertingSearches`, the most recently
    /// switched on first: a backup merge can bring in more than this device
    /// lets the reader switch on, and each one costs an AO3 search per poll.
    private func alertingSearches() -> [SavedSearch] {
        let descriptor = FetchDescriptor<SavedSearch>(predicate: #Predicate { $0.alertsEnabled == true })
        let searches = (try? context.fetch(descriptor)) ?? []
        return Array(searches
            .sorted { ($0.alertsChangedAt ?? .distantPast) > ($1.alertsChangedAt ?? .distantPast) }
            .prefix(SavedSearchAlerts.maxAlertingSearches))
    }

    private func postSavedSearchNotification(search: SavedSearch, newWorks: [AO3WorkSummary]) async {
        let content = Self.savedSearchContent(searchName: search.name, prompt: search.prompt, newWorks: newWorks)
        let request = UNNotificationRequest(
            identifier: "search-\(search.name)-new-\(newWorks.map(\.id).max() ?? 0)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
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
    /// restricted work a guest page left out. Empty with no baseline: the
    /// poller dates those works instead (`worksPostedSinceFollow`), so a first
    /// poll never alerts for the whole back catalogue. Internal for tests.
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

    /// New fics for a saved search. One opens that work; several open the
    /// search's results, newest posted first. Internal for tests.
    nonisolated static func savedSearchContent(
        searchName: String,
        prompt: String,
        newWorks: [AO3WorkSummary]
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = searchName
        if newWorks.count == 1, let work = newWorks.first {
            content.body = "New fic: \(work.title)"
            content.userInfo = NotificationRoute.searchMatch(workId: work.id).userInfo
        } else {
            content.body = "\(newWorks.count) new fics match this search"
            content.userInfo = NotificationRoute.savedSearch(name: searchName, prompt: prompt).userInfo
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
