import SwiftUI

struct LoginView: View {
    @Environment(\.ao3Client) private var client
    @Environment(AuthState.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var username: String = ""
    @State private var password: String = ""

    var body: some View {
        Form {
            if let current = auth.username {
                Section {
                    LabeledContent("Logged in as", value: current)
                    Button("Log out", role: .destructive) {
                        Task { await auth.logout(using: client) }
                    }
                } footer: {
                    Text("Logging out clears the session cookie from your Keychain. Your offline library stays on the device.")
                }
            } else {
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                } footer: {
                    Text("Credentials go directly to AO3. We never store your password — only the resulting session cookie, in your iOS Keychain.")
                }

                if let error = auth.lastError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            await auth.login(using: client, username: username, password: password)
                            if auth.isLoggedIn { dismiss() }
                        }
                    } label: {
                        if auth.isAuthenticating {
                            ProgressView()
                        } else {
                            Text("Log in").frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(auth.isAuthenticating || username.isEmpty || password.isEmpty)
                }
            }
        }
        .navigationTitle("AO3 Login")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack { LoginView() }
        .environment(\.ao3Client, MockAO3Client())
        .environment(AuthState())
}
