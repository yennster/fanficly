import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct SettingsView: View {
    private enum SettingsRoute: Hashable {
        case login
        case reader
        case hiddenWorks
        case blockedTerms
        case contentPolicy
        case privacy
    }

    @Environment(AuthState.self) private var auth
    @Environment(\.modelContext) private var context
    @AppStorage(ContentControl.filterMatureKey) private var filterMature: Bool = true
    @AppStorage("settings.iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = false
    @AppStorage("library.showReadingProgress") private var showReadingProgress = true
    @State private var lastSync: Date? = nil
    @State private var lastBackupFailure: String? = nil
    @State private var showingRestoreSuccess = false
    @State private var showingRestoreFailure = false
    @State private var isRestoring = false
    @State private var isSyncing = false
    /// What the last Sync Now did, shown under "Last synced" until the
    /// screen goes away.
    @State private var syncResult: String? = nil
    /// The Sync Now line is a partial success (a warning, not a checkmark).
    @State private var syncResultIsWarning = false
    @State private var showingClearConfirmation = false
    @State private var clearResult: ClearResultAlert? = nil
    @State private var exportItem: ShareItem? = nil
    @State private var showingImporter = false
    @State private var fileAlert: LibraryFileAlert? = nil
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
                        // An expired session (#131): the sign-in form is one tap away.
                        LabeledContent("AO3 Login", value: auth.isSessionExpired
                                       ? String(localized: "Session expired for \(username)") : username)
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
                                        RestoreDownloadCenter.shared.proposeRedownload(context: context)
                                    } else {
                                        showingRestoreFailure = true
                                    }
                                }
                            }
                        }
                    }
                    .disabled(isRestoring || isSyncing)
                
                if iCloudSyncEnabled {
                    if let date = lastSync {
                        LabeledContent("Last synced", value: date.formatted())
                    } else {
                        // A backup that's in iCloud but not on this device yet has no date here.
                        LabeledContent("Last synced") {
                            Text(syncManager.isBackupAvailable ? "Not downloaded yet" : "Never")
                        }
                    }
                    
                    if let lastBackupFailure {
                        Label {
                            Text("Last backup didn't run: \(lastBackupFailure)")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(.secondary)
                    }

                    if let syncResult {
                        Label {
                            Text(syncResult)
                        } icon: {
                            Image(systemName: syncResultIsWarning ? "exclamationmark.triangle" : "checkmark.circle")
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(.secondary)
                    }

                    Button {
                        isSyncing = true
                        syncResult = nil
                        Task {
                            let result = await syncManager.syncNow(context: context)
                            isSyncing = false
                            lastSync = syncManager.lastBackupDate
                            lastBackupFailure = syncManager.backupProblem
                            syncResult = Self.syncResultMessage(result)
                            syncResultIsWarning = result.restoreFailed || !result.backup.succeeded
                            if let message = syncResult ?? lastBackupFailure {
                                announce(message)
                            }
                            if result.restored {
                                RestoreDownloadCenter.shared.proposeRedownload(context: context)
                            }
                        }
                    } label: {
                        if isSyncing {
                            HStack {
                                Text("Syncing...")
                                Spacer()
                                ProgressView()
                            }
                        } else {
                            Text("Sync Now")
                        }
                    }
                    .disabled(isRestoring || isSyncing)
                    
                    if syncManager.isBackupAvailable || isRestoring {
                        Button {
                            isRestoring = true
                            Task {
                                let success = await syncManager.restoreFromiCloud(context: context)
                                isRestoring = false
                                if success {
                                    lastSync = syncManager.lastBackupDate
                                    showingRestoreSuccess = true
                                    RestoreDownloadCenter.shared.proposeRedownload(context: context)
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
                        .disabled(isRestoring || isSyncing)
                    }
                    
                    Button("Clear iCloud Data", role: .destructive) {
                        showingClearConfirmation = true
                    }
                    .disabled(isRestoring || isSyncing)
                    .confirmationDialog("Clear iCloud Data?", isPresented: $showingClearConfirmation,
                                        titleVisibility: .visible) {
                        Button("Clear and Turn Off Sync", role: .destructive) {
                            cleariCloudData(turnOffSync: true)
                        }
                        Button("Clear and Keep Syncing", role: .destructive) {
                            cleariCloudData(turnOffSync: false)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This deletes your library backup from iCloud. Your other devices that sync use the same backup, so they won't get changes from it until one of them backs up again. Your library on this device isn't affected. If sync stays on, this device starts a new backup with its next change.")
                    }
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
                                RestoreDownloadCenter.shared.proposeRedownload(context: context)
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
                    .disabled(isRestoring || isSyncing)
                }
            }
            Section {
                Button("Export Library File…") {
                    do {
                        exportItem = ShareItem(url: try syncManager.exportLibraryFile(context: context))
                    } catch {
                        fileAlert = .exportFailed
                    }
                }
                .disabled(isRestoring || isSyncing)
                Button("Import Library File…") {
                    showingImporter = true
                }
                .disabled(isRestoring || isSyncing)
            } header: {
                Text("Library File")
            } footer: {
                Text("Saves your library, reading progress, stats and settings as a file you can keep anywhere, or opens one from another device, including Fanficly for Windows. Importing adds the file's works to your library without moving reading progress backwards.")
            }
            Section {
                Toggle("Filter mature & explicit works", isOn: $filterMature)
                NavigationLink("Hidden works", value: SettingsRoute.hiddenWorks)
                NavigationLink("Blocked tags & authors", value: SettingsRoute.blockedTerms)
                NavigationLink("Content policy", value: SettingsRoute.contentPolicy)
            } header: {
                Text("Content & Safety")
            } footer: {
                Text("Fanficly shows works from Archive of Our Own, which are created by other users. Filtering hides Mature- and Explicit-rated works; hiding removes individual works from your results; blocking a tag or author removes every work that has it.")
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
                Link(destination: ReviewPrompter.writeReviewURL) {
                    Label("Rate Fanficly on the App Store", systemImage: "star")
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
            case .blockedTerms:
                BlockedTermsView()
            case .contentPolicy:
                ContentPolicyView()
            case .privacy:
                PrivacyTransparencyView()
            }
        }
        .onAppear {
            lastSync = syncManager.lastBackupDate
            lastBackupFailure = syncManager.backupProblem
            syncResult = nil
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
        .sheet(item: $exportItem) { ShareSheet(items: [$0.url]) }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json]) { result in
            guard case .success(let url) = result else { return }
            do {
                try syncManager.importLibraryFile(at: url, context: context)
                fileAlert = .imported
                RestoreDownloadCenter.shared.proposeRedownload(context: context)
            } catch {
                fileAlert = .importFailed
            }
        }
        .alert(
            fileAlert?.title ?? "",
            isPresented: Binding(get: { fileAlert != nil }, set: { if !$0 { fileAlert = nil } }),
            presenting: fileAlert
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { alert in
            Text(alert.message)
        }
        .alert(clearResult?.title ?? "", isPresented: Binding(
            get: { clearResult != nil },
            set: { if !$0 { clearResult = nil } }
        ), presenting: clearResult) { _ in
            Button("OK", role: .cancel) {}
        } message: { result in
            Text(result.message)
        }
    }

    /// The line Sync Now leaves under "Last synced". When the backup didn't
    /// write, `backupProblem` says why, so this only mentions a restore that
    /// still brought changes in.
    static func syncResultMessage(_ result: SyncNowResult) -> String? {
        guard result.backup.succeeded else {
            return result.restored
                ? String(localized: "Changes from your other devices were added to your library, but this device's backup didn't run.")
                : nil
        }
        if result.restored {
            return String(localized: "Synced. Changes from your other devices were added to your library.")
        }
        if result.restoreFailed {
            return String(localized: "Backed up, but changes from your other devices couldn't be brought in. Fanficly will try again the next time it opens.")
        }
        return String(localized: "Synced. Your library is backed up to iCloud.")
    }

    private func cleariCloudData(turnOffSync: Bool) {
        // The clear cancels a queued backup and nothing backs up in between
        // (both run on the main actor), so sync goes off after it, and only
        // when it worked: otherwise Clear iCloud Data must stay on screen to
        // try again.
        let outcome = syncManager.clearFromiCloud()
        let turnedOff = turnOffSync && (outcome == .cleared || outcome == .nothingToClear)
        if turnedOff { iCloudSyncEnabled = false }
        lastSync = syncManager.lastBackupDate
        lastBackupFailure = syncManager.backupProblem
        syncResult = nil
        let alert = ClearResultAlert(outcome, syncTurnedOff: turnedOff)
        clearResult = alert
        announce(alert.message)
    }

    private func announce(_ message: String) {
        #if os(iOS)
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
    }
}

/// The alert Clear iCloud Data ends with, saying what really happened.
struct ClearResultAlert {
    let title: String
    let message: String

    init(_ outcome: ClearOutcome, syncTurnedOff: Bool) {
        let syncNote = syncTurnedOff
            ? String(localized: "Sync is now off on this device.")
            : String(localized: "Sync is still on, so this device starts a new backup with its next change.")
        switch outcome {
        case .cleared:
            title = String(localized: "iCloud Data Cleared")
            message = String(localized: "Your library backup was deleted from iCloud.") + " " + syncNote
        case .nothingToClear:
            title = String(localized: "Nothing to Clear")
            message = String(localized: "There's no library backup in iCloud.") + " " + syncNote
        case .waitingForDownload:
            title = String(localized: "Not Cleared Yet")
            message = String(localized: "The backup in iCloud is still downloading to this device, so it couldn't be deleted yet. Try again in a minute.")
        case .iCloudUnavailable:
            title = String(localized: "Couldn't Clear iCloud Data")
            message = BackupOutcome.iCloudUnavailable.failureMessage ?? ""
        case .failed(let reason):
            title = String(localized: "Couldn't Clear iCloud Data")
            message = reason
        }
    }
}

/// The outcome alerts for exporting and importing a library file.
private enum LibraryFileAlert: String, Identifiable {
    case imported, importFailed, exportFailed

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .imported: "Library Imported"
        case .importFailed: "Import Failed"
        case .exportFailed: "Export Failed"
        }
    }

    var message: LocalizedStringKey {
        switch self {
        case .imported: "The file's works, reading progress and stats have been added to your library."
        case .importFailed: "That file couldn't be imported. Make sure it's a Fanficly library file and try again."
        case .exportFailed: "Your library couldn't be written to a file. Please try again."
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
                    • Works you've saved offline, your notes and tags on them, and your reading position (in app storage).
                    • Your preferences (theme, font size).
                    • The title, author, summary and tags of works in your Library, in your device's on-device Spotlight index so system search can find them. Removing a work removes it.
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

    private func section(_ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
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
