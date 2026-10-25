import SwiftUI
import SwiftData

/// Subscribes to a work on AO3 from its options menu (login-gated), the way
/// Windows' "Subscribe on AO3" does. The screen owns it, like `KudosGiver`, so
/// the result alert has a live anchor after the menu closes. The POST is never
/// retried. A subscription AO3 confirms is mirrored into a local
/// `SubscriptionRecord` whose baseline is today's chapter count, so the poller
/// only alerts for chapters posted after this.
@Observable @MainActor
final class WorkSubscriber {
    var isSending = false
    var isSubscribed = false
    /// The alert after a tap: the confirmation or why it failed.
    var result: (title: String, message: String)?
    /// AO3 sent the login page; the screen marks `AuthState` (#131) and resets it.
    var sessionExpired = false

    static func key(workId: Int) -> String { "\(AO3Subscription.Kind.work.rawValue):\(workId)" }

    func refresh(workId: Int, in context: ModelContext) {
        isSubscribed = Self.record(workId: workId, in: context) != nil
    }

    func subscribe(workId: Int, title: String, author: String, chapterCount: Int,
                   username: String?, client: any AO3ClientProtocol, context: ModelContext) async {
        guard username != nil, !isSending, !isSubscribed else { return }
        isSending = true
        defer { isSending = false }
        do {
            try await client.subscribeToWork(workId: workId)
            if Self.record(workId: workId, in: context) == nil {
                let record = SubscriptionRecord(key: Self.key(workId: workId), kind: AO3Subscription.Kind.work.rawValue,
                                                displayName: title, authorName: author)
                record.lastSeenChapterCount = chapterCount
                context.insert(record)
                try? context.save()
            }
            isSubscribed = true
            result = (title: "Subscribed on AO3", message: "AO3 will email you when this work updates.")
        } catch AO3Error.unauthorized {
            sessionExpired = true
            result = (title: "Couldn't subscribe", message: "Your AO3 login has expired. Log in again in Settings → AO3 Login, then try again.")
        } catch AO3Error.subscribeRejected(let message) {
            result = (title: "Couldn't subscribe", message: message)
        } catch AO3Error.rateLimited {
            result = (title: "Couldn't subscribe", message: "AO3 is asking us to slow down. Try again in a few minutes.")
        } catch AO3Error.http(let status) {
            result = (title: "Couldn't subscribe", message: "AO3 returned HTTP \(status). Try again later.")
        } catch AO3Error.network(let underlying) {
            result = (title: "Couldn't subscribe", message: "Network: \(underlying). If the request reached AO3, you may already be subscribed; check your Subscriptions page before trying again.")
        } catch {
            result = (title: "Couldn't subscribe", message: "\(error)")
        }
    }

    private static func record(workId: Int, in context: ModelContext) -> SubscriptionRecord? {
        let key = Self.key(workId: workId)
        var descriptor = FetchDescriptor<SubscriptionRecord>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}

/// The "Subscribe on AO3" item for a work's options menu. Pass the screen's
/// `WorkSubscriber` and attach `.subscribePresentation(_:workId:)` to the screen.
struct SubscribeMenuButton: View {
    @Environment(\.ao3Client) private var client
    @Environment(\.modelContext) private var context
    @Environment(AuthState.self) private var auth
    let workId: Int
    let title: String
    let author: String
    let chapterCount: Int
    let subscriber: WorkSubscriber

    var body: some View {
        Button {
            let client = client
            let username = auth.username
            Task {
                await subscriber.subscribe(workId: workId, title: title, author: author, chapterCount: chapterCount,
                                           username: username, client: client, context: context)
            }
        } label: {
            if subscriber.isSending {
                Label("Subscribing…", systemImage: "bell")
            } else if subscriber.isSubscribed {
                Label("Subscribed on AO3", systemImage: "bell.fill")
            } else if auth.username == nil {
                Label("Log In to Subscribe on AO3", systemImage: "bell")
            } else {
                Label("Subscribe on AO3", systemImage: "bell")
            }
        }
        .disabled(subscriber.isSending || subscriber.isSubscribed || auth.username == nil)
    }
}

private struct SubscribePresentation: ViewModifier {
    @Environment(AuthState.self) private var auth
    @Environment(\.modelContext) private var context
    @Bindable var subscriber: WorkSubscriber
    let workId: Int

    func body(content: Content) -> some View {
        content
            .onAppear { subscriber.refresh(workId: workId, in: context) }
            .onChange(of: subscriber.sessionExpired) { _, expired in
                guard expired else { return }
                auth.markSessionExpired()
                subscriber.sessionExpired = false
            }
            .alert(subscriber.result?.title ?? "", isPresented: Binding(
                get: { subscriber.result != nil },
                set: { if !$0 { subscriber.result = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(subscriber.result?.message ?? "")
            }
    }
}

extension View {
    /// Loads whether the work is already subscribed and presents a
    /// `WorkSubscriber`'s result. Attach to the screen view that owns the
    /// subscriber, never inside `Menu` content.
    func subscribePresentation(_ subscriber: WorkSubscriber, workId: Int) -> some View {
        modifier(SubscribePresentation(subscriber: subscriber, workId: workId))
    }
}
