import SwiftUI
import UIKit

/// Lays the reader out under iPhone Duo's side column, as Apple Books does.
/// There the status bar and the toolbar strip sit in a column on one side of
/// the screen, which comes in as a safe-area inset on that side only. Kept
/// clear, it was blank beside the page (and stayed blank in full screen,
/// since the page holds still); Books runs its text under it and lets the
/// controls float over the page.
///
/// Only on the phone idiom (the Duo is one on both displays) at a regular
/// height, and only a side whose inset the other side doesn't match. An
/// iPhone in landscape (a compact height) keeps the insets around its sensor
/// housing, which needn't match on both sides. A sidebar's inset is wider
/// than any strip and is kept too.
struct RunUnderSideColumn: ViewModifier {
    /// The controls are hidden: hiding the status bar may take the column's
    /// inset away, so the page keeps running under it until they're back, or
    /// for one layout pass on showing them the page would narrow.
    let controlsHidden: Bool
    /// The sides run under. Views inside that lay out their own content by
    /// the safe area (the paging TabView's pages, the bottom bars) ignore
    /// them too, or they'd keep the column clear inside the wider frame.
    @Binding var edges: Edge.Set

    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Wider than this, a side inset isn't the Duo's column.
    nonisolated static let maxColumnWidth: CGFloat = 100

    func body(content: Content) -> some View {
        content
            .ignoresSafeArea(.container, edges: edges)
            // Measured around the content, which reports its insets the same
            // whether or not it runs into them.
            .background {
                GeometryReader { geo in
                    let column = Self.columnEdges(geo.safeAreaInsets, isPhone: Self.isPhone,
                                                  compactHeight: verticalSizeClass == .compact)
                    Color.clear
                        .onChange(of: column, initial: true) { _, value in
                            if !(controlsHidden && value.isEmpty) { edges = value }
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
