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
        let commit: @MainActor () -> Void
    }

    private(set) var pending: Pending?
    /// Toast hosts on screen, innermost last: the window, then any sheet
    /// over it. Only the innermost shows the toast, so a sheet's delete
    /// isn't hidden behind the sheet and the window doesn't show a second copy.
    private(set) var hosts: [UUID] = []

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
    func schedule(_ message: String, keys: Set<String>, undoManager: UndoManager? = nil,
                  commit: @escaping @MainActor () -> Void) {
        commitPending()
        let item = Pending(message: message, keys: keys, commit: commit)
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
        guard pending?.id == id else { return }
        finish()
        UIAccessibility.post(notification: .announcement, argument: String(localized: "Undone"))
    }

    private func commit(_ id: UUID) {
        guard let item = pending, item.id == id else { return }
        finish()
        item.commit()
    }

    private func finish() {
        timer?.cancel()
        timer = nil
        undoManager?.removeAllActions(withTarget: self)
        undoManager = nil
        withAnimation(.easeInOut(duration: 0.2)) { pending = nil }
    }

    func addHost(_ id: UUID) {
        hosts.removeAll { $0 == id }
        hosts.append(id)
    }

    func removeHost(_ id: UUID) {
        hosts.removeAll { $0 == id }
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

extension View {
    /// Shows the Undo toast over this view while it is the innermost host.
    /// Apply once to the window's root and once inside each sheet that can
    /// delete something.
    func undoToastHost() -> some View {
        modifier(UndoToastHost())
    }
}

private struct UndoToastHost: ViewModifier {
    @State private var id = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let center = UndoCenter.shared
        content
            .overlay(alignment: .bottom) {
                if let pending = center.pending, center.hosts.last == id {
                    UndoToast(message: pending.message) { center.undo() }
                        .id(pending.id)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onAppear { center.addHost(id) }
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
