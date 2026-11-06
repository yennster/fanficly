import Foundation
import SwiftData

/// Bringing a downloaded work up to date with AO3 (#180). The Library reader
/// reads saved chapters without asking AO3, so a work in progress would keep
/// its old ending forever; the counts the app already has (the work's own
/// metadata, the poller's new-chapter baselines) tell it when AO3 is ahead.
enum DownloadUpdate {
    /// How many chapters AO3 has that the saved copy doesn't, as far as the
    /// app knows: the highest known count minus the saved chapters. Zero
    /// when nothing is saved (that work reads live) or nothing is known.
    static func newChapterCount(saved: Int, known: [Int?]) -> Int {
        guard saved > 0, let highest = known.compactMap({ $0 }).max() else { return 0 }
        return max(0, highest - saved)
    }

    /// Every chapter count the app has for a library work: its metadata, its
    /// local follow's baseline, and its AO3 subscription's baseline.
    @MainActor
    static func knownChapterCounts(for work: Work, in context: ModelContext) -> [Int?] {
        let key = "work:\(work.ao3Id)"
        let descriptor = FetchDescriptor<SubscriptionRecord>(predicate: #Predicate { $0.key == key })
        let subscription = (try? context.fetch(descriptor))?.first
        return [work.chapterCount, work.lastSeenChapterCount, subscription?.lastSeenChapterCount]
    }

    /// `newChapterCount` for a library work.
    @MainActor
    static func newChapterCount(for work: Work, in context: ModelContext) -> Int {
        newChapterCount(saved: work.chapters.count, known: knownChapterCounts(for: work, in: context))
    }

    /// "1 new chapter on AO3", "3 new chapters on AO3".
    static func bannerText(count: Int) -> String {
        count == 1 ? "1 new chapter on AO3" : "\(count) new chapters on AO3"
    }
}
