import SwiftUI

/// The reader's turn and scroll keys. Hardware keyboards send them, and so do
/// Bluetooth page turners and scroll remotes (rings, clickers, foot pedals),
/// which pair as keyboards and send arrows, Page Up / Page Down or Space.
/// Remotes that pair as a touch screen need nothing here: their taps and
/// swipes land on the tap-to-turn zones and the scroll views like a finger's.
/// A mouse-mode remote's wheel scrolls the scrolling modes, but page-by-page
/// doesn't turn on the wheel yet (RM-025).
enum ReaderKey: Equatable {
    case left, right, up, down, pageUp, pageDown, space, home, end

    init?(_ key: KeyEquivalent) {
        switch key {
        case .leftArrow: self = .left
        case .rightArrow: self = .right
        case .upArrow: self = .up
        case .downArrow: self = .down
        case .pageUp: self = .pageUp
        case .pageDown: self = .pageDown
        case .space: self = .space
        case .home: self = .home
        case .end: self = .end
        default: return nil
        }
    }

    static var all: Set<KeyEquivalent> {
        [.leftArrow, .rightArrow, .upArrow, .downArrow, .pageUp, .pageDown, .space, .home, .end]
    }
}

/// What a reader key does, by reading mode. Mirrors the Windows reader's
/// `HandleKey`, Up / Down turning the page in page-by-page included (several
/// remotes only send those).
enum ReaderKeyAction: Equatable {
    /// Page-by-page: the next or previous page (or spread).
    case turnPage(forward: Bool)
    /// Swipe by chapter's arrow keys: the next or previous chapter.
    case turnChapter(forward: Bool)
    /// 90% of a screen; in swipe by chapter, the chapter turns at its edge.
    case scrollScreen(forward: Bool)
    /// A line's worth (48pt), never turning the chapter.
    case scrollLine(forward: Bool)
    /// Home / End: the start or end of the chapter on screen, in every mode.
    case chapterEdge(end: Bool)

    /// Nil for a key the reader doesn't use, or any modifier but Shift+Space
    /// (back a screen), so ⌘ shortcuts pass through.
    static func action(for key: ReaderKey, shift: Bool, otherModifiers: Bool, mode: ReadingMode) -> ReaderKeyAction? {
        guard !otherModifiers, !shift || key == .space else { return nil }
        let forward: Bool
        switch key {
        case .right, .down, .pageDown: forward = true
        case .left, .up, .pageUp: forward = false
        case .space: forward = !shift
        case .home: return .chapterEdge(end: false)
        case .end: return .chapterEdge(end: true)
        }
        switch mode {
        case .pageByPage:
            return .turnPage(forward: forward)
        case .paginated:
            switch key {
            case .left, .right: return .turnChapter(forward: forward)
            case .up, .down: return .scrollLine(forward: forward)
            case .pageUp, .pageDown, .space, .home, .end: return .scrollScreen(forward: forward)
            }
        case .continuous:
            switch key {
            case .up, .down: return .scrollLine(forward: forward)
            default: return .scrollScreen(forward: forward)
            }
        }
    }
}

/// Key scroll arithmetic on a scroll view's content offset, as the Windows
/// reader does it (`ScrollContinuousPage`, `ScrollPaginatedPage`).
enum ReaderKeyScroll {
    static let line: CGFloat = 48

    /// The content offset to scroll to, or nil when the scroll view is already
    /// at that edge. A screenful is 90% of the visible height, so a line or
    /// two stays in view; it's clamped to the content.
    static func targetOffset(current: CGFloat, viewportHeight: CGFloat, contentHeight: CGFloat,
                             insetTop: CGFloat, insetBottom: CGFloat,
                             forward: Bool, screenful: Bool) -> CGFloat? {
        let minY = -insetTop
        let maxY = max(contentHeight + insetBottom - viewportHeight, minY)
        if forward ? current >= maxY - 1 : current <= minY + 1 { return nil }
        let visible = viewportHeight - insetTop - insetBottom
        let step = screenful ? max(line, visible * 0.9) : line
        return min(max(current + (forward ? step : -step), minY), maxY)
    }
}

/// The UIScrollViews behind the reader's SwiftUI ScrollViews, keyed by
/// chapter index for swipe by chapter's pages and `continuous` for
/// continuous scroll. iOS 17's SwiftUI can only scroll *to* a view, so key
/// scrolls move the UIScrollView itself.
@MainActor final class ReaderScrollViews {
    static let continuous = Int.min
    private var views: [Int: WeakScrollView] = [:]

    subscript(id: Int) -> UIScrollView? {
        get { views[id]?.view }
        set { views[id] = newValue.map { WeakScrollView(view: $0) } }
    }

    private struct WeakScrollView {
        weak var view: UIScrollView?
    }
}

/// Placed inside a ScrollView's content: finds the enclosing UIScrollView
/// once it's in a window and records it under `id`.
struct ReaderScrollViewFinder: UIViewRepresentable {
    let views: ReaderScrollViews
    let id: Int

    func makeUIView(context: Context) -> FinderView {
        let view = FinderView()
        view.isUserInteractionEnabled = false
        view.register = { [views, id] in views[id] = $0 }
        return view
    }

    func updateUIView(_ uiView: FinderView, context: Context) {
        uiView.register = { [views, id] in views[id] = $0 }
        uiView.findScrollView()
    }

    final class FinderView: UIView {
        var register: ((UIScrollView) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            findScrollView()
        }

        func findScrollView() {
            var view = superview
            while let current = view, !(current is UIScrollView) { view = current.superview }
            if let scrollView = view as? UIScrollView { register?(scrollView) }
        }
    }
}

