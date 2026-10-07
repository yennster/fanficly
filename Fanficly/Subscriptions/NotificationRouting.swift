import Foundation
import Observation
import UserNotifications

/// What a tapped poller notification opens. Encoded into the notification's
/// `userInfo` when the poller posts it and decoded when it's tapped, so the
/// payload format lives in one place.
enum NotificationRoute: Hashable, Sendable {
    /// New chapters on a followed or AO3-subscribed work.
    case newChapters(workId: Int)
    /// A followed author posted one new work.
    case newWork(workId: Int)
    /// A followed author posted several new works at once.
    case newWorks(author: AuthorRef)

    private enum Key {
        static let kind = "kind"
        static let workId = "workId"
        static let authorUsername = "authorUsername"
        static let authorName = "authorName"
    }

    private enum Kind: String {
        case newChapters, newWork, newWorks
    }

    /// Property-list values only — the system stores `userInfo` as a plist.
    var userInfo: [AnyHashable: Any] {
        switch self {
        case .newChapters(let workId):
            [Key.kind: Kind.newChapters.rawValue, Key.workId: workId]
        case .newWork(let workId):
            [Key.kind: Kind.newWork.rawValue, Key.workId: workId]
        case .newWorks(let author):
            [Key.kind: Kind.newWorks.rawValue,
             Key.authorUsername: author.username,
             Key.authorName: author.displayName]
        }
    }

    init?(userInfo: [AnyHashable: Any]) {
        let workId = userInfo[Key.workId] as? Int
        switch (userInfo[Key.kind] as? String).flatMap(Kind.init(rawValue:)) {
        case .newWorks:
            guard let username = userInfo[Key.authorUsername] as? String, !username.isEmpty else { return nil }
            let name = (userInfo[Key.authorName] as? String).flatMap { $0.isEmpty ? nil : $0 }
            self = .newWorks(author: AuthorRef(username: username, displayName: name ?? username))
        case .newWork:
            guard let workId else { return nil }
            self = .newWork(workId: workId)
        case .newChapters, nil:
            // No kind: posted before taps were routed, when chapter alerts and
            // single new works both carried just the work id.
            guard let workId else { return nil }
            self = .newChapters(workId: workId)
        }
    }

    var workId: Int? {
        switch self {
        case .newChapters(let workId), .newWork(let workId): workId
        case .newWorks: nil
        }
    }

    /// The tab to open beneath the screen when no tab is showing yet (the
    /// iPhone sidebar menu, e.g. after a cold launch), so Back lands somewhere
    /// related: chapter alerts for a saved work in the Library, for a work only
    /// subscribed to on AO3 in Subscriptions; author news in Followed Authors.
    func landingTab(workIsSaved: Bool) -> SidebarItem {
        switch self {
        case .newChapters: workIsSaved ? .library : .subscriptions
        case .newWork, .newWorks: .authors
        }
    }
}

/// Hands a tapped notification's route from the system delegate to `RootView`.
/// A tap that cold-launches the app can arrive before RootView exists, so the
/// route waits here until RootView takes it.
@MainActor @Observable
final class NotificationRouter {
    static let shared = NotificationRouter()
    var pendingRoute: NotificationRoute?
}

/// `UNUserNotificationCenter` delegate that turns a notification tap into a
/// `NotificationRoute`. Without one, iOS just foregrounds the app.
final class NotificationTapHandler: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationTapHandler()

    /// Call from `FanficlyApp.init()`: the delegate must be set before
    /// `application(_:didFinishLaunchingWithOptions:)` returns, or the tap that
    /// launched the app is never delivered. `delegate` is weak; `shared` keeps
    /// the handler alive.
    @MainActor
    static func install() {
        UNUserNotificationCenter.current().delegate = shared
    }

    /// Called off the main actor: decode the payload into a Sendable route
    /// here, then hop to the main actor with only that.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let route = NotificationRoute(userInfo: response.notification.request.content.userInfo) {
            Task { @MainActor in NotificationRouter.shared.pendingRoute = route }
        }
        completionHandler()
    }
}
