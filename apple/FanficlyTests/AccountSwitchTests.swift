import XCTest
import SwiftData
@testable import Fanficly

/// Switching AO3 accounts (#159): signing out, or signing in as someone else,
/// forgets the previous account's subscriptions and list-sync stamps, and a
/// list that was still on its way when the account changed is dropped.
@MainActor
private final class Counter {
    var count = 0
}

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
}
