import SwiftUI
import UIKit // UIAccessibility (announcement, VoiceOver check)

/// One-tap deletes wait behind an Undo toast (#169). A delete schedules its
/// work here instead of running it: the row leaves its list at once (lists
/// skip `isPending` keys), a "Deleted 'X' · Undo" toast shows at the bottom of
/// the window, and the delete only runs when the toast closes. Undo drops it
/// and the row comes back untouched, with its offline text, EPUB, notes, tags
/// and folders. On the Mac (and with an iPad keyboard) ⌘Z undoes it too,
/// through the scene's `UndoManager`.
///
/// One delete waits at a time: scheduling another runs the one before it
/// first. The app going to the background runs it too (`FanficlyApp`), so a
/// delete never waits on a suspended app. If the app is killed while the
/// toast is up, the delete simply never happened, which loses nothing.
@MainActor @Observable
final class UndoCenter {
    static let shared = UndoCenter()

    struct Pending: Identifiable {
        let id = UUID()
        let message: String
        let keys: Set<String>
        /// Runs when the toast closes (a delete that waits).
        let commit: (@MainActor () -> Void)?
        /// Runs on Undo (a delete that already happened, see `offer`).
        let revert: (@MainActor () -> Void)?
        /// The toast host the delete came from (`\.undoToastHost`).
        let host: UUID?
    }

    struct Host {
        let parent: UUID?
        weak var undoManager: UndoManager?
    }

    private(set) var pending: Pending?
    /// Toast hosts on screen: each window's root, and any sheet that
    /// deletes (its parent is the host it sits in). The toast shows in the
    /// host its delete came from, so in that window and over that sheet; once
    /// a sheet closes, in the host under it.
    private(set) var hosts: [UUID: Host] = [:]

    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private weak var undoManager: UndoManager?
    private let delay: Duration?

    /// `delay` is how long the toast stays up; nil picks it from
    /// `defaultDelay` each time (longer with VoiceOver running).
    init(delay: Duration? = nil) {
        self.delay = delay
    }

    /// Long enough to read the toast and reach Undo. VoiceOver reads the
    /// announcement first and then has to find the button, so it gets longer.
    static var defaultDelay: Duration {
        UIAccessibility.isVoiceOverRunning ? .seconds(12) : .seconds(6)
    }

    func isPending(_ key: String) -> Bool {
        pending?.keys.contains(key) ?? false
    }

    /// Hides `keys` from their lists and runs `commit` when the toast closes,
    /// unless Undo is pressed first. `commit` must check its objects still
    /// exist: an iCloud restore can delete them while the toast is up.
    /// `host` is the view's `\.undoToastHost`, which also gives the window's
    /// `UndoManager` (⌘Z) unless one is passed.
    func schedule(_ message: String, keys: Set<String>, host: UUID? = nil, undoManager: UndoManager? = nil,
                  commit: @escaping @MainActor () -> Void) {
        show(Pending(message: message, keys: keys, commit: commit, revert: nil, host: host), undoManager: undoManager)
    }

    /// Drops a waiting delete without undoing anything because `key` is
    /// being saved again (a search or filter saved under the same name, a
    /// folder made again, a deleted work saved or followed again): the newest
    /// intent wins, and the delete never runs or writes its tombstone.
    func cancel(_ key: String) {
        guard isPending(key) else { return }
        finish()
    }

    /// For a delete that has already happened and is cheap to put back (a
    /// reader profile, a plain value whose deletion syncs as a tombstone):
    /// shows the same toast, and Undo runs `revert`.
    func offer(_ message: String, host: UUID? = nil, undoManager: UndoManager? = nil,
               revert: @escaping @MainActor () -> Void) {
        show(Pending(message: message, keys: [], commit: nil, revert: revert, host: host), undoManager: undoManager)
    }

