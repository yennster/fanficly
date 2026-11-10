import AVFoundation
import Foundation
import MediaPlayer
import Observation

/// The Listen sleep timer (#182): bedtime listening pauses once a span runs
/// out, after the paragraph being spoken, or at the end of the chapter.
enum SleepTimer: Hashable, Sendable {
    case minutes(Int)
    case endOfChapter

    /// What the narration bar offers, in order.
    static let choices: [SleepTimer] = [.minutes(15), .minutes(30), .minutes(60), .endOfChapter]

    var title: String {
        switch self {
        case .minutes(60): "1 hour"
        case .minutes(let m): "\(m) minutes"
        case .endOfChapter: "End of chapter"
        }
    }

    /// How long a timed choice runs; nil for "End of chapter".
    var duration: TimeInterval? {
        if case .minutes(let m) = self { return TimeInterval(m * 60) }
        return nil
    }
}

/// On-device text-to-speech for the reader — turns a chapter into spoken
/// audio with Apple's built-in `AVSpeechSynthesizer`.
///
/// Deliberately no third-party model and no network: the system voices run
/// entirely on-device, which keeps the app's privacy posture intact (nothing
/// leaves the device). Users can download higher-quality/natural voices in
/// iOS Settings → Accessibility → Spoken Content → Voices (or set up Personal Voice
/// under Settings → Accessibility → Personal Voice) and pick one in
/// Reader settings; otherwise the platform default voice is used.
///
/// Paragraphs are enqueued up-front so playback is gapless. We map each
/// utterance back to its paragraph index (via `ObjectIdentifier`) to drive
/// the mini-player's progress and detect the end of a chapter.
@MainActor
@Observable
final class SpeechController: NSObject {
    /// A chapter is loaded — the reader should show the mini-player.
    private(set) var isActive = false
    /// Audio is currently being produced (vs. paused).
    private(set) var isPlaying = false {
        didSet { if isPlaying != oldValue { onPlayingChanged?(isPlaying) } }
    }
    /// Index of the *rendered* paragraph currently being spoken — aligned with
    /// `ChapterContentView`'s paragraphs so the reader can highlight it.
    private(set) var currentParagraph = 0
    /// Number of spoken (non-empty) paragraphs in the loaded chapter.
    private(set) var spokenCount = 0
    /// 1-based position of the current paragraph among the spoken ones (for the
    /// "¶ x / y" mini-player readout).
    private(set) var spokenPosition = 0
    /// Label for the loaded chapter (shown in the mini-player / lock screen).
    private(set) var chapterLabel = ""
    /// The sleep timer that's set, if any (#182). Cleared once it pauses
    /// narration, and by `stop()`.
    private(set) var sleepTimer: SleepTimer?
    /// When a timed sleep timer runs out; nil for "End of chapter", and once
    /// it has run out.
    private(set) var sleepDeadline: Date?
    /// The sleep timer ran out (or the chapter ended under "End of
    /// chapter"): narration pauses at the end of the paragraph being spoken.
    private(set) var sleepPausePending = false
    /// The sleep timer paused narration and nothing has played since. The
    /// reader keeps the screen's idle timer running then too, so a paused
    /// bedtime chapter doesn't hold the screen on all night (#182).
    private(set) var pausedBySleepTimer = false
    /// Called when a chapter finishes so the reader can advance to the next
    /// one (or `stop()`). A direct call rather than an observed signal: SwiftUI
    /// doesn't run a backgrounded view's `onChange`, so with the app minimized
    /// or the phone locked an observed tick left narration stuck at the end of
    /// the chapter. The closure captures the reading view, so `stop()` (which
    /// the reader calls whenever it closes) drops it to break that cycle.
    @ObservationIgnored var onChapterFinished: (@MainActor () -> Void)?
    /// Called with the rendered index of each paragraph as it starts, so the
    /// reader saves the place even in the background, where its
    /// `onChange(of: currentParagraph)` doesn't run (#161). Direct for the
    /// same reason as `onChapterFinished`, and dropped by `stop()` with it.
    @ObservationIgnored var onParagraphStarted: (@MainActor (Int) -> Void)?
    /// Called when narration starts or stops producing audio (play, pause, an
    /// interruption, a chapter's end), so the reader can time listening in
    /// the background as reading (#161). Dropped by `stop()`, after it reports
    /// the stop.
    @ObservationIgnored var onPlayingChanged: (@MainActor (Bool) -> Void)?

