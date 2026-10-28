import SwiftUI

/// Reads a work's comment thread and, when logged in, lets you post a comment.
/// Live-fetched (no caching), presented as a sheet from the reader's options
/// menu. Posting reuses the proven CSRF-token flow (scrape the work page's
/// authenticity_token + pseud, then POST), like login and subscribe.
struct CommentsView: View {
    let workId: Int
    let workTitle: String
    /// The chapter whose thread to show/post to (AO3 comments are per-chapter).
    /// nil → work-level (first chapter), the fallback when the id is unknown.
    var chapterId: Int? = nil
    var chapterNumber: Int? = nil
    var totalChapters: Int? = nil
    @Environment(\.ao3Client) private var client
    @Environment(AuthState.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var comments: [AO3Comment] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    /// The last comment page loaded and how many AO3 has, for "Load more".
    @State private var currentPage = 1
    @State private var totalPages = 1
    @State private var isLoadingMore = false
    @State private var loadMoreError: String?
    /// Bumped by every page-1 load, so a "Load more" that finishes after a
    /// refresh or post can't append onto the reloaded list.
    @State private var loadGeneration = 0
    @State private var draft = ""
    @State private var isPosting = false
    @State private var postError: String?
    @FocusState private var composerFocused: Bool

    /// Show the chapter only for multi-chapter works; single-chapter works read
    /// plainly as "Comments".
    private var navTitle: String {
        if let chapterNumber, (totalChapters ?? 1) > 1 { return "Comments · Ch \(chapterNumber)" }
        return "Comments"
    }

    /// Per-chapter empty state names the chapter, so an empty later chapter
    /// reads as "this chapter has none" rather than "comments failed to load".
    private var emptyTitle: String {
        if let chapterNumber, (totalChapters ?? 1) > 1 { return "No comments on Chapter \(chapterNumber) yet" }
        return "No comments yet"
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && comments.isEmpty {
                    VStack { Spacer(); ProgressView("Loading comments…"); Spacer() }
                } else if let errorMessage, comments.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't load comments", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Retry") { Task { await load() } }
                    }
                } else if comments.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: "bubble.left",
                        description: Text(auth.username == nil
                            ? "Be the first to comment — log in to AO3 to post."
                            : "Be the first to comment."))
                } else {
                    List {
                        ForEach(comments) { comment in
                            CommentRow(comment: comment)
                        }
                        if currentPage < totalPages {
                            loadMoreRow
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        if isLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(isLoading)
                    .accessibilityLabel("Refresh comments")
                }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .task { await load() }
        }
    }

    private var loadMoreRow: some View {
        VStack(spacing: 6) {
            if let loadMoreError {
                Text(loadMoreError).font(.caption).foregroundStyle(.red)
            }
            Button {
                Task { await loadMore() }
            } label: {
                if isLoadingMore {
                    ProgressView()
                        .accessibilityLabel("Loading more comments")
                } else {
                    Text("Load more comments")
                }
            }
            .disabled(isLoadingMore || isLoading)
            .accessibilityHint("Page \(currentPage) of \(totalPages)")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            if auth.username == nil {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .accessibilityHidden(true)
                    Text("Log in to AO3 (Settings) to post a comment.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.bar)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let postError {
                        Text(postError).font(.caption).foregroundStyle(.red)
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        TextField("Add a comment as \(auth.username ?? "you")…", text: $draft, axis: .vertical)
                            .lineLimit(1...5)
                            .textFieldStyle(.roundedBorder)
                            .focused($composerFocused)
                            .disabled(isPosting)
                        Button {
                            Task { await post() }
                        } label: {
                            if isPosting {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.up.circle.fill").font(.title2)
                            }
                        }
                        .disabled(isPosting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Post comment")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }

    /// Loads (or reloads) the first comment page, dropping any later pages.
    private func load() async {
        isLoading = true
        errorMessage = nil
        loadMoreError = nil
        loadGeneration += 1
        defer { isLoading = false }
        do {
            let page = try await client.fetchComments(workId: workId, chapterId: chapterId, page: 1)
            comments = page.comments
            currentPage = page.currentPage
            totalPages = page.totalPages
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Appends the next comment page. Ids already shown are skipped, since a
    /// comment posted meanwhile can shift a thread onto the next page.
    private func loadMore() async {
        guard !isLoadingMore, !isLoading, currentPage < totalPages else { return }
        let generation = loadGeneration
        isLoadingMore = true
        loadMoreError = nil
        defer { isLoadingMore = false }
        do {
            let page = try await client.fetchComments(workId: workId, chapterId: chapterId, page: currentPage + 1)
            guard generation == loadGeneration else { return }
            let seen = Set(comments.map(\.id))
            let added = page.comments.filter { !seen.contains($0.id) }
            comments += added
            currentPage = max(currentPage + 1, page.currentPage)
            totalPages = page.totalPages
            AccessibilityNotification.Announcement(
                added.count == 1 ? "Loaded 1 more comment" : "Loaded \(added.count) more comments"
            ).post()
        } catch {
            guard generation == loadGeneration else { return }
            loadMoreError = "Couldn't load more comments: \(error.localizedDescription)"
            AccessibilityNotification.Announcement(loadMoreError ?? "").post()
        }
    }

    private func post() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isPosting = true
        postError = nil
        defer { isPosting = false }
        do {
            try await client.postComment(workId: workId, chapterId: chapterId, text: text)
            draft = ""
            composerFocused = false
            // Re-fetch so the new comment shows (AO3 may hold it for moderation).
            await load()
        } catch AO3Error.unauthorized {
            auth.markSessionExpired()
            postError = "Couldn't post: your AO3 login has expired. Log in again in Settings → AO3 Login, then post again. Your comment is still here."
        } catch AO3Error.commentRejected(let message) {
            postError = message
        } catch {
            postError = "Couldn't post. \(error.localizedDescription) Your comment may be awaiting moderation, or try again."
        }
    }
}

private struct CommentRow: View {
    let comment: AO3Comment

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Thread guide line for nested replies, so the indentation reads as
            // a reply rather than a stray offset.
            if comment.depth > 0 {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 2)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: comment.commenterUsername.isEmpty ? "person.crop.circle.badge.questionmark" : "person.crop.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(comment.commenterName)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if !comment.dateText.isEmpty {
                        Text(comment.dateText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                // Combine only the header (name + date); the body may carry
                // links, which combining would flatten.
                .accessibilityElement(children: .combine)
                HTMLText(html: comment.bodyHTML)
                    .font(.callout)
            }
        }
        .padding(.leading, CGFloat(min(comment.depth, 6)) * 16)
        .padding(.vertical, 2)
        .alignmentGuide(.listRowSeparatorLeading) { d in d[.leading] }
    }
}
