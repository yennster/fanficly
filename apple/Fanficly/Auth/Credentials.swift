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

/// Where the signed-in AO3 login name is kept. `CredentialStore` in the app;
/// tests pass one that keeps it in memory.
protocol LoginNameStore: AnyObject, Sendable {
    func storedUsername() -> String?
    func setUsername(_ username: String?)
}

/// Where AO3's cookies are kept between launches. `CredentialStore` in the app;
/// tests pass one that keeps them in memory.
protocol CookieVault: AnyObject, Sendable {
    func saveCookies(_ cookies: [HTTPCookie])
    func loadCookies() -> [HTTPCookie]
    func clearCookies()
}

final class CredentialStore: LoginNameStore, CookieVault, @unchecked Sendable {
    static let shared = CredentialStore()

    private static let service = "io.github.yennster.fanficly"
    private let keychain = Keychain(service: CredentialStore.service)
    private let usernameKey = "ao3.username"
    private let cookiesKey = "ao3.cookies"

    private init() {
        let keychain = self.keychain
        Self.forgetPreviousInstall(defaults: .standard) { try? keychain.removeAll() }
    }

    /// Set the first time this install opens.
    static let installedKey = "app.installed"

    /// iOS keeps Keychain items after the app is deleted, so a reinstalled app
    /// would still be signed in as whoever used it before (#145). Deleting the
    /// app does erase its UserDefaults, so a first launch with no
    /// `installedKey` clears the Keychain. An install from before the flag
    /// existed has answered the age gate, which a fresh one hasn't yet; that
    /// one keeps its sign-in. Returns whether it cleared.
    @discardableResult
    static func forgetPreviousInstall(defaults: UserDefaults, clear: () -> Void) -> Bool {
        guard !defaults.bool(forKey: installedKey) else { return false }
        defaults.set(true, forKey: installedKey)
        guard defaults.object(forKey: ContentControl.ageConfirmedKey) == nil else { return false }
        clear()
        return true
    }

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

    func clearCookies() {
        try? keychain.remove(cookiesKey)
    }
}

/// Keeps the vault's copy of AO3's cookies in step with signing in and out
/// (#145). Saves run in order on one queue, only while signed in, and a save
/// queued before a sign-out is dropped, so a cookie change that was racing
/// logout can't write the session back after logout cleared it.
final class CookiePersistence: @unchecked Sendable {
    private let vault: any CookieVault
    private let queue = DispatchQueue(label: "io.github.yennster.fanficly.cookies", qos: .utility)
    private let lock = NSLock()
    private var _generation = 0
    private var _isSignedIn: Bool

    init(vault: any CookieVault, signedIn: Bool) {
        self.vault = vault
        _isSignedIn = signedIn
    }

    /// Goes up at every sign-out. A request that started at an older
    /// generation was sent with the old session's cookies, so whatever cookies
    /// it brings back belong to that session.
    var generation: Int { lock.withLock { _generation } }

    /// Signed in on this device: cookie changes are saved.
    var isSignedIn: Bool { lock.withLock { _isSignedIn } }

    func cookiesChanged(_ cookies: [HTTPCookie]) {
        let generation: Int? = lock.withLock { _isSignedIn ? _generation : nil }
        guard let generation else { return }
        queue.async { [self] in
            guard lock.withLock({ _isSignedIn && _generation == generation }) else { return }
            vault.saveCookies(cookies)
        }
    }

    /// A sign-in succeeded: save its cookies, and every change after.
    func signedIn(with cookies: [HTTPCookie]) {
        lock.withLock { _isSignedIn = true }
        cookiesChanged(cookies)
    }

    /// Stops saving, drops saves still queued, and clears the vault's cookies.
    func signedOut() {
        lock.withLock {
            _isSignedIn = false
            _generation += 1
        }
        queue.async { [vault] in vault.clearCookies() }
    }

    /// Waits for queued saves and clears (tests).
    func flush() { queue.sync {} }
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
    private let store: any LoginNameStore
    /// Forgets what the device keeps about the account that just left (#159):
    /// its subscriptions and when they were synced. Runs on sign-out and when
    /// someone else signs in; the app passes `AccountData.forget`.
    private let forgetAccount: @MainActor () -> Void

    init(store: any LoginNameStore = CredentialStore.shared,
         forgetAccount: @escaping @MainActor () -> Void = {}) {
        self.store = store
        self.forgetAccount = forgetAccount
        self.username = store.storedUsername()
    }

    /// Signs in with what the reader typed, a username or an email address, and
    /// keeps the AO3 login name AO3 answers with: `/users/<name>` pages and the
    /// subscription poller need the login name, never the email (#144).
    func login(using client: any AO3ClientProtocol, username typed: String, password: String) async {
        isAuthenticating = true
        lastError = nil
        defer { isAuthenticating = false }
        do {
            let login = try await client.login(username: typed.trimmingCharacters(in: .whitespacesAndNewlines),
                                               password: password)
            // Signing in as someone else from the expired-session form skips
            // logout, so drop the previous account's kudos and subscriptions here.
            if let previous = self.username, previous.caseInsensitiveCompare(login) != .orderedSame {
                KudosStore.clear()
                forgetAccount()
            }
            self.username = login
            store.setUsername(login)
            isSessionExpired = false
        } catch let AO3Error.loginFailed(reason) {
            lastError = reason
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Signing out: AO3 is being asked to end the session (#145).
    var isSigningOut: Bool = false

    func logout(using client: any AO3ClientProtocol) async {
        isSigningOut = true
        defer { isSigningOut = false }
        // The client forgets the stored name as soon as it starts (#145).
        await client.logout()
        store.setUsername(nil)
        KudosStore.clear()
        forgetAccount()
        username = nil
        isSessionExpired = false
    }

    /// Builds before #144 stored whatever was typed at sign-in, so a reader who
    /// signed in with an email address has it stored in place of the login
    /// name. Swaps it for the name in AO3's page header. Runs at launch.
    func repairStoredLogin(using client: any AO3ClientProtocol) async {
        if let login = await Self.repairedLogin(store: store, client: client) { username = login }
    }

    /// The stored login name, first replacing a stored email address with the
    /// name AO3 shows the signed-in reader. Leaves an email in place when AO3
    /// can't say (offline, or the session expired); signing in again fixes it.
    /// AO3 login names can't contain "@", so only an email costs a request.
    static func repairedLogin(store: any LoginNameStore = CredentialStore.shared,
                              client: any AO3ClientProtocol) async -> String? {
        guard let stored = store.storedUsername(), stored.contains("@") else { return store.storedUsername() }
        guard let login = await client.currentUsername(), !login.contains("@") else { return stored }
        store.setUsername(login)
        return login
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
