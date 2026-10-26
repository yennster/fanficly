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

    /// Which way a volume change turns: forward when it went up, back when it
    /// went down, nil when it's (within rounding) the volume being held, as
    /// when the reset itself is reported.
    static func direction(from baseline: Float, to volume: Float) -> Bool? {
        let delta = volume - baseline
        guard abs(delta) > step / 4 else { return nil }
        return delta > 0
    }
}

#if !targetEnvironment(macCatalyst)
/// Watches the output volume while the reader is open and the setting is on.
/// The hidden MPVolumeView keeps the system volume HUD away and is the only
/// public way to set the volume back.
@MainActor final class VolumeButtonPageTurner {
    private var observation: NSKeyValueObservation?
    private var baseline: Float = 0.5
    private weak var slider: UISlider?
    var onTurn: ((Bool) -> Void)?

    func attach(_ slider: UISlider?) {
        self.slider = slider
    }

    func start() {
        guard observation == nil else { return }
        let session = AVAudioSession.sharedInstance()
        // Mix with whatever's playing (music keeps going) instead of the
        // default category, which would stop it. Narration, which sets its own
        // .playback, never runs at the same time (see the modifier below).
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)
        baseline = VolumeButtonTurn.baseline(for: session.outputVolume)
        if baseline != session.outputVolume { setVolume(baseline) }
        // KVO reports on whatever queue the change came from.
        observation = session.observe(\.outputVolume, options: [.new]) { @Sendable [weak self] _, change in
            guard let self, let volume = change.newValue else { return }
            Task { @MainActor in self.volumeChanged(to: volume) }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
    }

    private func volumeChanged(to volume: Float) {
        guard observation != nil,
              let forward = VolumeButtonTurn.direction(from: baseline, to: volume) else { return }
        setVolume(baseline)
        onTurn?(forward)
    }

    private func setVolume(_ volume: Float) {
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
        turner.attach(view.subviews.compactMap { $0 as? UISlider }.first)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        turner.attach(uiView.subviews.compactMap { $0 as? UISlider }.first)
    }
}

/// Runs the turner while the reader is on screen, the app is active, the
/// setting is on and narration isn't playing (its volume buttons are for
/// volume).
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
                if enabled {
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
