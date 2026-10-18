import Foundation
import SwiftSoup

enum MediaCategoryParser {
    static func parse(html: String) throws -> [BrowseFandom] {
        let doc = try SwiftSoup.parse(html)
        var seen = Set<String>()
        var results: [BrowseFandom] = []

        for link in try doc.select("a[href^=/tags/]").array() {
            let href = try link.attr("href")
            guard href.hasSuffix("/works") else { continue }
            let raw = try link.text().trimmingCharacters(in: .whitespaces)
            guard !raw.isEmpty else { continue }

            let canonical = canonicalizeFandomName(raw)
            // AO3 renders the work count after the link, e.g.
            // `<a ...>Harry Potter - J. K. Rowling</a> (123456)`. Read it from
            // the enclosing element's text so "Popular" can rank by it.
            let containerText = (try? link.parent()?.text()) ?? raw
            let count = trailingCount(in: containerText)
            if !seen.contains(canonical) {
                seen.insert(canonical)
                results.append(BrowseFandom(canonical, canonical: canonical, workCount: count))
            }
        }
        return results.sorted { $0.canonicalName.localizedCaseInsensitiveCompare($1.canonicalName) == .orderedAscending }
    }

    /// The number inside the trailing `(…)` of a fandom line, e.g.
    /// "Harry Potter - J. K. Rowling (123,456)" → 123456. nil when absent.
    static func trailingCount(in text: String) -> Int? {
        guard let open = text.lastIndex(of: "("),
              let close = text[open...].firstIndex(of: ")") else { return nil }
        let digits = text[text.index(after: open)..<close].filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    private static func canonicalizeFandomName(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// One tag in the works-listing filter sidebar, with its work count.
public struct AO3TagFacet: Sendable, Hashable {
    public let name: String
    public let count: Int
}

/// The faceted filter sidebar AO3 renders on a works listing
/// (`/tags/<tag>/works`): the most-used relationships, characters, fandoms, and
/// additional tags within that scope, each with a count. Drives the live
/// "Popular ships / characters" lists.
public struct AO3WorkFilters: Sendable {
    public let relationships: [AO3TagFacet]
    public let characters: [AO3TagFacet]
    public let fandoms: [AO3TagFacet]
    public let freeforms: [AO3TagFacet]
}

enum WorkFiltersParser {
    static func parse(html: String) throws -> AO3WorkFilters {
        let doc = try SwiftSoup.parse(html)
        return AO3WorkFilters(
            relationships: facets(in: doc, kind: "relationship"),
            characters: facets(in: doc, kind: "character"),
            fandoms: facets(in: doc, kind: "fandom"),
            freeforms: facets(in: doc, kind: "freeform")
        )
    }

    /// Each facet is a checkbox label in the sidebar's "Include" half. Live
    /// AO3 ids are `include_work_search_<kind>_ids_<tag id>` with the name and
    /// count together in a plain span — `<span>Sherlock Holmes/John Watson
    /// (57746)</span>` — while older markup used `include_<kind>_ids_<n>` with
    /// the count in `span.count`; match both. Must stay anchored on
    /// `include_`: the "Exclude" half repeats every tag under
    /// `exclude_work_search_…` ids, and a bare contains-match would return
    /// each facet twice.
    private static func facets(in doc: Document, kind: String) -> [AO3TagFacet] {
        let labels = (try? doc.select("label[for^=include_][for*=_\(kind)_ids_]").array()) ?? []
        var result: [AO3TagFacet] = []
        for label in labels {
            let full = ((try? label.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var name = full
            var count = 0
            // Trailing "(N)" is the work count; only strip it when it parses
            // as a number, since tag names themselves can end in parentheses
            // ("Sherlock (BBC TV 2010)" has a count, "Ocean's (Movies)" may not).
            if let open = full.lastIndex(of: "("),
               let parsed = MediaCategoryParser.trailingCount(in: full) {
                count = parsed
                name = String(full[..<open]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !name.isEmpty else { continue }
            result.append(AO3TagFacet(name: name, count: count))
        }
        return result
    }
}
