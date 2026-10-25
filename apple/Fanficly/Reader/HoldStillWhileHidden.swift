import SwiftUI
import UIKit

/// Keeps the reader's page exactly where it was while its controls are
/// hidden, as Apple Books does: a tap shows or hides the controls over a page
/// that never moves or re-flows.
///
/// Hiding the controls also hides the status bar, and on iPhone Duo empties
/// the toolbar strip on the side. Either can hand the reader a slightly
/// different area (the bar moving up on an iPad, the strip's width coming
/// back), which would shift the text and re-paginate it. So while `hidden`,
/// the content is laid out in the frame it had with the controls up, at the
/// same place on screen. A real change of the window (rotation, a split-view
/// or Mac window resize) lets go, and the content lays out for the new size.
struct HoldStillWhileHidden: ViewModifier {
    let hidden: Bool
    /// The content's frame (global) with the controls up, and the window's
    /// size then.
    @State private var shownFrame: CGRect = .zero
    @State private var shownWindow: CGSize = .zero

    func body(content: Content) -> some View {
        GeometryReader { geo in
            let live = geo.frame(in: .global)
            let window = Self.windowSize
            let hold = hidden && shownFrame.width > 0 && shownFrame.height > 0
                && abs(window.width - shownWindow.width) < 1
                && abs(window.height - shownWindow.height) < 1
            content
                .frame(width: hold ? shownFrame.width : geo.size.width,
                       height: hold ? shownFrame.height : geo.size.height)
                .offset(x: hold ? shownFrame.minX - live.minX : 0,
                        y: hold ? shownFrame.minY - live.minY : 0)
                .onChange(of: live, initial: true) { _, frame in
                    if !hidden { record(frame) }
                }
                .onChange(of: hidden) { _, isHidden in
                    // Back up: whatever the frame is now is the controls-up one.
                    if !isHidden { record(live) }
                }
        }
    }

    private func record(_ frame: CGRect) {
        shownFrame = frame
        shownWindow = Self.windowSize
    }

    /// The key window's size (zero where there's none, e.g. previews).
    @MainActor private static var windowSize: CGSize {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .bounds.size ?? .zero
    }
}
