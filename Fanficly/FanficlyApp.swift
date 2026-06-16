import SwiftUI
import SwiftData

@main
struct FanficlyApp: App {
    /// True when launched for App Store screenshots / manual demos. Swaps in a
    /// fully offline, curated, all-ages client and an in-memory store so nothing
    /// touches the network or real storage. See `DemoAO3Client` / `DemoSeed`.
    static var isDemoMode: Bool { ProcessInfo.processInfo.arguments.contains("-demoMode") }
    static var isTestMode: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    private let client: any AO3ClientProtocol = FanficlyApp.isDemoMode ? DemoAO3Client() : AO3Client()
    @State private var auth = AuthState()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        if Self.isDemoMode {
            let defaults = UserDefaults.standard
            let demoReaderWidthKey = ReaderProfile.deviceKey("reader.widthPercent")
            defaults.removeObject(forKey: "reader.theme")
            defaults.removeObject(forKey: "reader.fontFamily")
            defaults.removeObject(forKey: "reader.width")
            defaults.removeObject(forKey: "reader.widthPercent")
            defaults.removeObject(forKey: "reader.mode")
            defaults.removeObject(forKey: "reader.fontSizePt")
            defaults.removeObject(forKey: "reader.lineSpacingPt")
            defaults.removeObject(forKey: "reader.paragraphSpacingPt")
            defaults.removeObject(forKey: "reader.pageTurnHaptics")
            defaults.removeObject(forKey: "reader.pageTurnAnimations")
            defaults.removeObject(forKey: "settings.iCloudSyncEnabled")
            
            // Clean up device-specific keys too
            let deviceKeys = [
                ReaderProfile.deviceKey("reader.theme"),
                ReaderProfile.deviceKey("reader.fontFamily"),
                demoReaderWidthKey,
                ReaderProfile.deviceKey("reader.mode"),
                ReaderProfile.deviceKey("reader.fontSizePt"),
                ReaderProfile.deviceKey("reader.lineSpacingPt"),
                ReaderProfile.deviceKey("reader.paragraphSpacingPt"),
                ReaderProfile.deviceKey("reader.pageTurnHaptics"),
                ReaderProfile.deviceKey("reader.pageTurnAnimations")
            ]
            for key in deviceKeys {
                defaults.removeObject(forKey: key)
            }
            
            #if !targetEnvironment(macCatalyst)
            if UIDevice.current.userInterfaceIdiom == .phone {
                defaults.set(90.0, forKey: demoReaderWidthKey)
            }
            #endif
        } else if !Self.isTestMode {
            WidgetProgressStore.installCloudSyncObserver()
            ReaderProfileSyncStore.installCloudSyncObserver()
            StreakStore.installCloudSyncObserver()
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
            FollowedAuthor.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: isDemoMode, cloudKitDatabase: .none)
        return try! ModelContainer(for: schema, configurations: config)
    }()

    @AppStorage("app.selectedTabRaw") private var selectedTabRaw: String = "search"
    @AppStorage(ReaderProfile.deviceKey("reader.theme")) private var themeRaw: String = ReaderTheme.system.rawValue
    @AppStorage(ReaderProfile.deviceKey("reader.mode")) private var modeRaw: String = ReadingMode.continuous.rawValue

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.ao3Client, client)
                .environment(auth)
                // Screenshots use the standard system blue accent (cleaner for
                // the App Store) rather than the app's maroon brand tint, and
                // force light mode so they're deterministic regardless of the
                // simulator's appearance. Demo mode only — the shipped app keeps
                // its maroon AccentColor and follows the system light/dark setting.
                .tint(Self.isDemoMode ? Color.blue : nil)
                .preferredColorScheme(Self.isDemoMode ? .light : nil)
                .task {
                    let context = Self.sharedModelContainer.mainContext
                    
                    // Migrate legacy single folder to folders array if needed
                    if let works = try? context.fetch(FetchDescriptor<Work>()) {
                        var migratedAny = false
                        for work in works {
                            if let legacyFolder = work.folder {
                                if !work.folders.contains(where: { $0.name == legacyFolder.name }) {
                                    work.folders.append(legacyFolder)
                                }
                                work.folder = nil
                                migratedAny = true
                            }
                        }
                        if migratedAny {
                            try? context.save()
                        }
                    }

                    let iCloudEnabled = UserDefaults.standard.bool(forKey: "settings.iCloudSyncEnabled")
                    if iCloudEnabled && !Self.isDemoMode {
                        let worksCount = (try? context.fetchCount(FetchDescriptor<Work>())) ?? 0
                        if worksCount == 0 && iCloudSyncManager.shared.isBackupAvailable {
                            await iCloudSyncManager.shared.restoreFromiCloud(context: context)
                        }
                    }
                }
        }
        .modelContainer(Self.sharedModelContainer)
        .commands {
            SidebarCommands()
            
            CommandMenu("Go") {
                Button("Search") {
                    selectedTabRaw = SidebarItem.search.rawValue
                }
                .keyboardShortcut("1", modifiers: [.command])
                
                Button("Browse") {
                    selectedTabRaw = SidebarItem.browse.rawValue
                }
                .keyboardShortcut("2", modifiers: [.command])
                
                Button("Library") {
                    selectedTabRaw = SidebarItem.library.rawValue
                }
                .keyboardShortcut("3", modifiers: [.command])
                
                Button("Recently Viewed") {
                    selectedTabRaw = SidebarItem.recentlyViewed.rawValue
                }
                .keyboardShortcut("4", modifiers: [.command])

                Button("Authors") {
                    selectedTabRaw = SidebarItem.authors.rawValue
                }
                .keyboardShortcut("5", modifiers: [.command])

                Button("Bookmarks") {
                    selectedTabRaw = SidebarItem.bookmarks.rawValue
                }
                .keyboardShortcut("6", modifiers: [.command])

                Button("Subscriptions") {
                    selectedTabRaw = SidebarItem.subscriptions.rawValue
                }
                .keyboardShortcut("7", modifiers: [.command])

                Button("Settings") {
                    selectedTabRaw = SidebarItem.settings.rawValue
                }
                .keyboardShortcut("8", modifiers: [.command])
            }
            
            CommandMenu("Reader") {
                Menu("Reading Mode") {
                    ForEach(ReadingMode.allCases) { mode in
                        Button(action: {
                            modeRaw = mode.rawValue
                        }) {
                            HStack {
                                Text(mode.displayName)
                                if modeRaw == mode.rawValue {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                
                Menu("Theme") {
                    ForEach(ReaderTheme.allCases) { theme in
                        Button(action: {
                            themeRaw = theme.rawValue
                        }) {
                            HStack {
                                Text(theme.displayName)
                                if themeRaw == theme.rawValue {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        }
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
