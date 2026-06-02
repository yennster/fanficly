import SwiftUI

struct SettingsView: View {
    @Environment(AuthState.self) private var auth
    @AppStorage(ContentControl.filterMatureKey) private var filterMature: Bool = true

    /// Pre-filled feedback email (subject percent-encoded so it survives the mailto).
    static let feedbackMailto = URL(
        string: "mailto:jenny+fanficly@jennyplunkett.me?subject=Fanficly%20feedback"
    )!

    var body: some View {
        List {
            Section("Account") {
                NavigationLink {
                    LoginView()
                } label: {
                    if let username = auth.username {
                        LabeledContent("AO3 Login", value: username)
                    } else {
                        Text("AO3 Login")
                    }
                }
            }
            Section("Reader") {
                NavigationLink("Theme & typography") {
                    ReaderSettingsView()
                }
            }
            Section {
                Toggle("Filter mature & explicit works", isOn: $filterMature)
                NavigationLink("Hidden works") {
                    HiddenWorksView()
                }
                NavigationLink("Content policy") {
                    ContentPolicyView()
                }
            } header: {
                Text("Content & Safety")
            } footer: {
                Text("Fanficly shows works from Archive of Our Own, which are created by other users. Filtering hides Mature- and Explicit-rated works; hiding removes individual works from your results.")
            }
            Section("Privacy") {
                NavigationLink("What this app sees and stores") {
                    PrivacyTransparencyView()
                }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.shortVersionString)
                Link(destination: URL(string: "https://github.com/yennster/fanficly")!) {
                    Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://github.com/sponsors/yennster/")!) {
                    Label("Sponsor me on GitHub", systemImage: "heart.fill")
                        .foregroundStyle(.pink)
                }
                Link(destination: Self.feedbackMailto) {
                    Label("Send feedback", systemImage: "envelope")
                }
            }
        }
        .navigationTitle("Settings")
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