    static let rateKey = "reader.ttsRate"
    static let voiceKey = "reader.ttsVoiceId"
    static var defaultRate: Float { AVSpeechUtteranceDefaultSpeechRate }

    /// Current speaking rate multiplier (e.g. 1.0, 1.25, 1.5).
    var rateMultiplier: Double = 1.0 {
        didSet {
            let minMult = Double(AVSpeechUtteranceMinimumSpeechRate / Self.defaultRate)
            let maxMult = Double(AVSpeechUtteranceMaximumSpeechRate / Self.defaultRate)
            let clamped = max(minMult, min(maxMult, rateMultiplier))
            if clamped != rateMultiplier {
                rateMultiplier = clamped
                return
            }
            let newRaw = rateMultiplier * Double(Self.defaultRate)
            let oldRaw = UserDefaults.standard.double(forKey: Self.rateKey)
            if abs(newRaw - oldRaw) > 0.001 {
                UserDefaults.standard.set(newRaw, forKey: Self.rateKey)
                applyRateChange()
            }
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    /// Index-aligned with the reader's rendered paragraphs; empty entries
    /// (scene breaks) are skipped when speaking but keep their slot.
    private var paragraphs: [String] = []
    /// The rendered indices that actually get spoken (non-empty), in order.
    private var spokenIndices: [Int] = []
    private var indexOf: [ObjectIdentifier: Int] = [:]
    private var workTitle = ""
    private var author = ""
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    /// Held while a chapter is loaded so macOS's App Nap doesn't throttle the
    /// app once its window is minimized or hidden: the synthesizer's callbacks
    /// (paragraph tracking, the next chapter) would otherwise stall.
    private var narrationActivity: NSObjectProtocol?
    /// An interruption paused narration that was playing; only then does its
    /// end resume it (narration you paused yourself stays paused).
    private var pausedByInterruption = false
    /// Counts down a timed sleep timer.
    private var sleepTask: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
        
        // Load stored rate multiplier from UserDefaults
        if let stored = UserDefaults.standard.object(forKey: Self.rateKey) as? Double {
            self.rateMultiplier = stored / Double(Self.defaultRate)
        } else {
            self.rateMultiplier = 1.0
        }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleUserDefaultsChange),
            name: UserDefaults.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleUserDefaultsChange() {
        if let stored = UserDefaults.standard.object(forKey: Self.rateKey) as? Double {
            let newMultiplier = stored / Double(Self.defaultRate)
            if abs(self.rateMultiplier - newMultiplier) > 0.001 {
                self.rateMultiplier = newMultiplier
            }
        }
    }

    // MARK: - Live settings (read from @AppStorage's backing store)

    private var rate: Float {
        Float(rateMultiplier * Double(Self.defaultRate))
    }

    private var voice: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: Self.voiceKey), !id.isEmpty {
            return AVSpeechSynthesisVoice(identifier: id)
        }
        return nil  // nil → platform default voice for the current language
    }

    // MARK: - Control

    /// Loads a chapter's paragraphs and starts speaking from `paragraph`.
    /// False when the chapter has nothing to speak (nothing is loaded then).
    @discardableResult
    func play(paragraphs: [String], workTitle: String, author: String,
              chapterLabel: String, from paragraph: Int = 0) -> Bool {
        let spoken = paragraphs.indices.filter {
            !paragraphs[$0].trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !spoken.isEmpty else { return false }
        self.paragraphs = paragraphs
        self.spokenIndices = spoken
        self.spokenCount = spoken.count
        self.workTitle = workTitle
        self.author = author
        self.chapterLabel = chapterLabel
        isActive = true
        activateSession()
        if narrationActivity == nil {
            narrationActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Reading a chapter aloud")
        }
        wireRemoteCommands()
        if sleepPausePending {
            // The sleep timer ran out at the end of the last chapter (or it
            // was "End of chapter"): the next chapter loads paused at its start.
            synthesizer.stopSpeaking(at: .immediate)
            indexOf.removeAll()
            let first = spoken.first(where: { $0 >= max(0, paragraph) }) ?? spoken[0]
            currentParagraph = first
            spokenPosition = (spoken.firstIndex(of: first) ?? 0) + 1
            pauseForSleepTimer()
            return true
        }
        enqueue(from: max(0, paragraph))
        return true
    }

    func togglePlayPause() {
        guard isActive else { return }
        if isPlaying { pause() } else { resume() }
    }

    func pause() {
        guard synthesizer.isSpeaking, !synthesizer.isPaused else { return }
        // Pausing yourself takes over from a sleep timer that already ran out.
        if sleepPausePending { clearSleepTimer() }
        synthesizer.pauseSpeaking(at: .word)
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        guard isActive else { return }
        // An interruption (a call, Siri, an alarm) deactivates the session;
        // speaking from the background needs it active again.
        activateSession()
        pausedBySleepTimer = false
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
        } else if !synthesizer.isSpeaking {
            enqueue(from: currentParagraph)  // restart from where we stopped
        }
        isPlaying = true
        updateNowPlaying()
    }

    /// Jump to the next spoken paragraph, or end the chapter if at the last.
    func skipForward() {
        if let next = spokenIndices.first(where: { $0 > currentParagraph }) {
            enqueue(from: next)
        } else {
            finishChapter()
        }
    }

    func skipBackward() {
        let prev = spokenIndices.last(where: { $0 < currentParagraph })
            ?? spokenIndices.first ?? 0
        enqueue(from: prev)
    }

    /// Tears everything down — used when the reader closes, or when playback
    /// ends with no further chapter.
    func stop() {
        // Only hand the audio session back if narration took it: the reader
        // calls stop() on every close, and another reader's volume page
        // turning (VolumeButtonPageTurner) may be holding it.
        let hadSession = isActive
        synthesizer.stopSpeaking(at: .immediate)
        indexOf.removeAll()
        paragraphs = []
        spokenIndices = []
        isPlaying = false
        isActive = false
        currentParagraph = 0
        spokenCount = 0
        spokenPosition = 0
        chapterLabel = ""
        onChapterFinished = nil
        onParagraphStarted = nil
        onPlayingChanged = nil
        pausedByInterruption = false
        clearSleepTimer()
        pausedBySleepTimer = false
        if let narrationActivity {
            ProcessInfo.processInfo.endActivity(narrationActivity)
            self.narrationActivity = nil
        }
        unwireRemoteCommands()
        clearNowPlaying()
        if hadSession { deactivateSession() }
    }

    // MARK: - Internals

    /// `renderedIndex` is a paragraph index in the reader's coordinate space;
    /// we enqueue every spoken paragraph at or after it.
    private func enqueue(from renderedIndex: Int) {
        synthesizer.stopSpeaking(at: .immediate)
        indexOf.removeAll()
        let toSpeak = spokenIndices.filter { $0 >= renderedIndex }
        guard let first = toSpeak.first else { finishChapter(); return }
        currentParagraph = first
        spokenPosition = (spokenIndices.firstIndex(of: first) ?? 0) + 1
        let v = voice
        let r = rate
        for i in toSpeak {
            let utterance = AVSpeechUtterance(string: paragraphs[i])
            utterance.rate = r
            utterance.voice = v
            utterance.postUtteranceDelay = 0.15  // a small breath between paragraphs
            indexOf[ObjectIdentifier(utterance)] = i
            synthesizer.speak(utterance)
        }
        pausedBySleepTimer = false
        isPlaying = true
        updateNowPlaying()
    }

    /// A new speed reaches utterances only when they're built, so playing
    /// narration re-queues from the current paragraph. Paused narration drops
    /// its queue instead of speaking again; `resume()` rebuilds it from the
    /// current paragraph at the new speed.
    private func applyRateChange() {
        switch Self.rateChange(isActive: isActive, isPlaying: isPlaying) {
        case .requeue:
            enqueue(from: currentParagraph)
        case .dropQueue:
            synthesizer.stopSpeaking(at: .immediate)
            indexOf.removeAll()
        case .ignore:
            break
        }
    }

    enum RateChange: Equatable { case requeue, dropQueue, ignore }

    /// What a speed change does: re-queue playing narration, drop a paused
    /// one's queue (never speak), nothing with no chapter loaded.
    nonisolated static func rateChange(isActive: Bool, isPlaying: Bool) -> RateChange {
        guard isActive else { return .ignore }
        return isPlaying ? .requeue : .dropQueue
    }

    private func finishChapter() {
        synthesizer.stopSpeaking(at: .immediate)
        // "End of chapter": the next chapter the reader loads stays paused.
        if Self.pausesAtChapterEnd(sleepTimer) { sleepPausePending = true }
        isPlaying = false
        onChapterFinished?()  // reader decides whether to advance or stop()
    }

    // MARK: - Sleep timer (#182)

    /// Sets the sleep timer, or turns it off with nil. A timed one counts
    /// down from now, playing or paused; when it runs out, narration that's
    /// playing pauses at the end of the paragraph being spoken.
    func setSleepTimer(_ timer: SleepTimer?) {
        clearSleepTimer()
        sleepTimer = timer
        guard let duration = timer?.duration else { return }
        let deadline = Date().addingTimeInterval(duration)
        sleepDeadline = deadline
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.sleepTimerRanOut()
        }
    }

    private func sleepTimerRanOut() {
        let overdue = sleepDeadline.map { Date().timeIntervalSince($0) > 30 } ?? false
        sleepTask = nil
        sleepDeadline = nil
        // An interruption (a call, an alarm) that resumes on its own counts as
        // playing, so the timer isn't lost under it. A timer that fires long
        // overdue ran out while the app was suspended, i.e. paused: it must
        // not pause the next play.
        let playing = (isPlaying || pausedByInterruption) && !overdue
        if Self.sleepTimerRanOut(isPlaying: playing) == .pauseAfterParagraph {
            sleepPausePending = true
        } else {
            sleepTimer = nil
        }
    }

    private func clearSleepTimer() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimer = nil
        sleepDeadline = nil
        sleepPausePending = false
    }

    /// The pending sleep pause lands: narration is paused with nothing
    /// queued, so `resume()` speaks again from `currentParagraph`.
    private func pauseForSleepTimer() {
        clearSleepTimer()
        pausedBySleepTimer = true
        isPlaying = false
        updateNowPlaying()
    }

    enum SleepTimerEnd: Equatable { case pauseAfterParagraph, nothingToPause }

    /// A timed sleep timer running out pauses only narration that's playing;
    /// with narration already paused it just turns itself off.
    nonisolated static func sleepTimerRanOut(isPlaying: Bool) -> SleepTimerEnd {
        isPlaying ? .pauseAfterParagraph : .nothingToPause
    }

    /// Whether a chapter's end pauses narration (rather than rolling on).
    nonisolated static func pausesAtChapterEnd(_ timer: SleepTimer?) -> Bool {
        timer == .endOfChapter
    }

    enum ParagraphEnd: Equatable { case finishChapter, pause, carryOn }

    /// What a paragraph finishing does: the chapter's last one ends the
    /// chapter (a pending sleep pause then holds the next chapter at its
    /// start); any other pauses before the next when a sleep pause is
    /// pending, else narration carries on.
    nonisolated static func paragraphEnd(isLast: Bool, sleepPausePending: Bool) -> ParagraphEnd {
        if isLast { return .finishChapter }
        return sleepPausePending ? .pause : .carryOn
    }

    // MARK: - Audio session

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// A phone call, Siri or another app's audio took over: the system pauses
    /// the synthesizer, so show it paused, and pick up again afterwards when
    /// the system says to (it does after a call, even with the app in the
    /// background or the screen locked). Posted off the main thread, so only
    /// the raw values cross to the main actor.
    @objc nonisolated private func handleAudioInterruption(_ note: Notification) {
        guard let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
        Task { @MainActor in
            guard isActive else { return }
            switch type {
            case .began:
                if isPlaying {
                    synthesizer.pauseSpeaking(at: .word)
                    isPlaying = false
                    pausedByInterruption = true
                    updateNowPlaying()
                }
            case .ended:
                if pausedByInterruption && shouldResume { resume() }
                pausedByInterruption = false
            @unknown default:
                break
            }
        }
    }

    /// Headphones were unplugged or AirPods disconnected or ran flat. The
    /// synthesizer doesn't pause on its own (`AVPlayer` does), so without this
    /// a chapter would carry on through the speaker. Pause as you would by
    /// hand: reconnecting doesn't resume, and neither does the end of an
    /// interruption that was already pausing it.
    @objc nonisolated private func handleAudioRouteChange(_ note: Notification) {
        guard let rawReason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
              Self.pausesNarration(for: reason) else { return }
        Task { @MainActor in
            guard isActive else { return }
            pausedByInterruption = false
            // As a pause by hand: it takes over from a sleep pause pending.
            if sleepPausePending { clearSleepTimer() }
            // Not `pause()`, which finishes the word: not one more through the speaker.
            guard synthesizer.isSpeaking, !synthesizer.isPaused else { return }
            synthesizer.pauseSpeaking(at: .immediate)
            isPlaying = false
            updateNowPlaying()
        }
    }

    /// Only losing the device narration was playing on pauses it; a new
    /// device (plugging headphones in) or a category change doesn't.
    nonisolated static func pausesNarration(for reason: AVAudioSession.RouteChangeReason) -> Bool {
        reason == .oldDeviceUnavailable
    }

    // MARK: - Lock-screen / Control Center

    private func wireRemoteCommands() {
        guard commandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor @Sendable () -> Void) {
            let token = command.addTarget { _ in
                Task { @MainActor in action() }
                return .success
            }
            commandTargets.append((command, token))
        }
        add(center.playCommand) { [weak self] in self?.resume() }
        add(center.pauseCommand) { [weak self] in self?.pause() }
        add(center.togglePlayPauseCommand) { [weak self] in self?.togglePlayPause() }
        add(center.nextTrackCommand) { [weak self] in self?.skipForward() }
        add(center.previousTrackCommand) { [weak self] in self?.skipBackward() }
    }

    private func unwireRemoteCommands() {
        for (command, token) in commandTargets { command.removeTarget(token) }
        commandTargets.removeAll()
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapterLabel.isEmpty ? workTitle : chapterLabel,
            MPMediaItemPropertyArtist: author,
            MPMediaItemPropertyAlbumTitle: workTitle,
            MPNowPlayingInfoPropertyPlaybackQueueCount: spokenCount,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: max(0, spokenPosition - 1),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechController: AVSpeechSynthesizerDelegate {
    // Callbacks may arrive off the main actor. We capture only the Sendable
    // `ObjectIdentifier` (never the non-Sendable utterance) and hop to the
    // main actor to touch state.
    @objc nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                             didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            if let i = indexOf[id] {
                currentParagraph = i
                spokenPosition = (spokenIndices.firstIndex(of: i) ?? 0) + 1
                updateNowPlaying()
                onParagraphStarted?(i)
            }
        }
    }

    @objc nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                             didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            // Only the last spoken paragraph's natural finish ends the chapter;
            // stopSpeaking(.immediate) fires didCancel instead, not didFinish.
            guard let i = indexOf[id] else { return }
            switch Self.paragraphEnd(isLast: i == spokenIndices.last,
                                     sleepPausePending: sleepPausePending) {
            case .finishChapter:
                finishChapter()
            case .pause:
                // The sleep timer ran out: stop before the next paragraph
                // (the 0.15 s breath between them leaves time) and drop the
                // queue, so playing again starts that paragraph afresh.
                self.synthesizer.stopSpeaking(at: .immediate)
                indexOf.removeAll()
                if let next = spokenIndices.first(where: { $0 > i }) {
                    currentParagraph = next
                    spokenPosition = (spokenIndices.firstIndex(of: next) ?? 0) + 1
                }
                pauseForSleepTimer()
            case .carryOn:
                break
            }
        }
    }
}

