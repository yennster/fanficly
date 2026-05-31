import SwiftUI
import SwiftData

@main
struct FanficlyApp: App {
    private let client: AO3Client = AO3Client()
    @State private var auth = AuthState()
    @Environment(\.scenePhase) private var scenePhase

    private static let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Work.self,
            Chapter.self,
            TagRecord.self,
            BookmarkRecord.self,
            SubscriptionRecord.self,
            SavedSearch.self,
            ReadingProgress.self,
            SavedFilter.self,
        ])
        return try! ModelContainer(for: schema)
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.ao3Client, client)
                .environment(auth)
        }
        .modelContainer(Self.sharedModelContainer)
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            BackgroundRefresh.scheduleNext()
            await BackgroundRefresh.runPoll(client: client, container: Self.sharedModelContainer)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                BackgroundRefresh.scheduleNext()
            }
        }
    }
}