/// The reader's ⌘ keys, as the Reader menu shows them on iPad and the Mac
/// (`ReaderMenuCommands`). iPhone has no menu bar, so there the reader
/// handles them itself (`ReaderKeyPressModifier`); everywhere else the menu
/// does, so a key never acts twice.
enum ReaderCommandKey: Equatable {
    /// ⌘← / ⌘→, as Ctrl+← / Ctrl+→ on Windows.
    case chapter(forward: Bool)
    /// ⌘L: Listen to the chapter, or stop (Ctrl+L on Windows).
    case listen

    /// Nil unless ⌘ (and nothing but ⌘) is held with ←, → or L.
    init?(key: KeyEquivalent, modifiers: EventModifiers) {
        guard modifiers.subtracting([.capsLock, .numericPad, .function]) == .command else { return nil }
        switch key {
        case .leftArrow: self = .chapter(forward: false)
        case .rightArrow: self = .chapter(forward: true)
        case "l", "L": self = .listen
        default: return nil
        }
    }
}

/// Home and End: where the chapter on screen starts or ends.
enum ReaderChapterEdge {
    /// Page-by-page: the first or last page of the current page's chapter,
    /// or, in a two-page spread, the spread holding it (a spread's id is its
    /// left page's). Nil when that's already the page on screen.
    static func pageId(in pages: [ChapterPage], selected: String, end: Bool, spreads: Bool) -> String? {
        guard let current = pages.first(where: { $0.id == selected }) else { return nil }
        let inChapter = pages.filter { $0.chapterIndex == current.chapterIndex }
        guard let edge = end ? inChapter.last : inChapter.first else { return nil }
        if spreads, let spread = ReaderSpread.spreads(from: pages).first(where: { $0.contains(edge.id) }) {
            return spread.contains(selected) ? nil : spread.id
        }
        return edge.id == selected ? nil : edge.id
    }
}

/// The id of a marker at the bottom of each chapter in continuous scroll,
/// which End scrolls to the bottom of the screen.
struct ChapterEndID: Hashable {
    let chapter: Int
}

/// What the Reader menu's chapter and Listen items act on: the reader in
/// front, through a focused scene value (`ReaderView` publishes it).
struct ReaderMenuActions {
    let hasPreviousChapter: Bool
    let hasNextChapter: Bool
    let isListening: Bool
    let turnChapter: @MainActor (Bool) -> Void
    let toggleListening: @MainActor () -> Void
}

private struct ReaderMenuActionsKey: FocusedValueKey {
    typealias Value = ReaderMenuActions
}

extension FocusedValues {
    var readerMenu: ReaderMenuActions? {
        get { self[ReaderMenuActionsKey.self] }
        set { self[ReaderMenuActionsKey.self] = newValue }
    }
}

/// The Reader menu's Previous / Next Chapter (⌘← / ⌘→) and Listen (⌘L),
/// enabled only while a reader is in front.
struct ReaderMenuCommands: View {
    @FocusedValue(\.readerMenu) private var reader

    var body: some View {
        Button("Previous Chapter") { reader?.turnChapter(false) }
            .keyboardShortcut(.leftArrow, modifiers: [.command])
            .disabled(reader?.hasPreviousChapter != true)
        Button("Next Chapter") { reader?.turnChapter(true) }
            .keyboardShortcut(.rightArrow, modifiers: [.command])
            .disabled(reader?.hasNextChapter != true)
        Button(reader?.isListening == true ? "Stop Listening" : "Listen to Chapter") {
            reader?.toggleListening()
        }
        .keyboardShortcut("l", modifiers: [.command])
        .disabled(reader == nil)
    }
}

struct ReaderKeyPressModifier: ViewModifier {
    let mode: ReadingMode
    @FocusState.Binding var isReaderFocused: Bool
    let perform: (ReaderKeyAction) -> Void
    /// Esc: brings hidden controls back (false when they're already up), as
    /// on Windows, so a keyboard is never left with only a tap to get out.
    let showControls: () -> Bool
    /// ⌘F: Find in this work (#183). The Reader menu has it too (Mac, iPad);
    /// this covers a keyboard on iPhone, which has no menu bar.
    let find: () -> Void
    /// ⌘← / ⌘→ and ⌘L. Only on iPhone, which has no menu bar: on iPad and
    /// the Mac the Reader menu's items take these keys (`ReaderMenuCommands`).
    let command: (ReaderCommandKey) -> Void

    @MainActor private static let handlesCommandKeys = UIDevice.current.userInterfaceIdiom == .phone

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($isReaderFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: ReaderKey.all) { press in
                // A focused control inside the reader (the Listen bar's
                // buttons) keeps its keys, like Windows' `activates` check.
                guard isReaderFocused, let key = ReaderKey(press.key),
                      let action = ReaderKeyAction.action(
                        for: key,
                        shift: press.modifiers.contains(.shift),
                        otherModifiers: !press.modifiers.subtracting([.shift, .capsLock, .numericPad, .function]).isEmpty,
                        mode: mode)
                else { return .ignored }
                perform(action)
                return .handled
            }
            .onKeyPress(keys: [.leftArrow, .rightArrow, "l"], phases: .down) { press in
                guard Self.handlesCommandKeys, isReaderFocused,
                      let key = ReaderCommandKey(key: press.key, modifiers: press.modifiers)
                else { return .ignored }
                command(key)
                return .handled
            }
            .onKeyPress("f", phases: .down) { press in
                guard isReaderFocused,
                      press.modifiers.subtracting([.capsLock, .numericPad, .function]) == .command
                else { return .ignored }
                find()
                return .handled
            }
            .onKeyPress(.escape) {
                guard isReaderFocused, showControls() else { return .ignored }
                return .handled
            }
            .onAppear {
                isReaderFocused = true
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    isReaderFocused = true
                }
            )
    }
}
