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
        // Before launch finishes, so a tap that cold-launches the app still
        // opens the work/author it's about.
        NotificationTapHandler.install()

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
            // Recent searches and the Library sort persist across launches;
            // clear them so every demo run (screenshots, previews) starts
            // from the same defaults.
            defaults.removeObject(forKey: RecentSearches.storageKey)
            defaults.removeObject(forKey: LibrarySort.keyStorageKey)
            defaults.removeObject(forKey: LibrarySort.ascendingStorageKey)
            
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
            ReadingStat.self,
            BlockedTerm.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: isDemoMode, cloudKitDatabase: .none)
        return try! ModelContainer(for: schema, configurations: config)
    }()

    @AppStorage(ReaderProfile.deviceKey("reader.theme")) private var themeRaw: String = ReaderTheme.system.rawValue
    @AppStorage(ReaderProfile.deviceKey("reader.mode")) private var modeRaw: String = ReadingMode.continuous.rawValue
    @AppStorage("app.zoomScale") private var zoomScale: Double = UIZoom.actualSize
    @AppStorage(ReaderProfile.deviceKey("reader.fontSizePt")) private var fontSizePt: Double = ReaderMetrics.defaultFontSize

    var body: some Scene {
        WindowGroup {
            RootView()
                .readingSpeedFromStats()
                .environment(\.ao3Client, client)
                .environment(auth)
                // Screenshots use the standard system blue accent (cleaner for
                // the App Store) rather than the app's indigo brand tint, and
                // force light mode so they're deterministic regardless of the
                // simulator's appearance. Demo mode only — the shipped app keeps
                // its indigo AccentColor and follows the system light/dark setting.
                .tint(Self.isDemoMode ? Color.blue : nil)
                .preferredColorScheme(Self.isDemoMode ? .light : nil)
                .task {
                    // Demo mode: present a signed-in state so the login-gated
                    // screens (Bookmarks tab, the comment composer) render with
                    // the curated offline data for App Store screenshots. The
                    // DemoAO3Client serves all of this offline. Never ships.
                    if Self.isDemoMode { auth.username = "demo_reader" }

                    // Older builds stored the email address a reader signed
                    // in with; swap it for the AO3 login name (#144) before a
                    // restored Bookmarks or Subscriptions screen loads with it.
                    // Costs a request only when an email is stored.
                    if !Self.isDemoMode {
                        await auth.repairStoredLogin(using: client)
                    }

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

                    // One-time: drop login or error pages older builds saved
                    // as EPUBs, so those works stop showing as Downloaded.
                    if !Self.isDemoMode {
                        WorkPersistence.removeInvalidEPUBsIfNeeded()
                    }

                    let iCloudEnabled = UserDefaults.standard.bool(forKey: "settings.iCloudSyncEnabled")
                    if iCloudEnabled && !Self.isDemoMode {
                        let sync = iCloudSyncManager.shared
                        // Adopt the newest cloud backup automatically, not just
                        // on an empty library: restore is a conservative merge
                        // (positions and flags only advance, chapters only
                        // grow), so pulling at every launch is safe and keeps
                        // iPhone and Mac in step without a manual Restore. The
                        // stamp skips the work when the cloud file is unchanged
                        // since this device last applied or wrote it.
                        if sync.isBackupAvailable && sync.cloudBackupHasUnappliedChanges {
                            if await sync.restoreFromiCloud(context: context) {
                                RestoreDownloadCenter.shared.proposeRedownload(context: context)
                            }
                        }
                    }

                    // One-time: seed Stats from reading history that predates the
                    // feature (and any history just restored from iCloud) so the
                    // Stats tab isn't empty for existing readers. Runs after the
                    // restore above; demo mode seeds its own stats.
                    if !Self.isDemoMode {
                        ReadingStatsBackfill.runIfNeeded(in: context)
                        // One-time: index works saved before every library work
                        // was indexed (only followed ones were). Not every launch:
                        // a rebuild empties Fanficly's Spotlight results while
                        // it runs and drops what Spotlight learned about them.
                        if !UserDefaults.standard.bool(forKey: WorkPersistence.spotlightReindexedKey) {
                            WorkPersistence.reindexLibrary(context: context)
                            UserDefaults.standard.set(true, forKey: WorkPersistence.spotlightReindexedKey)
                        }
                    }
                }
        }
        .modelContainer(Self.sharedModelContainer)
        .commands {
            SidebarCommands()

            // In the system View menu, after Show/Hide Sidebar. ⌘+ / ⌘− are
            // the reader's text size (the Reader menu). RootView keeps the
            // other spellings of these keys (⇧⌘=, ⇧⌘_) as hidden shortcuts,
            // since a menu item shows only one.
            CommandGroup(after: .sidebar) {
                Divider()

                Button("Zoom In") {
                    zoomScale = UIZoom.stepped(zoomScale, in: true)
                }
                .keyboardShortcut("+", modifiers: [.command, .shift])

                Button("Zoom Out") {
                    zoomScale = UIZoom.stepped(zoomScale, in: false)
                }
                .keyboardShortcut("-", modifiers: [.command, .shift])

                Button("Actual Size") {
                    zoomScale = UIZoom.actualSize
                }
                .keyboardShortcut("0", modifiers: [.command])
            }

            GoCommands()

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

                Divider()

                // The same text size the Aa menu and Settings → Reader set on
                // this device. Bigger Text is ⌘=, not ⌘+: on a US layout ⌘+ is
                // typed as ⇧⌘=, which is Zoom In's key, so "+" here would
                // claim the same keystroke as Zoom In.
                Button("Bigger Text") {
                    fontSizePt = ReaderMetrics.steppedFontSize(fontSizePt, bigger: true)
                }
                .keyboardShortcut("=", modifiers: [.command])

                Button("Smaller Text") {
                    fontSizePt = ReaderMetrics.steppedFontSize(fontSizePt, bigger: false)
                }
                .keyboardShortcut("-", modifiers: [.command])
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
                    // The snapshot and a background-task assertion now, the
                    // write off the main actor; it leaves the file alone when
                    // nothing changed, so backgrounding doesn't re-upload the
                    // library every time (#137).
                    iCloudSyncManager.shared.startBackgroundBackup(context: Self.sharedModelContainer.mainContext)
                }
            }
        }
    }
}

/// The Go menu. Each item switches tabs through `RootView`'s own `select(_:)`,
/// as a sidebar click does, so it also clears what's pushed on the old tab;
/// setting `app.selectedTabRaw` alone left the reader (or any other pushed
/// screen) on top of the new tab. Through a focused scene value, so with two
/// windows open it acts on the one in front.
private struct GoCommands: Commands {
    @FocusedValue(\.selectTab) private var selectTab

    var body: some Commands {
        CommandMenu("Go") {
            item(.search, key: "1")
            item(.browse, key: "2")
            item(.popular, key: "3")
            item(.library, key: "4")
            item(.recentlyViewed, key: "5")
            item(.authors, key: "6")
            item(.bookmarks, key: "7")
            // ⌘1–⌘9 are all taken, so these two have no ⌘-number shortcut
            // (the Windows app's Ctrl+number list matches).
            item(.markedForLater, key: nil)
            item(.ao3History, key: nil)
            item(.subscriptions, key: "8")
            item(.stats, key: "9")
            item(.settings, key: ",")
        }
    }

    @ViewBuilder
    private func item(_ tab: SidebarItem, key: KeyEquivalent?) -> some View {
        let button = Button(tab.title) { selectTab?(tab) }
            .disabled(selectTab == nil)
        if let key {
            button.keyboardShortcut(key, modifiers: [.command])
        } else {
            button
        }
    }
}
