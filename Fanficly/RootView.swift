import SwiftUI

struct RootView: View {
    // Start with no selection so the app opens on the sidebar menu
    // (on iPhone) rather than pushing straight into Search.
    @State private var selectedTab: SidebarItem? = nil
    @Environment(\.modelContext) private var context
    @AppStorage(ContentControl.ageConfirmedKey) private var ageConfirmed: Bool = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(SidebarItem.allCases) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.systemImage)
                    }
                }
            }
            .navigationTitle("Fanficly")
        } detail: {
            NavigationStack {
                switch selectedTab ?? .search {
                case .search: SearchView()
                case .browse: BrowseView()
                case .library: LibraryView()
                case .recentlyViewed: RecentlyViewedView()
                case .subscriptions: SubscriptionsView()
                case .settings: SettingsView()
                }
            }
        }
        .task {
            if FanficlyApp.isDemoMode { DemoSeed.seed(into: context) }
        }
        // 17+ confirmation on first launch (UGC safeguard). Skipped in demo
        // mode so screenshot automation isn't blocked.
        .fullScreenCover(isPresented: .constant(!ageConfirmed && !FanficlyApp.isDemoMode)) {
            AgeGateView()
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case search, browse, library, recentlyViewed, subscriptions, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: "Search"
        case .browse: "Browse"
        case .library: "Library"
        case .recentlyViewed: "Recently Viewed"
        case .subscriptions: "Subscriptions"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .search: "magnifyingglass"
        case .browse: "rectangle.stack"
        case .library: "books.vertical"
        case .recentlyViewed: "clock.arrow.circlepath"
        case .subscriptions: "bell"
        case .settings: "gearshape"
        }
    }
}

#Preview {
    RootView()
}
