import Foundation

/// Unposted comment text, per work and chapter, for as long as the app runs.
/// Done or a swipe down closes the comments sheet without asking, so the text
/// lives here rather than only in the composer: reopening the same chapter's
/// comments brings it back (#204). Kept in memory only, never written to disk,
/// and cleared once the comment posts. The Windows app's `CommentDrafts`.
@MainActor
final class CommentDrafts {
    static let shared = CommentDrafts()

    private struct Key: Hashable {
        let workId: Int
        let chapterId: Int?
    }

    private var drafts: [Key: String] = [:]

    /// The draft for a thread, or "" when there is none.
    func text(workId: Int, chapterId: Int?) -> String {
        drafts[Key(workId: workId, chapterId: chapterId)] ?? ""
    }

    /// Stores the composer's text; blank text forgets the draft.
    func set(_ text: String, workId: Int, chapterId: Int?) {
        let key = Key(workId: workId, chapterId: chapterId)
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            drafts[key] = nil
        } else {
            drafts[key] = text
        }
    }

    func clear(workId: Int, chapterId: Int?) {
        set("", workId: workId, chapterId: chapterId)
    }
}

/// The sentence the comment composer shows when posting fails, worded by what
/// went wrong (the Windows app's `CommentPostError`, same words). An expired
/// login is the view's own message, since each app says where to log in.
enum CommentPostError {
    /// After a failure that can come once AO3 already has the comment, so
    /// posting again straight away could post it twice.
    static let mayHavePosted = "It may have been posted anyway, so refresh the comments before trying again."

    /// Failures where the POST may have reached AO3: a timeout, a dropped
    /// connection or an HTTP error. A rate limit, a block or a missing comment
    /// form all stop the comment before AO3 takes it.
    static func mayHaveBeenSent(_ error: Error) -> Bool {
        switch error as? AO3Error {
        case .network?, .http?: true
        case .some: false
        case nil: error is URLError
        }
    }

    static func message(for error: Error) -> String {
        // AO3's own reason ("Couldn't save comment! …") or "AO3 didn't
        // confirm…", already a full sentence that says what to do.
        if case .commentRejected(let message)? = error as? AO3Error {
            return sentence(message)
        }
        let message = "Couldn't post. \(sentence(error.localizedDescription))"
        return mayHaveBeenSent(error) ? "\(message) \(mayHavePosted)" : message
    }

    /// Ends the text with one full stop, so "error." never reads "error..".
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "Something went wrong." }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}
