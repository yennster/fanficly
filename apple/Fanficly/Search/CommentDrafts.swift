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

    /// Forgets the draft once `posted` went up, unless the stored text has
    /// changed since (a newer comment typed meanwhile).
    func clearIfPosted(_ posted: String, workId: Int, chapterId: Int?) {
        let key = Key(workId: workId, chapterId: chapterId)
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let text = drafts[key], trim(text) == trim(posted) { drafts[key] = nil }
    }
}

/// A comment POST that failed after it went out, so AO3 may have saved the
/// comment anyway (the Windows app's `CommentPostUncertainException`). Thrown
/// only by `postComment`'s POST step: the same failure on the comment page's
/// GET before it is an ordinary `AO3Error`, since nothing was sent (#204).
struct CommentPostUncertain: Error, LocalizedError, Equatable {
    let underlying: AO3Error

    var errorDescription: String? { underlying.localizedDescription }

    /// A dropped connection or timeout, or a server error. A 4xx, a rate limit
    /// or a block means AO3 turned the POST down.
    static func mayHaveReachedAO3(_ error: AO3Error) -> Bool {
        switch error {
        case .network: true
        case .http(let status): status >= 500
        default: false
        }
    }
}

/// The sentence the comment composer shows when posting fails, worded by what
/// went wrong (the Windows app's `CommentPostError`, same words). An expired
/// login is the view's own message, since each app says where to log in.
enum CommentPostError {
    /// After a failure that can come once AO3 already has the comment, so
    /// posting again straight away could post it twice.
    static let mayHavePosted = "It may have been posted anyway, so refresh the comments before trying again."

    static func message(for error: Error) -> String {
        // AO3's own reason ("Couldn't save comment! …") or "AO3 didn't
        // confirm…", already a full sentence that says what to do.
        if case .commentRejected(let message)? = error as? AO3Error {
            return sentence(message)
        }
        let message = "Couldn't post. \(sentence(error.localizedDescription))"
        return error is CommentPostUncertain ? "\(message) \(mayHavePosted)" : message
    }

    /// Ends the text with one full stop, so "error." never reads "error..".
    static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "Something went wrong." }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }
}
