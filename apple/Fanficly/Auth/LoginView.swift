import SwiftUI

/// AO3 sign-in. Logged out: username or email, password and Log in. Logged in: who you
/// are and Log out. Session expired (#131): the form again, with the username
/// filled in and a note saying why.
struct LoginView: View {
    @Environment(\.ao3Client) private var client
    @Environment(AuthState.self) private var auth
    @Environment(\.dismiss) private var dismiss
    @State private var username: String = ""
    @State private var password: String = ""

    var body: some View {
        Form {
            if let current = auth.username, !auth.isSessionExpired {
                Section {
                    LabeledContent("Logged in as", value: current)
                    Button(role: .destructive) {
                        Task { await auth.logout(using: client) }
                    } label: {
                        if auth.isSigningOut {
                            ProgressView()
                        } else {
                            Text("Log out")
                        }
                    }
                    .disabled(auth.isSigningOut)
                } footer: {
                    Text("Logging out signs you out on AO3 and clears the session cookie from your Keychain. Your offline library stays on the device.")
                }
            } else {
                if auth.isSessionExpired {
                    Section {
                        Label("\(SessionExpiry.title). Sign in again to keep using your AO3 bookmarks, subscriptions and comments, and to see restricted works.",
                              systemImage: "person.crop.circle.badge.questionmark")
                    }
                }
                Section {
                    TextField("Username or email", text: $username)
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
                            if auth.hasSession { dismiss() }
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

                // An expired session can still be removed from this device.
                if auth.isSessionExpired {
                    Section {
                        Button("Log out", role: .destructive) {
                            Task { await auth.logout(using: client) }
                        }
                        .disabled(auth.isSigningOut)
                    }
                }
            }
        }
        .navigationTitle("AO3 Login")
        .onAppear {
            // The username is known when the session expired.
            if username.isEmpty, auth.isSessionExpired, let stored = auth.username { username = stored }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The full-page state for an expired session: retrying can't help, so it
/// offers Sign In Again, which opens the sign-in form with the username filled in.
struct SessionExpiredView: View {
    var message: String = SessionExpiry.message

    var body: some View {
        ContentUnavailableView {
            Label(SessionExpiry.title, systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text(message)
        } actions: {
            NavigationLink { LoginView() } label: { Text(SessionExpiry.actionTitle) }
                .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    NavigationStack { LoginView() }
        .environment(\.ao3Client, MockAO3Client())
        .environment(AuthState())
}
