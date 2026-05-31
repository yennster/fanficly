import SwiftUI

struct SettingsView: View {
    var body: some View {
        List {
            Section("Account") {
                NavigationLink("AO3 Login") { LoginPlaceholderView() }
            }
            Section("Reader") {
                Text("Theme and typography options will live here.")
                    .foregroundStyle(.secondary)
            }
            Section("Privacy") {
                NavigationLink("What this app sees and stores") {
                    PrivacyTransparencyView()
                }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.shortVersionString)
                Link("Source on GitHub", destination: URL(string: "https://github.com/yennster/fanficly")!)
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

struct LoginPlaceholderView: View {
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        Form {
            Section {
                TextField("Username", text: $username).textContentType(.username).autocapitalization(.none)
                SecureField("Password", text: $password).textContentType(.password)
            } footer: {
                Text("We pass these to AO3 to log in and store the resulting session cookie in your iOS Keychain. We never store your password.")
            }
            Button("Log in") {}
                .disabled(true)
        }
        .navigationTitle("AO3 Login")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension Bundle {
    var shortVersionString: String {
        (object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.1.0"
    }
}

#Preview { NavigationStack { SettingsView() } }
