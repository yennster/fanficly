import SwiftUI

/// The reader's turn and scroll keys. Hardware keyboards send them, and so do
/// Bluetooth page turners and scroll remotes (rings, clickers, foot pedals),
/// which pair as keyboards and send arrows, Page Up / Page Down or Space.
/// Remotes that pair as a mouse or a touch screen need nothing here: their
/// taps and swipes already land on the tap-to-turn zones and the scroll views.
enum ReaderKey: Equatable {
    case left, right, up, down, pageUp, pageDown, space

    init?(_ key: KeyEquivalent) {
        switch key {
        case .leftArrow: self = .left
        case .rightArrow: self = .right
        case .upArrow: self = .up
        case .downArrow: self = .down
        case .pageUp: self = .pageUp
        case .pageDown: self = .pageDown
        case .space: self = .space
        default: return nil
        }
    }

    static var all: Set<KeyEquivalent> { [.leftArrow, .rightArrow, .upArrow, .downArrow, .pageUp, .pageDown, .space] }
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

    /// Nil for a key the reader doesn't use, or any modifier but Shift+Space
    /// (back a screen), so ⌘ shortcuts pass through.
    static func action(for key: ReaderKey, shift: Bool, otherModifiers: Bool, mode: ReadingMode) -> ReaderKeyAction? {
        guard !otherModifiers, !shift || key == .space else { return nil }
        let forward: Bool
        switch key {
        case .right, .down, .pageDown: forward = true
        case .left, .up, .pageUp: forward = false
        case .space: forward = !shift
        }
        switch mode {
        case .pageByPage:
            return .turnPage(forward: forward)
        case .paginated:
            switch key {
            case .left, .right: return .turnChapter(forward: forward)
            case .up, .down: return .scrollLine(forward: forward)
            case .pageUp, .pageDown, .space: return .scrollScreen(forward: forward)
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

struct ReaderKeyPressModifier: ViewModifier {
    let mode: ReadingMode
    @FocusState.Binding var isReaderFocused: Bool
    let perform: (ReaderKeyAction) -> Void

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($isReaderFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: ReaderKey.all) { press in
                guard let key = ReaderKey(press.key),
                      let action = ReaderKeyAction.action(
                        for: key,
                        shift: press.modifiers.contains(.shift),
                        otherModifiers: !press.modifiers.subtracting([.shift, .capsLock, .numericPad, .function]).isEmpty,
                        mode: mode)
                else { return .ignored }
                perform(action)
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
