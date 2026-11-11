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
/// Books. Its cells, like one page's, need PagingInsetsOff and
/// fillingPagingCell, or the paging view's content inset and the page's own
/// safe area leave the page a column's width (or half of one) to the left.
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
/// superviews and snaps the scroll back to the page.
struct PagingInsetsOff: UIViewRepresentable {
    let active: Bool

    func makeUIView(context: Context) -> FinderView {
        let view = FinderView()
        view.isUserInteractionEnabled = false
        view.active = active
        return view
    }

    func updateUIView(_ uiView: FinderView, context: Context) {
        uiView.active = active
        uiView.apply()
    }

    final class FinderView: UIView {
        var active = false
        /// The scroll view's width at the last snap: a new one (a fold or
        /// unfold resizing the pages) is snapped again.
        private var snappedWidth: CGFloat = 0

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            apply()
        }

        func apply() {
            guard active, window != nil else { return }
            var view = superview
            while let current = view {
                if let scroll = current as? UIScrollView, scroll.isPagingEnabled { break }
                view = current.superview
            }
            guard let scroll = view as? UIScrollView else { return }
            let width = scroll.bounds.width
            guard scroll.contentInsetAdjustmentBehavior != .never || abs(width - snappedWidth) >= 1 else { return }
            scroll.contentInsetAdjustmentBehavior = .never
            snappedWidth = width
            Self.snap(scroll)
            // Again once the TabView has placed its page for this size.
            DispatchQueue.main.async { [weak scroll] in
                if let scroll { Self.snap(scroll) }
            }
        }

        private static func snap(_ scroll: UIScrollView) {
            let width = scroll.bounds.width
            guard width > 0, !scroll.isTracking, !scroll.isDecelerating else { return }
            let snapped = (scroll.contentOffset.x / width).rounded() * width
            if abs(snapped - scroll.contentOffset.x) >= 0.5 { scroll.contentOffset.x = snapped }
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

extension View {
    /// Fills the TabView page (paging cell) this page sits in, the area it was
    /// paginated for, safe area included. `.ignoresSafeArea` alone doesn't do
    /// it there on the unfolded iPhone Duo: the page's hosting view keeps its
    /// safe area (the side column's 84 pt, the bar's 50 pt), and an open book,
    /// wider than what's left, was centred in it, 41.67 pt left of the fold
    /// with its left page cut off (#360). So the page takes the insets back
    /// itself; where `.ignoresSafeArea` works they read 0 and this changes
    /// nothing.
    func fillingPagingCell() -> some View {
        GeometryReader { cell in
            let insets = cell.safeAreaInsets
            self
                .frame(width: cell.size.width + insets.leading + insets.trailing,
                       height: cell.size.height + insets.top + insets.bottom, alignment: .topLeading)
                .offset(x: -insets.leading, y: -insets.top)
        }
        .ignoresSafeArea(.container)
    }
}
