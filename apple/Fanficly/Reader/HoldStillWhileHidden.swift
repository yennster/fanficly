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
/// same place on screen. It lets go when the reader's own window changes size
/// (rotation, a fold or unfold, a split-view or Mac window resize) or `layout`
/// changes (the narration bar coming or going), and the content lays out for
/// the new area.
///
/// Showing the controls brings the status bar back a layout pass or two after
/// `hidden` turns false, so the hold lasts until the area is the controls-up
/// one again (or `releaseTimeout` passes), or the page would slide.
struct HoldStillWhileHidden: ViewModifier {
    let hidden: Bool
    /// What else shapes the area: the hold lets go when it changes.
    let layout: AnyHashable

    @State private var window = HostWindow()
    /// The content's frame (global) with the controls up, and what it was
    /// measured with.
    @State private var shown: Snapshot?
    /// True from showing the controls until the area is back to `shown`.
    @State private var releasing = false

    private struct Snapshot: Equatable {
        var frame: CGRect
        var window: CGSize
        var layout: AnyHashable
    }

    static let releaseTimeout: Duration = .milliseconds(500)

    func body(content: Content) -> some View {
        GeometryReader { geo in
            let live = geo.frame(in: .global)
            let held = heldFrame(window: window.size)
            let _ = (window.lastLive = live)
            content
                .frame(width: held?.width ?? geo.size.width, height: held?.height ?? geo.size.height)
                .offset(x: held.map { $0.minX - live.minX } ?? 0,
                        y: held.map { $0.minY - live.minY } ?? 0)
                .background(HostWindowFinder(window: window))
                .onChange(of: live, initial: true) { _, frame in
                    if releasing, let shown, !Self.same(frame, shown.frame) { return }
                    releasing = false
                    if !hidden { record(frame) }
                }
                .onChange(of: hidden) { _, isHidden in
                    guard !isHidden else {
                        releasing = false
                        // The window may not have been found yet when the
                        // controls-up frame was recorded.
                        shown?.window = window.size
                        return
                    }
                    releasing = true
                    Task { @MainActor in
                        try? await Task.sleep(for: Self.releaseTimeout)
                        guard releasing else { return }
                        releasing = false
                        record(window.lastLive)
                    }
                }
                .onChange(of: layout) { _, _ in
                    if !hidden { record(live) }
                }
        }
    }

    /// Where to lay the content out instead of where the area is now, if anywhere.
    private func heldFrame(window size: CGSize) -> CGRect? {
        guard hidden || releasing, let shown, shown.frame.width > 0, shown.frame.height > 0,
              shown.layout == layout,
              abs(size.width - shown.window.width) < 1, abs(size.height - shown.window.height) < 1
        else { return nil }
        return shown.frame
    }

    private func record(_ frame: CGRect) {
        shown = Snapshot(frame: frame, window: window.size, layout: layout)
    }

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1
            && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }
}

/// The window the reader is in: not the key window, which on an iPad in
/// Split View or with two Fanficly windows can be another one.
@MainActor final class HostWindow {
    weak var window: UIWindow?
    /// The area's frame at the last layout, for when the release times out.
    var lastLive: CGRect = .zero
    var size: CGSize { window?.bounds.size ?? .zero }
}

private struct HostWindowFinder: UIViewRepresentable {
    let window: HostWindow

    func makeUIView(context: Context) -> FinderView {
        let view = FinderView()
        view.host = window
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: FinderView, context: Context) {
        uiView.host = window
        window.window = uiView.window
    }

    final class FinderView: UIView {
        var host: HostWindow?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            host?.window = window
        }
    }
}
