import SwiftUI
import SwiftData

@main
struct FanficlyApp: App {
    private let client: AO3Client = AO3Client()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.ao3Client, client)
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
