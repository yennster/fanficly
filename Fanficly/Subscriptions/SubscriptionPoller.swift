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
        return total
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
