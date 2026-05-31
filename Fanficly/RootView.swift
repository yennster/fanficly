import SwiftUI

struct RootView: View {
    @State private var selectedTab: SidebarItem? = .search

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
                case .subscriptions: SubscriptionsView()
                case .settings: SettingsView()
                }
            }
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case search, browse, library, subscriptions, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: "Search"
        case .browse: "Browse"
        case .library: "Library"
        case .subscriptions: "Subscriptions"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .search: "magnifyingglass"
        case .browse: "rectangle.stack"
        case .library: "books.vertical"
        case .subscriptions: "bell"
        case .settings: "gearshape"
        }
    }
}

#Preview {
    RootView()
}
