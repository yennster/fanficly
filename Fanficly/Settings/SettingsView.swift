import SwiftUI
import SwiftData

struct SettingsView: View {
    private enum SettingsRoute: Hashable {
        case login
        case reader
        case hiddenWorks
        case contentPolicy
        case privacy
    }

    @Environment(AuthState.self) private var auth
    @Environment(\.modelContext) private var context
    @AppStorage(ContentControl.filterMatureKey) private var filterMature: Bool = true
    @AppStorage("settings.iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = false
    @AppStorage("library.showReadingProgress") private var showReadingProgress = true
    @State private var lastSync: Date? = nil
    @State private var showingRestoreSuccess = false
    @State private var showingRestoreFailure = false
    @State private var isRestoring = false
    private let syncManager = iCloudSyncManager.shared

    /// Pre-filled feedback email (subject percent-encoded so it survives the mailto).
    static let feedbackMailto = URL(
        string: "mailto:jenny+fanficly@jennyplunkett.me?subject=Fanficly%20feedback"
    )!

    var body: some View {
        List {
            Section("Account") {
                NavigationLink(value: SettingsRoute.login) {
                    if let username = auth.username {
                        LabeledContent("AO3 Login", value: username)
                    } else {
                        Text("AO3 Login")
                    }
                }
            }
            Section("Reader") {
                NavigationLink("Theme & typography", value: SettingsRoute.reader)
            }
            Section {
                Toggle("Show reading progress", isOn: $showReadingProgress)
            } header: {
                Text("Library")
            } footer: {
                Text("Shows a progress bar and percentage on works you've started. Your reading position is always saved — this only hides the display.")
            }
            Section("iCloud Sync") {
                Toggle("Sync Library to iCloud", isOn: $iCloudSyncEnabled)
                    .onChange(of: iCloudSyncEnabled) { _, newValue in
                        if newValue {
                            let worksCount = (try? context.fetchCount(FetchDescriptor<Work>())) ?? 0
                            if worksCount == 0 && syncManager.isBackupAvailable {
                                isRestoring = true
                                Task {
                                    let success = await syncManager.restoreFromiCloud(context: context)
                                    isRestoring = false
                                    if success {
                                        lastSync = syncManager.lastBackupDate
                                        showingRestoreSuccess = true
                                    }
                                }
                            }
                        }
                    }
                    .disabled(isRestoring)
                
                if iCloudSyncEnabled {
                    if let date = lastSync {
                        LabeledContent("Last synced", value: date.formatted())
                    } else {
                        LabeledContent("Last synced", value: "Never")
                    }
                    
                    Button("Sync Now") {
                        syncManager.backupToiCloud(context: context)
                        lastSync = syncManager.lastBackupDate
                    }
                    .disabled(isRestoring)
                    
                    if syncManager.isBackupAvailable || isRestoring {
                        Button {
                            isRestoring = true
                            Task {
                                let success = await syncManager.restoreFromiCloud(context: context)
                                isRestoring = false
                                if success {
                                    lastSync = syncManager.lastBackupDate
                                    showingRestoreSuccess = true
                                } else {
                                    showingRestoreFailure = true
                                }
                            }
                        } label: {
                            if isRestoring {
                                HStack {
                                    Text("Restoring...")
                                    Spacer()
                                    ProgressView()
                                }
                            } else {
                                Text("Restore from iCloud")
                            }
                        }
                        .disabled(isRestoring)
                    }
                    
                    Button("Clear iCloud Data", role: .destructive) {
                        syncManager.clearFromiCloud()
                        lastSync = nil
                    }
                    .disabled(isRestoring)
                } else {
                    Button {
                        isRestoring = true
                        Task {
                            let success = await syncManager.restoreFromiCloud(context: context)
                            isRestoring = false
                            if success {
                                iCloudSyncEnabled = true
                                lastSync = syncManager.lastBackupDate
                                showingRestoreSuccess = true
                            } else {
                                showingRestoreFailure = true
                            }
                        }
                    } label: {
                        if isRestoring {
                            HStack {
                                Text("Restoring...")
                                Spacer()
                                ProgressView()
                            }
                        } else {
                            Text("Restore Library from iCloud")
                        }
                    }
                    .disabled(isRestoring)
                }
            }
            Section {
                Toggle("Filter mature & explicit works", isOn: $filterMature)
                NavigationLink("Hidden works", value: SettingsRoute.hiddenWorks)
                NavigationLink("Content policy", value: SettingsRoute.contentPolicy)
            } header: {
                Text("Content & Safety")
            } footer: {
                Text("Fanficly shows works from Archive of Our Own, which are created by other users. Filtering hides Mature- and Explicit-rated works; hiding removes individual works from your results.")
            }
            Section("Privacy") {
                NavigationLink("What this app sees and stores", value: SettingsRoute.privacy)
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.shortVersionString)
                Link(destination: URL(string: "https://github.com/yennster/fanficly")!) {
                    Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: Self.feedbackMailto) {
                    Label("Send feedback", systemImage: "envelope")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationDestination(for: SettingsRoute.self) { route in
            switch route {
            case .login:
                LoginView()
            case .reader:
                ReaderSettingsView()
            case .hiddenWorks:
                HiddenWorksView()
            case .contentPolicy:
                ContentPolicyView()
            case .privacy:
                PrivacyTransparencyView()
            }
        }
        .onAppear {
            lastSync = syncManager.lastBackupDate
        }
        .onChange(of: filterMature) { _, _ in
            syncManager.queueBackup(context: context)
        }
        .alert("Library Restored", isPresented: $showingRestoreSuccess) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your library and settings have been successfully restored from iCloud.")
        }
        .alert("Restore Failed", isPresented: $showingRestoreFailure) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Could not restore backup from iCloud. Please make sure you are logged into iCloud and try again.")
        }
    }
}

struct PrivacyTransparencyView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("What this app sees and stores")
                    .font(.title2).bold()

                Text("Fanficly has no servers. Everything happens on your phone.")

                section(
                    "What we collect",
                    "Nothing. No analytics, no crash reports, no device IDs, no telemetry."
                )
                section(
                    "What's stored on your phone",
                    """
                    • Your AO3 session cookie (in iOS Keychain), so you stay logged in.
                    • Works you've saved offline and your reading position (in app storage).
                    • Your preferences (theme, font size).
                    • An optional backup of your library and settings in your private iCloud storage, if iCloud Sync is enabled.
                    """
                )
                section(
                    "What goes off your phone",
                    "Requests to archiveofourown.org so you can read, search, and log in. We never send your data anywhere else."
                )
                section(
                    "How to delete everything",
                    "Delete the app. iOS will erase all on-device storage including the session cookie. There's no server to wipe — there's no server."
                )
            }
            .padding()
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(body).foregroundStyle(.secondary)
        }
    }
}

extension Bundle {
    var shortVersionString: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
    }
}

#Preview {
    NavigationStack { SettingsView() }
        .environment(AuthState())
}
