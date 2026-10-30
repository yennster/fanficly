import XCTest
import SwiftData
@testable import Fanficly

@MainActor
private final class Counter {
    var count = 0
}

/// Switching AO3 accounts (#159): signing out, or signing in as someone else,
/// forgets the previous account's subscriptions and list-sync stamps, and a
/// list that was still on its way when the account changed is dropped.
@MainActor
final class AccountSwitchTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([
            Work.self, Chapter.self, TagRecord.self, BookmarkRecord.self,
            SubscriptionRecord.self, SavedSearch.self, ReadingProgress.self,
            RecentlyViewed.self, CustomFolder.self, FollowedAuthor.self,
            ReadingStat.self, BlockedTerm.self, HiddenWork.self, SavedFilter.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return ModelContext(try ModelContainer(for: schema, configurations: [config]))
    }

    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.accountSwitch.\(UUID().uuidString)")!
    }

    func test_logout_forgetsTheAccount() async {
        let forgotten = Counter()
        let auth = AuthState(store: MemoryLoginNameStore("alice"), forgetAccount: { forgotten.count += 1 })
        await auth.logout(using: StubAO3Client())
        XCTAssertNil(auth.username)
        XCTAssertEqual(forgotten.count, 1)
    }

    // The expired-session form lets someone else sign in without logging out.
    func test_signingInAsSomeoneElse_forgetsThePreviousAccount() async {
        let forgotten = Counter()
        let auth = AuthState(store: MemoryLoginNameStore("alice"), forgetAccount: { forgotten.count += 1 })
        await auth.login(using: StubAO3Client(), username: "bob", password: "pw")
        XCTAssertEqual(auth.username, "bob")
        XCTAssertEqual(forgotten.count, 1)
    }

    func test_signingInAgainAsTheSameAccount_keepsItsData() async {
        let forgotten = Counter()
        let auth = AuthState(store: MemoryLoginNameStore("alice"), forgetAccount: { forgotten.count += 1 })
        await auth.login(using: StubAO3Client(), username: "Alice", password: "pw")
        XCTAssertEqual(forgotten.count, 0)
    }

    func test_forget_deletesSubscriptionsAndSyncStamps() async throws {
        let ctx = try makeContext()
        let defaults = scratchDefaults()
        let client = StubAO3Client()
        client.subscriptionsResponse = [AO3Subscription(kind: .work, resourceId: "1", title: "Fic One", author: "carol")]
        let poller = SubscriptionPoller(client: client, context: ctx, username: "alice", defaults: defaults)
        _ = try await poller.syncSubscriptionList()
        defaults.set("kept", forKey: "reader.theme")
        XCTAssertTrue(poller.hasSyncedList)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<SubscriptionRecord>()), 1)

        AccountData.forget(in: ctx, defaults: defaults)

        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<SubscriptionRecord>()), 0)
        XCTAssertFalse(poller.hasSyncedList)
        XCTAssertTrue(poller.listSyncIsDue())
        XCTAssertEqual(defaults.string(forKey: "reader.theme"), "kept")
    }

    // Alice's list arrives after she signed out: it mustn't land under Bob.
    func test_listArrivingAfterTheAccountChanged_isDropped() async throws {
        let ctx = try makeContext()
        let defaults = scratchDefaults()
        let client = StubAO3Client()
        client.subscriptionsResponse = [AO3Subscription(kind: .work, resourceId: "1", title: "Fic One", author: "carol")]
        client.onFetchSubscriptions = { AccountData.forget(in: ctx, defaults: defaults) }
        let poller = SubscriptionPoller(client: client, context: ctx, username: "alice", defaults: defaults)

        let fresh = try await poller.syncSubscriptionList()

        XCTAssertTrue(fresh.isEmpty)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<SubscriptionRecord>()), 0)
        XCTAssertFalse(poller.hasSyncedList)
    }

    // Alice signs out while Refresh checks her subscriptions for new chapters:
    // the check stops and never touches the deleted records.
    func test_chapterCheck_stopsWhenTheAccountChanges() async throws {
        let ctx = try makeContext()
        let defaults = scratchDefaults()
        for id in [1, 2] {
            let rec = SubscriptionRecord(key: "work:\(id)", kind: "work", displayName: "Fic \(id)")
            rec.lastSeenChapterCount = 0   // the stub answers 1 chapter: a new one
            ctx.insert(rec)
        }
        try ctx.save()
        let client = StubAO3Client()
        client.onFetchWorkMetadata = { AccountData.forget(in: ctx, defaults: defaults) }
        let poller = SubscriptionPoller(client: client, context: ctx, username: "alice", defaults: defaults)

        let notified = await poller.checkForNewChapters()

        XCTAssertEqual(notified, 0)
        XCTAssertEqual(client.workMetadataCalls.count, 1)
        XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<SubscriptionRecord>()), 0)
    }

    // The iCloud backup is shared by every device on the Apple ID: another AO3
    // account's subscriptions stay in it but never restore here.
    func test_backedUpSubscriptions_restoreOnlyForTheirAccount() {
        func sub(_ account: String?) -> SubscriptionBackup {
            SubscriptionBackup(key: "work:1", kind: "work", displayName: "Fic", authorName: "",
                               lastSeenChapterCount: 1, lastCheckedAt: nil, account: account)
        }
        XCTAssertTrue(iCloudSyncManager.subscription(sub("alice"), belongsTo: "Alice"))
        XCTAssertFalse(iCloudSyncManager.subscription(sub("alice"), belongsTo: "bob"))
        XCTAssertFalse(iCloudSyncManager.subscription(sub("alice"), belongsTo: nil))
        // From a backup made before subscriptions recorded their account.
        XCTAssertTrue(iCloudSyncManager.subscription(sub(nil), belongsTo: "bob"))
        let merged = iCloudSyncManager.mergedSubscription(local: sub(nil), other: sub("alice"))
        XCTAssertEqual(merged.account, "alice")
    }
}
