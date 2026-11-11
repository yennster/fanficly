import SwiftUI
import UIKit

/// Lays the reader out under iPhone Duo's side column, as Apple Books does.
/// There the status bar and the toolbar strip sit in a column on one side of
/// the screen, which comes in as a safe-area inset on that side only. Kept
/// clear, it was blank beside the page (and stayed blank in full screen,
/// since the page holds still); Books runs its page under it and lets the
/// controls float over the page. In the scrolling modes the text stays
/// clear of the column (`SideColumn`'s widths, see
/// ReaderMetrics.textColumnPlacement). Page-by-page's text runs under it, as
/// Books' does: kept clear, full screen left the column's room blank beside
/// the text (#360), and the strip covers line ends only while the controls
/// show.
///
/// Only on the phone idiom (the Duo is one on both displays) at a regular
/// height, and only a side whose inset the other side doesn't match. An
/// iPhone in landscape (a compact height) keeps the insets around its sensor
/// housing, which needn't match on both sides. A sidebar's inset is wider
/// than any strip and is kept too. An open book (a two-page spread, the Duo
/// unfolded) runs under it too, so its pages sit evenly about the fold as in
/// Books; its cells need PagingInsetsOff like one page's, or the paging
/// view's content inset leaves the spread a column's width to the left
/// after a page turn.
struct RunUnderSideColumn: ViewModifier {
    /// False keeps every inset.
    let enabled: Bool
    /// The controls are hidden: hiding the status bar may take the column's
    /// inset away, so the page keeps running under it until they're back, or
    /// for one layout pass on showing them the page would narrow.
    let controlsHidden: Bool
    /// The sides run under, and how wide the column is there. Views inside
    /// that lay out their own content by the safe area (the bottom bars)
    /// ignore those sides too, or they'd keep the column clear inside the
    /// wider frame. The pages' paging scroll view is UIKit and needs
    /// PagingInsetsOff.
    @Binding var column: SideColumn

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Wider than this, a side inset isn't the Duo's column.
    nonisolated static let maxColumnWidth: CGFloat = 100

    func body(content: Content) -> some View {
        content
            .ignoresSafeArea(.container, edges: column.edges)
            // Measured around the content, which reports its insets the same
            // whether or not it runs into them.
            .background {
                GeometryReader { geo in
                    let insets = geo.safeAreaInsets
                    let edges = enabled
                        ? Self.columnEdges(insets, isPhone: Self.isPhone,
                                           compactHeight: verticalSizeClass == .compact)
                        : []
                    let measured = SideColumn(edges: edges,
                                              leading: edges.contains(.leading) ? ceil(insets.leading) : 0,
                                              trailing: edges.contains(.trailing) ? ceil(insets.trailing) : 0)
                    Color.clear
                        .onChange(of: measured, initial: true) { _, value in
                            if !(enabled && controlsHidden && value.edges.isEmpty) { column = value }
                        }
                }
            }
    }

    private static var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    nonisolated static func columnEdges(_ insets: EdgeInsets, isPhone: Bool, compactHeight: Bool) -> Edge.Set {
        guard isPhone, !compactHeight, abs(insets.leading - insets.trailing) >= 1 else { return [] }
        var edges: Edge.Set = []
        if insets.leading >= 1, insets.leading <= maxColumnWidth, insets.leading < insets.trailing || insets.trailing < 1 {
            edges.insert(.leading)
        }
        if insets.trailing >= 1, insets.trailing <= maxColumnWidth, insets.trailing < insets.leading || insets.leading < 1 {
            edges.insert(.trailing)
        }
        return edges
    }
}

/// The sides the reader runs under iPhone Duo's side column on, and the
/// column's width on each (0 on a side it doesn't run under).
struct SideColumn: Equatable {
    var edges: Edge.Set = []
    var leading: CGFloat = 0
    var trailing: CGFloat = 0

    static let empty = SideColumn()
}