// MARK: - Play Sample

/// Settings → Reader's Play Sample (#193): one short passage at the chosen
/// voice and speaking rate, so picking among many voices doesn't mean opening
/// a story each time. On-device like Listen. Its own synthesizer, so it never
/// touches a chapter's narration queue; the Windows app's `SpeechSample`
/// speaks the same passage.
@MainActor
@Observable
final class SpeechSample: NSObject {
    nonisolated static let text = "Bella poured the latte. It was hot. Edward looked up from the corner table and met her eyes."

    private(set) var isPlaying = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    /// The utterance playing, so a late callback from one already stopped
    /// can't end the next.
    @ObservationIgnored private var current: ObjectIdentifier?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// The utterance's rate for a stored `reader.ttsRate`, kept to the range
    /// AVSpeech takes.
    nonisolated static func utteranceRate(_ storedRate: Double) -> Float {
        min(max(Float(storedRate), AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    /// Speaks the sample; `voiceId` "" is the platform default voice, as for Listen.
    func play(voiceId: String, rate: Double) {
        stop()
        let utterance = AVSpeechUtterance(string: Self.text)
        utterance.rate = Self.utteranceRate(rate)
        if !voiceId.isEmpty { utterance.voice = AVSpeechSynthesisVoice(identifier: voiceId) }
        // The same session as Listen, so the sample is heard with the
        // ring/silent switch on silent, as narration is.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
        current = ObjectIdentifier(utterance)
        isPlaying = true
        synthesizer.speak(utterance)
    }

    func stop() {
        guard current != nil else { return }
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
        finish()
    }

    private func finished(_ id: ObjectIdentifier) {
        guard current == id else { return }
        current = nil
        finish()
    }

    private func finish() {
        isPlaying = false
        // Fails harmlessly (busy) while a reader in another window narrates.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension SpeechSample: AVSpeechSynthesizerDelegate {
    // Off the main actor: capture only the Sendable id, as SpeechController does.
    @objc nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                             didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in finished(id) }
    }

    @objc nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                             didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in finished(id) }
    }
}
