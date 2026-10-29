import SwiftUI
import SwiftData

/// First-launch 17+ confirmation. Presented full-screen over `RootView` until
/// the user confirms. Part of the App Store guideline 1.2 safeguards: the app
/// surfaces user-generated fiction that can include mature themes.
struct AgeGateView: View {
    @AppStorage(ContentControl.ageConfirmedKey) private var ageConfirmed: Bool = false
    @State private var showingPolicy = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "book.closed.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Welcome to Fanficly")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("Fanficly is a reader for fiction published on Archive of Our Own. Some works contain mature themes. You must be **17 or older** to continue.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Spacer()
            VStack(spacing: 12) {
                Button {
                    ageConfirmed = true
                } label: {
                    Text("I'm 17 or older")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)

                Button("Read the content policy") { showingPolicy = true }
                    .font(.subheadline)
            }
            .padding(.horizontal)
            Text("By continuing you agree to the content policy and the standard Apple licensed-application terms.")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .padding(.horizontal)
        }
        .padding()
        .sheet(isPresented: $showingPolicy) {
            NavigationStack { ContentPolicyView() }
        }
    }
}

/// Lists works the user has hidden, with swipe-to-unhide.
struct HiddenWorksView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \HiddenWork.hiddenAt, order: .reverse) private var hidden: [HiddenWork]

    var body: some View {
        Group {
            if hidden.isEmpty {
                ContentUnavailableView(
                    "Nothing hidden",
                    systemImage: "eye",
                    description: Text("Use the … menu on a work and choose “Hide this work” to keep it out of your search and browse results.")
                )
            } else {
                List {
                    ForEach(hidden) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title.isEmpty ? "Work #\(item.ao3Id)" : item.title)
                            Text("Hidden \(item.hiddenAt.formatted(.relative(presentation: .named)))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .swipeActions {
                            Button {
                                HiddenWorkStore.unhide(ao3Id: item.ao3Id, in: context)
                            } label: {
                                Label("Unhide", systemImage: "eye")
                            }
                            .tint(.accentColor)
                        }
                    }
                }
            }
        }
        .navigationTitle("Hidden works")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The content policy / acceptable-use statement shown from Settings and the
/// age gate. Documents the moderation commitment App Review expects.
struct ContentPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Content policy")
                    .font(.title2).bold()

                section(
                    "Where the writing comes from",
                    "Fanficly is a reader for works published on Archive of Our Own (AO3). All stories are created and hosted by AO3 and its users. Fanficly is not affiliated with AO3 or the Organization for Transformative Works, and does not host, edit, or moderate the works itself."
                )
                section(
                    "No objectionable content",
                    "We do not tolerate content that is illegal or that sexualizes minors. Works are rated by their authors; Fanficly lets you filter Mature and Explicit ratings, hide any individual work, and block tags and authors."
                )
                section(
                    "Reporting",
                    "Every work has a “Report this work” action (in the … menu) that opens AO3's official abuse-report form — AO3 is the host and can remove content. You can also email us, and we review reports about the app within 24 hours."
                )
                section(
                    "Your controls",
                    "• Mature/Explicit filtering (Settings → Content & Safety).\n• Hide any work from your results.\n• Block tags and authors (Settings → Content & Safety).\n• You confirmed you are 17 or older on first launch."
                )

                Link("Email the developer", destination: SettingsView.feedbackMailto)
                    .font(.subheadline)
                    .padding(.top, 4)
            }
            .padding()
        }
        .navigationTitle("Content policy")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(body).foregroundStyle(.secondary)
        }
    }
}

/// Long-press menu that blocks or unblocks a tag or author (RM-006), used on
/// the reader's tag chips and byline. It only changes data, so it presents
/// nothing from the menu.
private struct BlockTermMenu: ViewModifier {
    @Environment(\.modelContext) private var context
    @Query private var matches: [BlockedTerm]
    let kind: BlockedTermKind
    let value: String

