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

    init() {
        if Self.isDemoMode {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: "reader.theme")
            defaults.removeObject(forKey: "reader.fontFamily")
            defaults.removeObject(forKey: "reader.width")
            defaults.removeObject(forKey: "reader.mode")
            defaults.removeObject(forKey: "reader.fontSizePt")
            defaults.removeObject(forKey: "reader.lineSpacingPt")
            defaults.removeObject(forKey: "reader.paragraphSpacingPt")
            defaults.removeObject(forKey: "reader.pageTurnHaptics")
            defaults.removeObject(forKey: "reader.pageTurnAnimations")
            defaults.removeObject(forKey: "settings.iCloudSyncEnabled")
        }
    }

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
            CustomFolder.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: isDemoMode, cloudKitDatabase: .none)
        return try! ModelContainer(for: schema, configurations: config)
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.ao3Client, client)
                .environment(auth)
                .task {
                    let iCloudEnabled = UserDefaults.standard.bool(forKey: "settings.iCloudSyncEnabled")
                    if iCloudEnabled && !Self.isDemoMode {
                        let context = Self.sharedModelContainer.mainContext
                        let worksCount = (try? context.fetchCount(FetchDescriptor<Work>())) ?? 0
                        if worksCount == 0 && iCloudSyncManager.shared.isBackupAvailable {
                            await iCloudSyncManager.shared.restoreFromiCloud(context: context)
                        }
                    }
                }
        }
        .modelContainer(Self.sharedModelContainer)
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            BackgroundRefresh.scheduleNext()
            await BackgroundRefresh.runPoll(client: client, container: Self.sharedModelContainer)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                BackgroundRefresh.scheduleNext()
                
                let iCloudEnabled = UserDefaults.standard.bool(forKey: "settings.iCloudSyncEnabled")
                if iCloudEnabled && !Self.isDemoMode {
                    iCloudSyncManager.shared.backupToiCloud(context: Self.sharedModelContainer.mainContext)
                }
            }
        }
    }
}
