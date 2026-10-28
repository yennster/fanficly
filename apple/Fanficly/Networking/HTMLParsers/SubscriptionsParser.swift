import Foundation
import SwiftSoup

public struct AO3Subscription: Sendable, Equatable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Equatable, Hashable {
        case work, series, user
    }
    public let kind: Kind
    public let resourceId: String
    public let title: String
    public let author: String?

    public var id: String { "\(kind.rawValue):\(resourceId)" }
    public var key: String { id }
}

/// The account's whole subscriptions list, as far as `fetchSubscriptions`
/// walked it. `isComplete` is false when the list ran past the page ceiling,
/// so the entries it holds are real but anything missing may still be
/// subscribed: the caller must not treat a missing entry as unsubscribed.
public struct AO3SubscriptionList: Sendable, Equatable {
    public let subscriptions: [AO3Subscription]
    public let isComplete: Bool

    public init(subscriptions: [AO3Subscription], isComplete: Bool = true) {
        self.subscriptions = subscriptions
        self.isComplete = isComplete
    }
}

/// One page of the subscriptions index: its entries plus the pagination
/// numbers needed to walk the remaining pages.
struct AO3SubscriptionsPage: Sendable {
    let subscriptions: [AO3Subscription]
    let currentPage: Int
    let totalPages: Int
}

enum SubscriptionsParser {
    static func parse(html: String) throws -> [AO3Subscription] {
        try parsePage(html: html).subscriptions
    }

    static func parsePage(html: String) throws -> AO3SubscriptionsPage {
        let doc = try SwiftSoup.parse(html)

        // Fail closed on a stale session: AO3 302s /users/<name>/subscriptions
        // to the login page, URLSession follows the redirect, and the caller
        // hands us login HTML with a 200. Returning [] here (or a phantom row
        // scraped from the login page's own links) would make the poller prune
        // every real SubscriptionRecord, so it must be an error.
        if looksLikeLoginPage(doc) {
            throw AO3Error.unauthorized
        }

        var seen = Set<String>()
        var results: [AO3Subscription] = []

        let containers = try doc.select("dl.subscription, ul.subscription, dl.subscriptions, ul.subscriptions, ol.subscription, ol.subscriptions")

        // No subscription list at all: only trust that as "zero subscriptions"
        // when the page carries the subscriptions-index shell — anything else
        // (error page, markup drift, unexpected redirect) must not read as an
        // empty account.
        if containers.isEmpty(), try !hasIndexMarker(doc) {
            throw AO3Error.parseFailed(reason: "Not a subscriptions page")
        }

        for scope in containers.array() {
            let entries = try scope.select("dt, li.subscription, li.work, li.series, li.user").array()
            let entrySource: [Element] = entries.isEmpty ? [scope] : entries

            for entry in entrySource {
                let links = try entry.select("a[href]").array()
                guard let primary = pickPrimaryLink(links) else { continue }
                let href = try primary.attr("href")
                guard let parsed = classify(href: href) else { continue }
                if seen.contains(parsed.key) { continue }
                seen.insert(parsed.key)

                let title = try primary.text().trimmingCharacters(in: .whitespaces)
                let author = try authorFromEntry(links: links, primary: primary)

                results.append(AO3Subscription(
                    kind: parsed.kind,
                    resourceId: parsed.id,
                    title: title,
                    author: author
                ))
            }
        }

        let (currentPage, totalPages) = try pagination(doc)
        return AO3SubscriptionsPage(
            subscriptions: results,
            currentPage: currentPage,
            totalPages: totalPages
        )
    }

    /// A logged-in-only page can never legitimately contain a login form, so
    /// its presence means the session cookie expired and AO3 redirected us.
    static func looksLikeLoginPage(_ doc: Document) -> Bool {
        let forms = (try? doc.select("form").array()) ?? []
        return forms.contains { form in
            let action = (try? form.attr("action")) ?? ""
            return action.hasSuffix("/users/login") || action.contains("/users/login?")
        }
    }

    /// The subscriptions index shell: the `subscriptions-index` main div
    /// (Rails' controller-action class) or a heading naming the page. Present
    /// even when the user has zero subscriptions.
    private static func hasIndexMarker(_ doc: Document) throws -> Bool {
        if try !doc.select("div.subscriptions-index, div.subscription-index").isEmpty() {
            return true
        }
        for heading in try doc.select("h2.heading, h3.heading").array() {
            if try heading.text().localizedCaseInsensitiveContains("subscription") {
                return true
            }
        }
        return false
    }

    /// Same will_paginate markup as the search pages — see
    /// `SearchResultsParser` for why "current" is checked on both the <li>
    /// and its inner element.
    private static func pagination(_ doc: Document) throws -> (current: Int, total: Int) {
        var current = 1
        var total = 1
        for li in try doc.select("ol.pagination li").array() {
            guard let num = Int(try li.text().trimmingCharacters(in: .whitespaces)) else { continue }
            total = max(total, num)
            let liIsCurrent = try li.attr("class").contains("current")
            let innerIsCurrent = try !li.select(".current").array().isEmpty
            if liIsCurrent || innerIsCurrent { current = num }
        }
        return (current, total)
    }