    init(kind: BlockedTermKind, value: String) {
        self.kind = kind
        self.value = value
        let key = BlockedTerm.key(kind: kind.rawValue, value: value)
        _matches = Query(filter: #Predicate<BlockedTerm> { $0.key == key })
    }

    func body(content: Content) -> some View {
        let isBlocked = !matches.isEmpty
        content.contextMenu {
            if isBlocked {
                Button {
                    BlocklistStore.unblock(kind, value, in: context)
                    iCloudSyncManager.shared.queueBackup(context: context)
                } label: {
                    Label(kind == .tag ? "Unblock this tag" : "Unblock this author", systemImage: "eye")
                }
            } else {
                Button(role: .destructive) {
                    BlocklistStore.block(kind, value, into: context)
                    iCloudSyncManager.shared.queueBackup(context: context)
                } label: {
                    Label(kind == .tag ? "Block this tag" : "Block this author", systemImage: "nosign")
                }
            }
        }
    }
}

extension View {
    /// Adds the block/unblock long-press menu for a tag or author.
    func blockTermMenu(_ kind: BlockedTermKind, _ value: String) -> some View {
        modifier(BlockTermMenu(kind: kind, value: value))
    }
}

/// Settings → Content & Safety → Blocked tags & authors: the blocklist, with
/// swipe-to-unblock and a field to add a tag or author by name.
struct BlockedTermsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \BlockedTerm.createdAt, order: .reverse) private var terms: [BlockedTerm]
    @State private var newValue = ""
    @State private var newKind: BlockedTermKind = .tag

    var body: some View {
        List {
            Section {
                Picker("Block", selection: $newKind) {
                    Text("Tag").tag(BlockedTermKind.tag)
                    Text("Author").tag(BlockedTermKind.author)
                }
                .pickerStyle(.segmented)
                HStack {
                    TextField(newKind == .tag ? "Tag name, as on AO3" : "Author's AO3 username", text: $newValue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(Blocklist.fold(newValue).isEmpty)
                }
            } footer: {
                Text("Works with a blocked tag or by a blocked author are left out of search and browse results. They still open from links, your Library, and your AO3 subscriptions and bookmarks. You can also long-press a tag or byline on a work to block it.")
            }
            ForEach(BlockedTermKind.allCases, id: \.self) { kind in
                let items = terms.filter { $0.kind == kind.rawValue }
                if !items.isEmpty {
                    Section(kind == .tag ? "Tags" : "Authors") {
                        ForEach(items) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.value)
                                Text("Blocked \(item.createdAt.formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .swipeActions {
                                Button {
                                    unblock(item)
                                } label: {
                                    Label("Unblock", systemImage: "eye")
                                }
                                .tint(.accentColor)
                            }
                            .accessibilityAction(named: "Unblock") { unblock(item) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Blocked tags & authors")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func add() {
        let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        BlocklistStore.block(newKind, value, into: context)
        iCloudSyncManager.shared.queueBackup(context: context)
        newValue = ""
    }

    private func unblock(_ item: BlockedTerm) {
        guard let kind = BlockedTermKind(rawValue: item.kind) else { return }
        BlocklistStore.unblock(kind, item.value, in: context)
        iCloudSyncManager.shared.queueBackup(context: context)
    }
}

/// "Nothing to show" for a result list whose loaded rows are all filtered out
/// (hidden, blocked or Mature). Infinite scroll only fires from a visible
/// row, so when more pages remain this offers them with a button instead of
/// leaving a dead end. Appearing, it fetches the next page itself (#155):
/// `loadMore` keeps going through pages the filter hides entirely, up to
/// `LoadMoreState.hiddenPageLimit` of them, before the button takes over.
struct FilteredOutView: View {
    let message: String
    let canLoadMore: Bool
    let isLoadingMore: Bool
    /// Why the last next-page load failed, shown under the message (#154).
    var loadMoreError: String? = nil
    /// That failure was an expired AO3 session and no one has signed in since.
    var sessionExpired = false
    let loadMore: @MainActor () async -> Void
    /// Fetch by itself once; reappearing (a tab switch) leaves it to the button.
    @State private var autoLoaded = false

    var body: some View {
        Group {
            if let loadMoreError, sessionExpired {
                SessionExpiredView(message: loadMoreError)
            } else {
                nothingToShow
            }
        }
        // Unstructured like the rows' infinite scroll, so the request isn't
        // cancelled when the first visible row replaces this view.
        .onAppear {
            if !autoLoaded, canLoadMore, loadMoreError == nil, !isLoadingMore {
                autoLoaded = true
                Task { await loadMore() }
            }
        }
    }

    private var nothingToShow: some View {
        ContentUnavailableView {
            Label("Nothing to show", systemImage: "eye.slash")
        } description: {
            Text(message)
            if let loadMoreError {
                Text(loadMoreError)
            }
        } actions: {
            if canLoadMore {
                if isLoadingMore {
                    ProgressView()
                } else if loadMoreError != nil {
                    Button("Try Again") { Task { await loadMore() } }
                } else {
                    Button("Load more results") { Task { await loadMore() } }
                }
            }
        }
    }
}

/// Next-page bookkeeping for the infinite-scroll lists (#154). A failed page
/// gets its own error, shown under the rows by `LoadMoreFooter`, so the
/// loaded rows stay put; and each page-1 load bumps the generation, so a
/// next page still in flight from the old list is dropped, not appended.
///
/// A next page the content filter hides entirely adds no row for infinite
/// scroll to fire on, so the list's `loadMore` fetches the one after it
/// itself, one page at a time (the throttle holds), and stops after
/// `hiddenPageLimit` such pages in a row; then the footer's Load More (or
/// `FilteredOutView`'s button) picks up (#155).
struct LoadMoreState: Equatable {
    /// Hidden pages fetched in a row before asking the reader.
    static let hiddenPageLimit = 3

    private(set) var generation = 0
    private(set) var error: String?
    /// Next pages in a row the content filter hid completely, while more remain.
    private(set) var hiddenPages = 0

    /// Fetching stopped on hidden pages with more to load: offer Load More.
    var stoppedOnHiddenPages: Bool { hiddenPages >= Self.hiddenPageLimit }

    /// A fresh page-1 load (a new search, new filters, a refresh): forget the
    /// footer error and make every next-page load in flight stale.
    mutating func restart() {
        generation += 1
        error = nil
        hiddenPages = 0
    }

    /// A new run of next pages (a row came into view, or Load More): allow
    /// another `hiddenPageLimit` hidden pages.
    mutating func resume() {
        hiddenPages = 0
    }

    /// Records a next page that landed and how many rows it added after
    /// filtering. Returns true when the filter hid all of it, more pages
    /// remain and the limit isn't reached: fetch the next page now.
    mutating func landed(newRows: Int, hasMore: Bool) -> Bool {
        hiddenPages = newRows == 0 && hasMore ? hiddenPages + 1 : 0
        return hiddenPages > 0 && hiddenPages < Self.hiddenPageLimit
    }

    /// Starts a next-page load; check the response with `isCurrent` against
    /// the generation this returns.
    mutating func begin() -> Int {
        error = nil
        return generation
    }

    func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation
    }

    /// Records a failed next-page load. Returns false (and records nothing)
    /// when a page-1 load replaced the list meanwhile.
    @discardableResult
    mutating func fail(_ message: String, generation: Int) -> Bool {
        guard isCurrent(generation) else { return false }
        error = message
        return true
    }
}

/// The row under an infinite-scroll list: a spinner while the next page
/// loads, or why it failed with Try Again (Sign In Again for an expired
/// session). Infinite scroll won't fire again from a row that's already on
/// screen, so after a failure this button is the way on (#154), and so is
/// Load More after a run of pages the content filter hid entirely (#155).
struct LoadMoreFooter: View {
    let isLoadingMore: Bool
    let error: String?
    /// The failure was an expired AO3 session and no one has signed in since.
    var sessionExpired = false
    /// `LoadMoreState.stoppedOnHiddenPages`.
    var stoppedOnHiddenPages = false
    let retry: @MainActor () async -> Void

    var body: some View {
        if isLoadingMore {
            HStack { Spacer(); ProgressView(); Spacer() }
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
        } else if let error, sessionExpired {
            SessionExpiredView(message: error)
                .listRowSeparator(.hidden)
        } else if let error {
            VStack(alignment: .leading, spacing: 6) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Try Again") { Task { await retry() } }
                    .buttonStyle(.borderless)
            }
            .padding(.vertical, 8)
        } else if stoppedOnHiddenPages {
            VStack(alignment: .leading, spacing: 6) {
                Text("The last few pages are hidden by your content settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Load More") { Task { await retry() } }
                    .buttonStyle(.borderless)
            }
            .padding(.vertical, 8)
        }
    }
}