    private func show(_ item: Pending, undoManager: UndoManager?) {
        commitPending()
        let undoManager = undoManager ?? liveHost(from: item.host).flatMap { hosts[$0]?.undoManager }
        let message = item.message
        let id = item.id
        withAnimation(.easeInOut(duration: 0.2)) { pending = item }

        if let undoManager {
            undoManager.registerUndo(withTarget: self) { center in
                MainActor.assumeIsolated { center.undo(id) }
            }
            undoManager.setActionName(String(localized: "Delete"))
            self.undoManager = undoManager
        }
        UIAccessibility.post(notification: .announcement,
                             argument: String(localized: "\(message). Undo is available."))

        let wait = delay ?? Self.defaultDelay
        timer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.commit(id)
        }
    }

    /// Drops the waiting delete; its rows come back.
    func undo() {
        guard let pending else { return }
        undo(pending.id)
    }

    /// Runs the waiting delete now, if there is one.
    func commitPending() {
        guard let pending else { return }
        commit(pending.id)
    }

    private func undo(_ id: UUID) {
        guard let item = pending, item.id == id else { return }
        finish()
        item.revert?()
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Undone"))
    }

    private func commit(_ id: UUID) {
        guard let item = pending, item.id == id else { return }
        finish()
        item.commit?()
    }

    private func finish() {
        timer?.cancel()
        timer = nil
        undoManager?.removeAllActions(withTarget: self)
        undoManager = nil
        withAnimation(.easeInOut(duration: 0.2)) { pending = nil }
    }

    func addHost(_ id: UUID, parent: UUID?, undoManager: UndoManager?) {
        hosts[id] = Host(parent: parent, undoManager: undoManager)
        if let parent { parentOf[id] = parent }
    }

    func removeHost(_ id: UUID) {
        hosts[id] = nil
    }

    /// Parents of every host that has been on screen, kept after it leaves
    /// so a closed sheet's delete finds the host under it. One small entry
    /// per sheet shown.
    @ObservationIgnored private var parentOf: [UUID: UUID] = [:]

    /// The host on screen nearest to `id`: itself, or the host it sat in.
    private func liveHost(from id: UUID?) -> UUID? {
        var current = id
        var seen = Set<UUID>()
        while let candidate = current, seen.insert(candidate).inserted {
            if hosts[candidate] != nil { return candidate }
            current = parentOf[candidate]
        }
        return nil
    }

    /// Where the waiting delete's toast shows. A delete with no host (or
    /// whose hosts have all gone) shows in any window root.
    func showsToast(in id: UUID) -> Bool {
        guard let pending else { return false }
        if let host = liveHost(from: pending.host) { return host == id }
        let roots = hosts.filter { $0.value.parent == nil }.keys
        return roots.min(by: { $0.uuidString < $1.uuidString }) == id
    }

    /// Keys for the records a delete hides. Lists check these with `isPending`.
    enum Key {
        static func work(_ ao3Id: Int) -> String { "work:\(ao3Id)" }
        static func folder(_ name: String) -> String { "folder:\(name)" }
        static func search(_ name: String) -> String { "search:\(name)" }
        static func filter(_ name: String) -> String { "filter:\(name)" }
        static func author(_ username: String) -> String { "author:\(username)" }
    }
}

private struct UndoToastHostKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    /// The Undo toast host this view sits in (`.undoToastHost()`). Pass it as
    /// `schedule(host:)` so the toast shows in this window, over this sheet.
    var undoToastHost: UUID? {
        get { self[UndoToastHostKey.self] }
        set { self[UndoToastHostKey.self] = newValue }
    }
}

extension View {
    /// Shows the Undo toast for deletes made inside this view. Apply once to
    /// each window's root and once inside each sheet that can delete
    /// something, since a sheet covers the window's toast.
    func undoToastHost() -> some View {
        modifier(UndoToastHost())
    }
}

private struct UndoToastHost: ViewModifier {
    @State private var id = UUID()
    @Environment(\.undoToastHost) private var parent
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let center = UndoCenter.shared
        content
            .environment(\.undoToastHost, id)
            .overlay(alignment: .bottom) {
                if let pending = center.pending, center.showsToast(in: id) {
                    UndoToast(message: pending.message) { center.undo() }
                        .id(pending.id)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onAppear { center.addHost(id, parent: parent, undoManager: undoManager) }
            .onChange(of: undoManager) { _, manager in center.addHost(id, parent: parent, undoManager: manager) }
            .onDisappear { center.removeHost(id) }
    }
}

private struct UndoToast: View {
    let message: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.subheadline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Undo", action: undo)
                .font(.subheadline.bold())
                .buttonStyle(.borderless)
                .hoverEffect(.highlight)
                .help("Undo the delete (⌘Z)")
                .accessibilityHint("Puts it back.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .frame(maxWidth: 520)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityElement(children: .contain)
    }
}
