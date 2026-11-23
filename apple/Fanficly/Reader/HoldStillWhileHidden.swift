import SwiftUI
import UIKit

/// Keeps the reader's page where it was while its controls are hidden: a tap
/// shows or hides the controls over a page that doesn't slide about.
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
/// With `fillsTop` (page-by-page), hidden controls give the page their room at
/// the top: the held frame reaches up to where the status bar ends with the
/// controls up (`minimumTop` at least), so the empty navigation bar's band
/// fills with text instead of staying a blank margin. It's worked out from the
/// controls-up frame and window, never from the live area, so the status bar
/// going doesn't move it. Page-by-page measures its pages for the taller area
/// and re-paginates keeping the page's first words (PageAreaTracker).
///
/// Showing the controls brings the status bar back a layout pass or two after
/// `hidden` turns false, so the hold lasts until the area is the controls-up
/// one again (or `releaseTimeout` passes), or the page would slide.
struct HoldStillWhileHidden: ViewModifier {
    let hidden: Bool
    /// What else shapes the area: the hold lets go when it changes.
    let layout: AnyHashable
    /// Whether the content takes the controls' room at the top while they're
    /// hidden (see above).
    var fillsTop: Bool = false

    @State private var window = HostWindow()
    /// The content's frame (global) with the controls up, and what it was
    /// measured with.
    @State private var shown: Snapshot?
    /// True from showing the controls until the area is back to `shown`.
    @State private var releasing = false
    /// The latest show's release, so an older timeout can't end it early.
    @State private var releaseID = UUID()

    private struct Snapshot: Equatable {
        var frame: CGRect
        var window: CGSize
        var layout: AnyHashable
        /// The window's top safe area with the controls up: where the status
        /// bar (or the sensor housing) ends.
        var windowTop: CGFloat
    }

    static let releaseTimeout: Duration = .milliseconds(500)

    /// The least room a filled top keeps above the page (the page adds its
    /// own margin) where the window reports no top safe area: an iPhone in
    /// landscape, a window with no status bar.
    static let minimumTop: CGFloat = 16

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
                    if !hidden {
                        record(frame)
                    } else if let shown, abs(shown.window.width - window.size.width) >= 1
                                || abs(shown.window.height - window.size.height) >= 1 {
                        // The window changed size with the controls hidden (a
                        // rotation, a fold): hold the new area, so the top
                        // still fills (fillsTop) rather than leaving the band.
                        record(frame)
                    }
                }
                .onChange(of: hidden) { _, isHidden in
                    guard !isHidden else {
                        if releasing {
                            // Hidden again before the area settled back (it
                            // may never have, after a rotation): what's on
                            // screen now is the controls-up frame.
                            releasing = false
                            record(live)
                        } else if shown?.window == .zero {
                            // The window wasn't found yet when the
                            // controls-up frame was recorded.
                            shown?.window = window.size
                            shown?.windowTop = window.safeTop
                        }
                        return
                    }
                    releasing = true
                    let release = UUID()
                    releaseID = release
                    Task { @MainActor in
                        try? await Task.sleep(for: Self.releaseTimeout)
                        guard releasing, releaseID == release else { return }
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
        guard hidden, fillsTop else { return shown.frame }
        return Self.filledTop(shown.frame, windowTop: shown.windowTop)
    }

    /// `frame` grown upward to `windowTop` (`minimumTop` at least) when it
    /// starts below that: the room the hidden controls leave at the top.
    static func filledTop(_ frame: CGRect, windowTop: CGFloat) -> CGRect {
        let top = min(frame.minY, max(windowTop, minimumTop))
        return CGRect(x: frame.minX, y: top, width: frame.width, height: frame.maxY - top)
    }

    private func record(_ frame: CGRect) {
        shown = Snapshot(frame: frame, window: window.size, layout: layout, windowTop: window.safeTop)
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
    /// The window's top safe area (the status bar's or sensor housing's).
    var safeTop: CGFloat { window?.safeAreaInsets.top ?? 0 }
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
