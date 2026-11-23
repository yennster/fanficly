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

    enum Outcome: Equatable {
        /// The saved copy now matches AO3; `added` chapters are new.
        case updated(added: Int)
        /// AO3 has fewer chapters than the saved copy (the author deleted or
        /// merged some): nothing is replaced, so no saved text is lost.
        case keptLonger(saved: Int, onAO3: Int)
    }

    /// Saves `fetched` over a library work's chapters, unless AO3 now has
    /// fewer than are saved: an update never throws away offline text
    /// (as an EPUB import never replaces more chapters with fewer). The
    /// follow's and the subscription's new-chapter baselines move to AO3's
    /// count, as the poller's next check would set them: chapters already
    /// saved don't alert, and a baseline above AO3's (chapters deleted
    /// there) doesn't keep offering an update that brings nothing.
    @MainActor
    static func apply(_ fetched: AO3WorkPayload, to work: Work, in context: ModelContext) -> Outcome {
        let saved = work.chapters.count
        let onAO3 = fetched.chapters.count
        if onAO3 < saved { return .keptLonger(saved: saved, onAO3: onAO3) }
        _ = WorkPersistence.upsert(payload: fetched, into: context)
        let count = fetched.summary.chapterCount
        if work.lastSeenChapterCount != nil { work.lastSeenChapterCount = count }
        let key = "work:\(work.ao3Id)"
        let descriptor = FetchDescriptor<SubscriptionRecord>(predicate: #Predicate { $0.key == key })
        if let record = (try? context.fetch(descriptor))?.first, record.lastSeenChapterCount != nil {
            record.lastSeenChapterCount = count
        }
        try? context.save()
        return .updated(added: max(0, onAO3 - saved))
    }

    /// "1 new chapter on AO3", "3 new chapters on AO3".
    static func bannerText(count: Int) -> String {
        count == 1 ? "1 new chapter on AO3" : "\(count) new chapters on AO3"
    }
}