    private static func pickPrimaryLink(_ links: [Element]) -> Element? {
        for link in links {
            let href = (try? link.attr("href")) ?? ""
            if classify(href: href) != nil, !href.contains("/comments") {
                return link
            }
        }
        return nil
    }

    private static func authorFromEntry(links: [Element], primary: Element) throws -> String? {
        for link in links where link != primary {
            let href = try link.attr("href")
            if href.hasPrefix("/users/") {
                let text = try link.text().trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    struct Classified {
        let kind: AO3Subscription.Kind
        let id: String
        var key: String { "\(kind.rawValue):\(id)" }
    }

    private static func classify(href: String) -> Classified? {
        let trimmed = href.split(separator: "?").first.map(String.init) ?? href
        let parts = trimmed.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }

        switch parts[0] {
        case "works":
            return Classified(kind: .work, id: parts[1])
        case "series":
            return Classified(kind: .series, id: parts[1])
        case "users":
            if parts.count == 2 || (parts.count >= 3 && parts[2] == "pseuds") {
                return Classified(kind: .user, id: parts[1])
            }
            return nil
        default:
            return nil
        }
    }
}

/// A work page's subscribe button and AO3's answer to it, read from
/// otwarchive's `SubscriptionsController#create` and `subscriptions/_form`.
/// The button is `li.subscribe form`, posting to `/users/<login>/subscriptions`
/// (hidden `subscription[subscribable_id]`/`[subscribable_type]`), and reads
/// "Unsubscribe" (a `_method=delete` form) once subscribed. AO3 redirects
/// either outcome back to the work with a flash, a stale token to
/// `/auth_error`, and an ended session to the login page: all 200s once
/// URLSession follows, so the answer fails closed.
enum SubscribeParser {
    struct Form: Equatable {
        let action: URL
        /// The form's hidden inputs (its own token included).
        let fields: [String: String]
        /// The button reads "Unsubscribe": the work is already subscribed.
        let isSubscribed: Bool
    }

    static func form(html: String, base: URL) -> Form? {
        guard let doc = try? SwiftSoup.parse(html),
              let form = try? doc.select("li.subscribe form").first() else { return nil }
        let actionStr = (try? form.attr("action")) ?? ""
        guard !actionStr.isEmpty, let action = URL(string: actionStr, relativeTo: base)?.absoluteURL else { return nil }
        var fields: [String: String] = [:]
        for input in (try? form.select("input[type=hidden]").array()) ?? [] {
            let name = (try? input.attr("name")) ?? ""
            guard !name.isEmpty else { continue }
            fields[name] = (try? input.attr("value")) ?? ""
        }
        let isSubscribed = fields["_method"]?.lowercased() == "delete" || hasUnsubscribeButton(form)
        if !isSubscribed { fields["_method"] = nil }
        return Form(action: action, fields: fields, isSubscribed: isSubscribed)
    }

    static func checkOutcome(html: String, finalURL: URL?) throws {
        let path = finalURL?.path ?? ""
        if path.hasPrefix("/users/login") || path.hasPrefix("/auth_error") || AO3PageCheck.isLoginPage(html: html) {
            throw AO3Error.unauthorized
        }
        guard let doc = try? SwiftSoup.parse(html) else {
            throw AO3Error.parseFailed(reason: "Subscribe response not HTML")
        }
        let errors = texts(doc, "div.flash.error, div#error li")
        if !errors.isEmpty {
            var seen = Set<String>()
            throw AO3Error.subscribeRejected(message: errors.filter { seen.insert($0).inserted }.joined(separator: " "))
        }
        let notices = texts(doc, "div.flash.notice")
        if notices.contains(where: { $0.range(of: "now following", options: .caseInsensitive) != nil }) { return }
        if let form = try? doc.select("li.subscribe form").first(), hasUnsubscribeButton(form) { return }
        throw AO3Error.subscribeRejected(message: "AO3 didn't confirm the subscription. Check your Subscriptions page before trying again.")
    }

    private static func hasUnsubscribeButton(_ form: Element) -> Bool {
        let controls = (try? form.select("input[type=submit], button").array()) ?? []
        return controls.contains { control in
            let label = control.hasAttr("value") ? ((try? control.attr("value")) ?? "") : ((try? control.text()) ?? "")
            return label.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Unsubscribe") == .orderedSame
        }
    }

    private static func texts(_ doc: Document, _ selector: String) -> [String] {
        let items = (try? doc.select(selector).array()) ?? []
        return items.compactMap { try? $0.text().trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
