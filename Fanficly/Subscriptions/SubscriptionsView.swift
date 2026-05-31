import SwiftUI
import SwiftData

struct SubscriptionsView: View {
    @Environment(\.ao3Client) private var client
    @Environment(\.modelContext) private var context
    @Environment(AuthState.self) private var auth
    @Query(sort: \SubscriptionRecord.displayName) private var subs: [SubscriptionRecord]
    @State private var isRefreshing: Bool = false
    @State private var lastError: String?
    @State private var lastNotifyCount: Int?
    @State private var hasRequestedNotifications: Bool = false

    var body: some View {
        Group {
            if auth.username == nil {
                ContentUnavailableView {
                    Label("Log in to AO3", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("Your AO3 subscriptions sync here once you log in. We'll notify you locally when subscribed works post new chapters.")
                } actions: {
                    NavigationLink {
                        LoginView()
                    } label: {
                        Text("Open Settings → AO3 Login").font(.callout)
                    }
                }
            } else if subs.isEmpty && !isRefreshing {
                ContentUnavailableView {
                    Label("No subscriptions yet", systemImage: "bell")
                } description: {
                    Text("Tap Refresh to fetch your subscriptions from AO3.")
                } actions: {
                    Button("Refresh") { Task { await refresh() } }
                }
            } else {
                List {
                    if let lastError {
                        Section {
                            Label(lastError, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                    if let count = lastNotifyCount {
                        Section {
                            Text(count == 0
                                 ? "No new chapters."
                                 : "\(count) work\(count == 1 ? "" : "s") have new chapters.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        ForEach(subs) { sub in
                            SubscriptionRow(sub: sub)
                        }
                    } header: {
                        Text("\(subs.count) subscription\(subs.count == 1 ? "" : "s")")
                    }
                }
            }
        }
        .navigationTitle("Subscriptions")
        .toolbar {
            if auth.username != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        if isRefreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(isRefreshing)
                }
            }
        }
        .task {
            if !hasRequestedNotifications, auth.username != nil {
                hasRequestedNotifications = true
                _ = await NotificationsAuthorization.request()
            }
        }
    }

    private func refresh() async {
        guard let username = auth.username else { return }
        isRefreshing = true
        lastError = nil
        defer { isRefreshing = false }
        let poller = SubscriptionPoller(client: client, context: context, username: username)
        do {
            _ = try await poller.syncSubscriptionList()
            lastNotifyCount = await poller.checkForNewChapters()
        } catch let AO3Error.parseFailed(reason) {
            lastError = "Couldn't parse AO3's response: \(reason)"
        } catch let AO3Error.unauthorized {
            lastError = "Not logged in. Open Settings → AO3 Login."
        } catch let AO3Error.network(underlying) {
            lastError = "Network: \(underlying)"
        } catch {
            lastError = error.localizedDescription
        }
    }
}

struct SubscriptionRow: View {
    let sub: SubscriptionRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(sub.displayName).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    Text(sub.kind.capitalized).font(.caption).foregroundStyle(.secondary)
                    if let count = sub.lastSeenChapterCount {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(count) chapter\(count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let checked = sub.lastCheckedAt {
                        Text("·").foregroundStyle(.tertiary)
                        Text("checked \(checked, style: .relative) ago")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch sub.kind {
        case "work":   "doc.text"
        case "series": "books.vertical"
        case "user":   "person"
        default:       "bell"
        }
    }
}

#Preview {
    NavigationStack { SubscriptionsView() }
        .environment(\.ao3Client, MockAO3Client())
        .environment(AuthState())
}
