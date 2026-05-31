import SwiftUI
import SwiftData

@main
struct FanficlyApp: App {
    private let client: AO3Client = AO3Client()
    @State private var auth = AuthState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.ao3Client, client)
                .environment(auth)
        }
        .modelContainer(for: [
            Work.self,
            Chapter.self,
            TagRecord.self,
            BookmarkRecord.self,
            SubscriptionRecord.self,
        ])
    }
}
