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
/// `HandleKey`, except that Up / Down also turn the page in page-by-page
/// (several remotes only send those) and step a paragraph rather than 48pt
/// in the scrolling modes (SwiftUI on iOS 17 can only scroll to a view).
enum ReaderKeyAction: Equatable {
    /// Page-by-page: the next or previous page (or spread).
    case turnPage(forward: Bool)
    /// Swipe by chapter's arrow keys: the next or previous chapter.
    case turnChapter(forward: Bool)
    /// About a screenful; in swipe by chapter, the chapter turns at its edge.
    case scrollScreen(forward: Bool)
    /// One paragraph.
    case scrollParagraph(forward: Bool)

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
            case .up, .down: return .scrollParagraph(forward: forward)
            case .pageUp, .pageDown, .space: return .scrollScreen(forward: forward)
            }
        case .continuous:
            switch key {
            case .up, .down: return .scrollParagraph(forward: forward)
            default: return .scrollScreen(forward: forward)
            }
        }
    }
}

/// A scroll asked of the visible scroll view (continuous, or swipe by
/// chapter's current page), which owns the `ScrollViewProxy`.
struct ReaderScrollRequest: Equatable {
    let screenful: Bool
    let forward: Bool
    let id = UUID()
}

extension ChapterTracking {
    /// The paragraph to scroll to the top for a key scroll, from the
    /// paragraph tops reported in the scroll view (`offsets`). A screenful
    /// brings up the last paragraph starting within 90% of the viewport below
    /// the current top paragraph (back: the first one starting within 90%
    /// above it), so a line or two stays in view; when none does (a paragraph
    /// taller than the screen), it moves one paragraph. Nil at the ends.
    static func scrollTarget(_ offsets: [String: CGFloat], viewportHeight: CGFloat,
                             forward: Bool, screenful: Bool, threshold: CGFloat = 80) -> ReadingAnchor? {
        guard !offsets.isEmpty else { return nil }
        let passed = offsets.values.filter { $0 <= threshold }
        let current = passed.max() ?? offsets.values.min() ?? 0
        let reach = max(viewportHeight * 0.9, 1)
        let pick: (key: String, value: CGFloat)?
        if forward {
            let below = offsets.filter { $0.value > current + 1 }
            let inReach = below.filter { $0.value <= current + reach }
            pick = (screenful ? inReach.max(by: { $0.value < $1.value }) : nil)
                ?? below.min(by: { $0.value < $1.value })
        } else {
            let above = offsets.filter { $0.value < current - 1 }
            let inReach = above.filter { $0.value >= current - reach }
            pick = (screenful ? inReach.min(by: { $0.value < $1.value }) : nil)
                ?? above.max(by: { $0.value < $1.value })
        }
        return pick.flatMap { parse($0.key) }
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

/// Runs a key scroll in the scroll view that owns `proxy`. A ViewModifier so
/// its onChange is type-checked outside ReaderView's long body chains.
struct ReaderScrollRequestModifier: ViewModifier {
    let request: ReaderScrollRequest?
    let perform: (ReaderScrollRequest) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: request) { _, request in
            if let request { perform(request) }
        }
    }
}
