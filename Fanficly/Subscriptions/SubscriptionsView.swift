import SwiftUI
import SwiftData

struct SubscriptionsView: View {
    @Query(sort: \SubscriptionRecord.displayName) private var subs: [SubscriptionRecord]

    var body: some View {
        Group {
            if subs.isEmpty {
                ContentUnavailableView(
                    "No subscriptions",
                    systemImage: "bell.slash",
                    description: Text("Once you log in, your AO3 subscriptions will sync here and you'll get a local notification when new chapters drop.")
                )
            } else {
                List(subs) { sub in
                    VStack(alignment: .leading) {
                        Text(sub.displayName).font(.headline)
                        Text(sub.kind).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Subscriptions")
    }
}