/// Turns off the safe-area content inset of the paging scroll view a page
/// sits in, while the reader runs under the Duo's column. The page TabView is
/// UIKit underneath and takes its insets from where it is on screen, not from
/// SwiftUI: under the column it scrolled each page to end at the column's
/// edge, leaving the page a column's width to the left (text from -42 pt).
/// Placed in a page's background, it finds that scroll view among the page's
/// superviews and snaps the scroll back to the page on screen: the selected
/// page's cell, wherever the paging view put it. Its cells needn't sit a
/// whole scroll-view width apart (on the unfolded Duo's open book the second
/// spread's cell started 41.67 pt, the column's width, short of one width),
/// so a snap to a multiple of the width left that spread a column's width to
/// the left, its left page cut off (#360).
struct PagingInsetsOff: UIViewRepresentable {
    let active: Bool
    /// This page (or spread) is the one on screen: only its cell snaps.
    var selected = false

    func makeUIView(context: Context) -> FinderView {
        let view = FinderView()
        view.isUserInteractionEnabled = false
        view.active = active
        view.selected = selected
        return view
    }

    func updateUIView(_ uiView: FinderView, context: Context) {
        uiView.active = active
        uiView.selected = selected
        uiView.apply()
    }

    final class FinderView: UIView {
        var active = false
        var selected = false
        /// The paging view's subview this page sits in (its cell).
        private weak var cell: UIView?
        /// The scroll view's width at the last snap: a new one (a fold or
        /// unfold resizing the pages) is snapped again.
        private var snappedWidth: CGFloat = 0
        /// Watches the paging view's offset: a page turn the TabView animates
        /// itself (a tap) ends where it computed the page with the inset it
        /// had, so once the offset has rested the page is snapped back. Seen
        /// on the unfolded Duo's open book, which ended a column's width to
        /// the left after a turn.
        private var offsetObservation: NSKeyValueObservation?
        private weak var observed: UIScrollView?
        /// Counts offset changes, so only the last one's delayed snap runs.
        private var moves = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { stopObserving() }
            apply()
        }

        private func stopObserving() {
            offsetObservation?.invalidate()
            offsetObservation = nil
            observed = nil
        }

        private func observe(_ scroll: UIScrollView) {
            guard observed !== scroll else { return }
            stopObserving()
            observed = scroll
            offsetObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                MainActor.assumeIsolated { self?.offsetMoved(scroll) }
            }
        }

        private func offsetMoved(_ scroll: UIScrollView) {
            guard active else { return }
            moves += 1
            let move = moves
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak scroll] in
                MainActor.assumeIsolated {
                    guard let self, let scroll, self.moves == move, self.active else { return }
                    self.snap(scroll)
                }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            apply()
        }

        func apply() {
            guard active, window != nil else { return }
            var view = superview
            var below: UIView = self
            while let current = view {
                if let scroll = current as? UIScrollView, scroll.isPagingEnabled { break }
                below = current
                view = current.superview
            }
            guard let scroll = view as? UIScrollView else { return }
            cell = below
            observe(scroll)
            let width = scroll.bounds.width
            guard scroll.contentInsetAdjustmentBehavior != .never || abs(width - snappedWidth) >= 1 else { return }
            scroll.contentInsetAdjustmentBehavior = .never
            snappedWidth = width
            snap(scroll)
            // Again once the TabView has placed its page for this size.
            DispatchQueue.main.async { [weak self, weak scroll] in
                MainActor.assumeIsolated {
                    if let self, let scroll { self.snap(scroll) }
                }
            }
        }

        /// Scrolls the selected page's cell to the paging view's edge. Only
        /// that page's view moves the scroll, so the pages beside it, laid out
        /// too, don't fight over it.
        private func snap(_ scroll: UIScrollView) {
            guard selected, let cell, cell.superview === scroll, scroll.bounds.width > 0,
                  !scroll.isTracking, !scroll.isDecelerating else { return }
            let target = cell.frame.minX
            if abs(target - scroll.contentOffset.x) >= 0.5 { scroll.contentOffset.x = target }
        }
    }
}

extension View {
    /// Sets the reader's text at `placement` (ReaderMetrics.textColumnPlacement)
    /// in a page `containerWidth` wide.
    func textColumn(_ placement: (leading: CGFloat, width: CGFloat), in containerWidth: CGFloat) -> some View {
        frame(maxWidth: placement.width, alignment: .leading)
            .padding(.leading, placement.leading)
            .padding(.trailing, max(0, containerWidth - placement.leading - placement.width))
    }
}
