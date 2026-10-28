import AVFoundation
import MediaPlayer
import SwiftUI

/// "Volume buttons turn pages" (Settings → Reader, off by default): volume up
/// turns forward, volume down back, and the volume is put back after each
/// press. It's for page turners and rings that only send volume presses (a
/// remote's camera/volume mode), which work on every screen of an iPhone Duo,
/// folded or not, unlike a remote's fake taps. iOS doesn't hand apps the
/// buttons themselves, so this watches the output volume move.
///
/// Not on the Mac: Catalyst has no volume buttons for a remote to press.
enum VolumeButtonTurn {
    static let settingKey = "reader.volumeButtonsTurnPages"

    /// One press of the volume buttons moves the volume by 1/16.
    static let step: Float = 1.0 / 16.0

    /// The volume to hold while watching. A press past either end changes
    /// nothing iOS can report, so a volume at an end is moved one step in.
    static func baseline(for volume: Float) -> Float {
        min(max(volume, step), 1 - step)
    }

    /// Whether two volumes are the same, give or take rounding.
    static func same(_ a: Float, _ b: Float) -> Bool {
        abs(a - b) <= step / 4
    }

    /// Which way a reported volume change turns: forward when it went up,
    /// back when it went down. Nil when it didn't move, or when it's the
    /// turner's own reset arriving (`pendingReset`, the volume it just set).
    static func direction(from old: Float, to new: Float, pendingReset: Float?) -> Bool? {
        if let pendingReset, same(new, pendingReset) { return nil }
        guard !same(old, new) else { return nil }
        return new > old
    }
}

#if !targetEnvironment(macCatalyst)
/// Watches the output volume while the reader is open and the setting is on.
/// The hidden MPVolumeView keeps the system volume HUD away and is the only
/// public way to set the volume back.
@MainActor final class VolumeButtonPageTurner {
    private var observation: NSKeyValueObservation?
    private var routeObserver: NSObjectProtocol?
    private var baseline: Float = 0.5
    /// The volume before start() moved it off an end, put back by stop().
    private var original: Float?
    /// The value setVolume asked for, until its report comes back.
    private var pendingReset: Float?
    private weak var catcher: MPVolumeView?
    var onTurn: ((Bool) -> Void)?

    private var slider: UISlider? {
        catcher?.subviews.compactMap { $0 as? UISlider }.first
    }

    func attach(_ catcher: MPVolumeView) {
        self.catcher = catcher
    }

    func start() {
        guard observation == nil else { return }
        let session = AVAudioSession.sharedInstance()
        // Ambient mixes with whatever's playing, so music keeps going (the
        // default category would stop it). Narration, which sets its own
        // .playback, never runs at the same time (see the modifier below).
        try? session.setCategory(.ambient)
        try? session.setActive(true)
        holdCurrentVolume()
        // KVO reports on whatever queue the change came from.
        observation = session.observe(\.outputVolume, options: [.old, .new]) { @Sendable [weak self] _, change in
            guard let self, let old = change.oldValue, let new = change.newValue else { return }
            Task { @MainActor in self.volumeChanged(from: old, to: new) }
        }
        // Headphones or a speaker coming or going swaps in that device's own
        // volume: hold the new one rather than read it as a press.
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdCurrentVolume() }
        }
    }

    func stop() {
        guard observation != nil else { return }
        observation?.invalidate()
        observation = nil
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        // Leave the volume where the reader found it, unless it's been
        // changed some other way since (Control Center, another app).
        if let original, VolumeButtonTurn.same(AVAudioSession.sharedInstance().outputVolume, baseline) {
            // Now, not deferred: the catcher leaves the window with this update.
            slider?.setValue(original, animated: false)
            slider?.sendActions(for: .valueChanged)
        }
        original = nil
        pendingReset = nil
    }

    private func holdCurrentVolume() {
        let volume = AVAudioSession.sharedInstance().outputVolume
        baseline = VolumeButtonTurn.baseline(for: volume)
        pendingReset = nil
        if !VolumeButtonTurn.same(baseline, volume) {
            original = original ?? volume
            setVolume(baseline)
        }
    }

    private func volumeChanged(from old: Float, to new: Float) {
        guard observation != nil else { return }
        let forward = VolumeButtonTurn.direction(from: old, to: new, pendingReset: pendingReset)
        if let pendingReset, VolumeButtonTurn.same(new, pendingReset) { self.pendingReset = nil }
        guard let forward else { return }
        setVolume(baseline)
        // A sheet or alert over the reader (Comments, Bookmark, Report) hides
        // the page: hold the volume, but don't turn pages nobody can see.
        if isCovered { return }
        onTurn?(forward)
    }

    /// Whether something is presented over the reader.
    private var isCovered: Bool {
        guard let catcher, var top = catcher.window?.rootViewController else { return false }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        return !catcher.isDescendant(of: top.view)
    }

    private func setVolume(_ volume: Float) {
        pendingReset = volume
        // The slider ignores a value set in the same run loop turn as the press.
        Task { @MainActor [weak self] in
            guard let slider = self?.slider else { return }
            slider.setValue(volume, animated: false)
            slider.sendActions(for: .valueChanged)
        }
    }
}

/// The hidden MPVolumeView. It has to be in the window (not hidden, not zero
/// alpha) for iOS to drop its volume HUD and accept the slider's value.
struct VolumeButtonCatcher: UIViewRepresentable {
    let turner: VolumeButtonPageTurner

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))
        view.alpha = 0.01
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        turner.attach(view)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        turner.attach(uiView)
    }
}

/// Runs the turner while the reader is on screen, the app is active, the
/// setting is on and narration isn't playing. Narration's volume buttons are
/// for volume, with the system HUD, so the catcher is only in the window
/// while the turner runs.
struct VolumeButtonPageTurnModifier: ViewModifier {
    let enabled: Bool
    let speaking: Bool
    let scenePhase: ScenePhase
    let turn: (Bool) -> Void
    @State private var turner = VolumeButtonPageTurner()
    @State private var isVisible = false

    private var shouldRun: Bool { enabled && !speaking && isVisible && scenePhase == .active }

    func body(content: Content) -> some View {
        content
            .background {
                if shouldRun {
                    VolumeButtonCatcher(turner: turner)
                        .frame(width: 1, height: 1)
                        .accessibilityHidden(true)
                }
            }
            .onAppear {
                isVisible = true
                update()
            }
            .onDisappear {
                isVisible = false
                update()
            }
            .onChange(of: shouldRun) { _, _ in update() }
    }

    private func update() {
        turner.onTurn = turn
        if shouldRun { turner.start() } else { turner.stop() }
    }
}
#endif
