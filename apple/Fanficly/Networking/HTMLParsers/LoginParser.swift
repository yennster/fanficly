import Foundation
import SwiftSoup

enum LoginParser {
    static func authenticityToken(html: String) throws -> String? {
        let doc = try SwiftSoup.parse(html)
        if let meta = try doc.select("meta[name=csrf-token]").first() {
            let value = try meta.attr("content")
            if !value.isEmpty { return value }
        }
        if let input = try doc.select("form input[name=authenticity_token]").first() {
            let value = try input.attr("value")
            if !value.isEmpty { return value }
        }
        return nil
    }

    static func detectLoginFailure(html: String) throws -> String? {
        let doc = try SwiftSoup.parse(html)
        if let flash = try doc.select("div#flash_error, p.error, ul.errorlist li").first() {
            let msg = try flash.text().trimmingCharacters(in: .whitespaces)
            if !msg.isEmpty { return msg }
        }
        return nil
    }

    static func currentUsername(html: String) throws -> String? {
        let doc = try SwiftSoup.parse(html)
        // AO3's logged-in navbar (#greeting dropdown) links to /users/<name>.
        let selectors = [
            "#greeting a[href^=/users/]",
            "ul.user.navigation a[href^=/users/]",
            "ul#user-navigation a[href^=/users/]",
            "#header a[href^=/users/]",
        ]
        for sel in selectors {
            for link in try doc.select(sel).array() {
                let href = try link.attr("href")
                let parts = href.split(separator: "/").map(String.init)
                guard parts.count >= 2, parts[0] == "users" else { continue }
                let name = parts[1]
                // Skip the login/logout/signup action links.
                if ["login", "logout", "signup", "activate"].contains(name.lowercased()) { continue }
                return name
            }
        }
        return nil
    }

    /// True if the page still shows the login form (i.e. we're not logged in).
    static func hasLoginForm(html: String) throws -> Bool {
        let doc = try SwiftSoup.parse(html)
        return try !doc.select("form#new_user, input[name=user[login]], #loginform").isEmpty()
    }
}
