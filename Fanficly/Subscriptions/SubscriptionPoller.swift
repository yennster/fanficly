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
        for rec in existing where !freshKeys.contains(rec.key) {
            context.delete(rec)
        }
        try? context.save()
        return fresh
    }

    func checkForNewChapters() async -> Int {
        var notifyCount = 0
        let descriptor = FetchDescriptor<SubscriptionRecord>(
            predicate: #Predicate { $0.kind == "work" }
        )
        let workSubs = (try? context.fetch(descriptor)) ?? []
        for rec in workSubs {
            let parts = rec.key.split(separator: ":")
            guard parts.count == 2, let workId = Int(parts[1]) else { continue }
            do {
                let meta = try await client.fetchWorkMetadata(id: workId)
                if let lastSeen = rec.lastSeenChapterCount,
                   meta.chapterCount > lastSeen {
                    await postNewChapterNotification(
                        title: rec.displayName,
                        oldCount: lastSeen,
                        newCount: meta.chapterCount,
                        workId: workId
                    )
                    notifyCount += 1
                }
                rec.lastSeenChapterCount = meta.chapterCount
                rec.lastCheckedAt = .now
            } catch {
                logger.warning("Skipping work \(workId): \(error.localizedDescription, privacy: .public)")
            }
        }
        try? context.save()
        return notifyCount
    }

    /// Poll locally-followed works (no AO3 login required) for new chapters.
    func checkFollowedWorks() async -> Int {
        var notifyCount = 0
        let descriptor = FetchDescriptor<Work>(predicate: #Predicate { $0.isFollowed == true })
        let followed = (try? context.fetch(descriptor)) ?? []
        for work in followed {
            do {
                let meta = try await client.fetchWorkMetadata(id: work.ao3Id)
                if let lastSeen = work.lastSeenChapterCount, meta.chapterCount > lastSeen {
                    await postNewChapterNotification(
                        title: work.title,
                        oldCount: lastSeen,
                        newCount: meta.chapterCount,
                        workId: work.ao3Id
                    )
                    notifyCount += 1
                }
                work.lastSeenChapterCount = meta.chapterCount
            } catch {
                logger.warning("Skipping followed work \(work.ao3Id): \(error.localizedDescription, privacy: .public)")
            }
        }
        try? context.save()
        return notifyCount
    }

    /// Poll locally-followed authors (no AO3 login required) for newly
    /// published works, notifying once per new work.
    func checkFollowedAuthors() async -> Int {
        var notifyCount = 0
        let descriptor = FetchDescriptor<FollowedAuthor>()
        let authors = (try? context.fetch(descriptor)) ?? []
        for author in authors where !author.username.isEmpty {
            do {
                let result = try await client.fetchAuthorWorks(username: author.username, page: 1)
                let latestIds = result.works.map(\.id)
                let known = Set(author.knownWorkIds)
                // Only notify once we have a baseline — a freshly-followed
                // author is seeded at follow time, but guard the empty case so
                // a first poll never alerts for the whole back catalogue.
                if !known.isEmpty {
                    let newWorks = result.works.filter { !known.contains($0.id) }
                    if !newWorks.isEmpty {
                        await postNewWorkNotification(
                            author: author.displayName,
                            newWorks: newWorks
                        )
                        notifyCount += newWorks.count
                    }
                }
                author.knownWorkIds = Array(known.union(latestIds))
                author.lastCheckedAt = .now
            } catch {
                logger.warning("Skipping author \(author.username, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        try? context.save()
        return notifyCount
    }

    func runFullPoll() async -> Int {
        do {
            _ = try await syncSubscriptionList()
        } catch {
            logger.warning("Subscriptions list fetch failed: \(error.localizedDescription, privacy: .public)")
        }
        var total = 0
        if username != nil {
            total += await checkForNewChapters()
        }
        total += await checkFollowedWorks()
        total += await checkFollowedAuthors()
        WidgetDataStore.updateAll(context: context)
        return total
    }

    private func postNewWorkNotification(author: String, newWorks: [AO3WorkSummary]) async {
        let content = UNMutableNotificationContent()
        content.title = author
        if newWorks.count == 1, let work = newWorks.first {
            content.body = "New work: \(work.title)"
            content.userInfo = ["workId": work.id]
        } else {
            content.body = "\(newWorks.count) new works posted"
        }
        content.sound = .default
        let newestId = newWorks.first?.id ?? 0
        let request = UNNotificationRequest(
            identifier: "author-\(author)-newwork-\(newestId)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func postNewChapterNotification(title: String, oldCount: Int, newCount: Int, workId: Int) async {
        let content = UNMutableNotificationContent()
        content.title = title
        let added = newCount - oldCount
        content.body = added == 1
            ? "1 new chapter posted (\(newCount) total)"
            : "\(added) new chapters posted (\(newCount) total)"
        content.sound = .default
        content.userInfo = ["workId": workId]
        let request = UNNotificationRequest(
            identifier: "work-\(workId)-update-\(newCount)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
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
}
