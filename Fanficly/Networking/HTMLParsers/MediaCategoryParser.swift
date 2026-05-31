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
            if !seen.contains(canonical) {
                seen.insert(canonical)
                results.append(BrowseFandom(canonical, canonical: canonical))
            }
        }
        return results.sorted { $0.canonicalName.localizedCaseInsensitiveCompare($1.canonicalName) == .orderedAscending }
    }

    private static func canonicalizeFandomName(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
