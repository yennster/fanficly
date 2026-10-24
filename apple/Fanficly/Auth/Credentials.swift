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

/// What an expired AO3 session looks like (#131): signed in on this device, but
/// AO3 answered with its login page, or a listing rendered for a guest (which
/// leaves out restricted works).
enum SessionExpiry {
    static let title = "Your AO3 session expired"
    static let actionTitle = "Sign In Again"
    static let message = "AO3 signed you out. Sign in again to keep using your AO3 account here."
    static let listingMessage = "AO3 signed you out, so it only sent the works a guest can see. Sign in again to see restricted works too."

    /// A listing AO3 rendered for a guest while signed in.
    struct GuestListing: Error {}
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
            // Signing in as someone else from the expired-session form skips
            // logout, so drop the previous account's kudos here.
            if let previous = self.username, previous.caseInsensitiveCompare(username) != .orderedSame { KudosStore.clear() }
            self.username = username
            CredentialStore.shared.setUsername(username)
            isSessionExpired = false
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
        KudosStore.clear()
        username = nil
        isSessionExpired = false
    }

    /// A username is stored (the reader signed in on this device). The session
    /// cookie may still have expired; see `isSessionExpired`.
    var isLoggedIn: Bool { username != nil }

    /// AO3 dropped the session while a username is stored: a request that needs
    /// the account got the login page, or a page came back rendered for a
    /// guest. Only signing in again (or out) clears it.
    private(set) var isSessionExpired = false

    /// Signed in with a live session: what account features need.
    var hasSession: Bool { isLoggedIn && !isSessionExpired }

    /// Marks the session expired when signed in (a guest has nothing to expire).
    func markSessionExpired() {
        if isLoggedIn { isSessionExpired = true }
    }

    /// Notes a failed AO3 request: `unauthorized` while signed in means the
    /// session expired. Returns whether it did.
    @discardableResult
    func noteFailure(_ error: Error) -> Bool {
        guard case AO3Error.unauthorized = error, isLoggedIn else { return false }
        isSessionExpired = true
        return true
    }

    /// Notes a works listing (search, an author's works, bookmarks): one AO3
    /// rendered for a guest while signed in means the session expired, and the
    /// listing is missing every restricted work. Returns whether it did.
    @discardableResult
    func noteListing(_ results: AO3SearchResults) -> Bool {
        guard results.servedAsGuest, isLoggedIn else { return false }
        isSessionExpired = true
        return true
    }

    /// Passes a works listing through, throwing `SessionExpiry.GuestListing`
    /// when AO3 rendered it for a guest while signed in: showing it would
    /// quietly drop every restricted work.
    func check(_ results: AO3SearchResults) throws -> AO3SearchResults {
        if noteListing(results) { throw SessionExpiry.GuestListing() }
        return results
    }

    /// Whether a failure means the session expired, noting it (a guest
    /// listing, or `unauthorized` while signed in).
    func explains(_ error: Error) -> Bool {
        error is SessionExpiry.GuestListing || noteFailure(error)
    }

    /// What to say for a failure `explains(_:)` accepted.
    static func message(for error: Error) -> String {
        error is SessionExpiry.GuestListing ? SessionExpiry.listingMessage : SessionExpiry.message
    }
}
