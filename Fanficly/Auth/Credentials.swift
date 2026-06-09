import Foundation
import KeychainAccess

struct SerializableCookie: Codable, Sendable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let expiresDate: Date?
    let isSecure: Bool
    let isHTTPOnly: Bool
    
    init(cookie: HTTPCookie) {
        self.name = cookie.name
        self.value = cookie.value
        self.domain = cookie.domain
        self.path = cookie.path
        self.expiresDate = cookie.expiresDate
        self.isSecure = cookie.isSecure
        self.isHTTPOnly = cookie.isHTTPOnly
    }
    
    var properties: [HTTPCookiePropertyKey: Any] {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: name,
            .value: value,
            .domain: domain,
            .path: path
        ]
        if let expiresDate {
            props[.expires] = expiresDate
        }
        props[.secure] = isSecure ? "TRUE" : "FALSE"
        return props
    }
}

final class CredentialStore: @unchecked Sendable {
    static let shared = CredentialStore()

    private let keychain = Keychain(service: "io.github.yennster.fanficly")
    private let usernameKey = "ao3.username"
    private let cookiesKey = "ao3.cookies"

    private init() {}

    func storedUsername() -> String? {
        try? keychain.get(usernameKey)
    }

    func setUsername(_ username: String?) {
        if let username, !username.isEmpty {
            try? keychain.set(username, key: usernameKey)
        } else {
            try? keychain.remove(usernameKey)
            try? keychain.remove(cookiesKey)
        }
    }
    
    func saveCookies(_ cookies: [HTTPCookie]) {
        let serializable = cookies.map { SerializableCookie(cookie: $0) }
        if let data = try? JSONEncoder().encode(serializable),
           let jsonString = String(data: data, encoding: .utf8) {
            try? keychain.set(jsonString, key: cookiesKey)
        }
    }

    func loadCookies() -> [HTTPCookie] {
        guard let jsonString = try? keychain.get(cookiesKey),
              let data = jsonString.data(using: .utf8),
              let serializable = try? JSONDecoder().decode([SerializableCookie].self, from: data) else {
            return []
        }
        return serializable.compactMap { HTTPCookie(properties: $0.properties) }
    }
}

@MainActor
@Observable
final class AuthState {
    var username: String?
    var isAuthenticating: Bool = false
    var lastError: String?

    init() {
        self.username = CredentialStore.shared.storedUsername()
    }

    func login(using client: any AO3ClientProtocol, username: String, password: String) async {
        isAuthenticating = true
        lastError = nil
        defer { isAuthenticating = false }
        do {
            try await client.login(username: username, password: password)
            self.username = username
            CredentialStore.shared.setUsername(username)
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
        CredentialStore.shared.setUsername(nil)
        username = nil
    }

    var isLoggedIn: Bool { username != nil }
}
