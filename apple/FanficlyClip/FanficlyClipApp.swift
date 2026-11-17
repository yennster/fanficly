import SwiftUI
import SwiftData

/// Fanficly's App Clip (#292): opens one shared AO3 work from a fanficly.app
/// link in the app's own reader, without installing the app. It compiles the
/// app's sources (everything in `Fanficly/` but `FanficlyApp.swift`, see
/// project.yml) with the `APP_CLIP` condition, so the reader, the AO3 client
/// and its 1 request/second throttle are the app's own. No accounts, library
/// or follows: the work's menu offers the full app instead.
@main
struct FanficlyClipApp: App {
    private let client: any AO3ClientProtocol = AO3Client()
    /// Shared views read it. The clip has its own Keychain, so nobody is
    /// signed in here, and nothing in the clip offers a login.
    @State private var auth = AuthState()

    /// The clip's own store, in its own container: reading progress and
    /// stats for the work it opens. The app doesn't read it; the handoff goes
    /// through the app group (`ClipHandoff`, `WidgetProgressStore`).
    private static let sharedModelContainer: ModelContainer = {
        let config = ModelConfiguration(isStoredInMemoryOnly: false, cloudKitDatabase: .none)
        return try! ModelContainer(for: AppSchema.schema, configurations: config)
    }()

    var body: some Scene {
        WindowGroup {
            ClipRootView()
                .readingSpeedFromStats()
                .environment(\.ao3Client, client)
                .environment(auth)
        }
        .modelContainer(Self.sharedModelContainer)
    }
}

/// The app's launch flags, which shared code reads as `FanficlyApp.…`. The
/// clip has no demo mode: its screenshots aren't store art.
enum FanficlyApp {
    static var isDemoMode: Bool { false }
    static var isTestMode: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }
}
