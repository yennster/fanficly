import Foundation
import KeychainAccess

actor CredentialStore {
    static let shared = CredentialStore()

    private let keychain = Keychain(service: "io.github.yennster.fanficly")
    private let usernameKey = "ao3.username"

    func storedUsername() -> String? {
        try? keychain.get(usernameKey)
    }

    func setUsername(_ username: String?) {
        if let username, !username.isEmpty {
            try? keychain.set(username, key: usernameKey)
        } else {
            try? keychain.remove(usernameKey)
        }
    }
}

@MainActor
@Observable
final class AuthState {
    var username: String?
    var isAuthenticating: Bool = false
    var lastError: String?

    init() {
        Task { @MainActor in
            self.username = await CredentialStore.shared.storedUsername()
        }
    }

    func login(using client: any AO3ClientProtocol, username: String, password: String) async {
        isAuthenticating = true
        lastError = nil
        defer { isAuthenticating = false }
        do {
            try await client.login(username: username, password: password)
            self.username = username
            await CredentialStore.shared.setUsername(username)
        } catch let AO3Error.loginFailed(reason) {
            lastError = reason
        } catch let AO3Error.network(underlying) {
            lastError = "Network: \(underlying)"
        } catch {
            lastError = error.localizedDescription
        }
    }

    func logout(using client: any AO3ClientProtocol) async {
        await client.logout()
        await CredentialStore.shared.setUsername(nil)
        username = nil
    }

    var isLoggedIn: Bool { username != nil }
}
