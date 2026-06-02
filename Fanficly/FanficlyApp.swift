import SwiftUI
import SwiftData

@main
struct FanficlyApp: App {
    /// True when launched for App Store screenshots / manual demos. Swaps in a
    /// fully offline, curated, all-ages client and an in-memory store so nothing
    /// touches the network or real storage. See `DemoAO3Client` / `DemoSeed`.
    static var isDemoMode: Bool { ProcessInfo.processInfo.arguments.contains("-demoMode") }

    private let client: any AO3ClientProtocol = FanficlyApp.isDemoMode ? DemoAO3Client() : AO3Client()
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
            RecentlyViewed.self,
            HiddenWork.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: isDemoMode)
        return try! ModelContainer(for: schema, configurations: config)
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
