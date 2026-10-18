import Foundation
import SwiftSoup

public struct AO3WorkMetadata: Sendable, Equatable {
    public let id: Int
    public let chapterCount: Int
    public let totalChapters: Int?
    public let updatedAt: Date?
}

enum WorkMetadataParser {
    static func parse(html: String, workId: Int) throws -> AO3WorkMetadata {
        let doc = try SwiftSoup.parse(html)
        let stats = try doc.select("dl.stats").first()
        let chaptersText = try stats?.select("dd.chapters").first()?.text() ?? "1/1"
        let (current, total) = parseChapterFraction(chaptersText)

        let statusText = try stats?.select("dd.status").first()?.text() ?? ""
        let updatedAt = parseAO3Date(statusText)

        return AO3WorkMetadata(
            id: workId,
            chapterCount: current,
            totalChapters: total,
            updatedAt: updatedAt
        )
    }

    private static func parseChapterFraction(_ s: String) -> (current: Int, total: Int?) {
        let parts = s.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        let current = Int(parts.first ?? "1") ?? 1
        let total: Int?
        if parts.count > 1, parts[1] == "?" {
            total = nil
        } else if parts.count > 1, let n = Int(parts[1]) {
            total = n
        } else {
            total = current
        }
        return (current, total)
    }

    private static func parseAO3Date(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: trimmed)
    }
}
