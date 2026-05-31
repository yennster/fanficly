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
        if let link = try doc.select("ul#user-navigation a[href^=/users/]").first() {
            let href = try link.attr("href")
            let parts = href.split(separator: "/")
            if parts.count >= 2, parts[0] == "users" {
                return String(parts[1])
            }
        }
        return nil
    }
}
