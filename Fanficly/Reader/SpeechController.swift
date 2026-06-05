import AVFoundation
import Foundation
import MediaPlayer
import Observation

/// On-device text-to-speech for the reader — turns a chapter into spoken
/// audio with Apple's built-in `AVSpeechSynthesizer`.
///
/// Deliberately no third-party model and no network: the system voices run
/// entirely on-device, which keeps the app's privacy posture intact (nothing
/// leaves the device). Users can download higher-quality/natural voices in
/// iOS Settings → Accessibility → Spoken Content → Voices and pick one in
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
    private(set) var isPlaying = false
    /// Index of the paragraph currently being spoken.
    private(set) var currentParagraph = 0
    /// Total paragraphs in the loaded chapter.
    private(set) var paragraphCount = 0
    /// Label for the loaded chapter (shown in the mini-player / lock screen).
    private(set) var chapterLabel = ""
    /// Bumped when a chapter finishes so the reader can advance to the next
    /// one. A published signal (rather than a stored completion closure) avoids
    /// the retain cycle a closure capturing the reading view would create.
    private(set) var finishedTick = 0

    static let rateKey = "reader.ttsRate"
    static let voiceKey = "reader.ttsVoiceId"
    static var defaultRate: Float { AVSpeechUtteranceDefaultSpeechRate }

    private let synthesizer = AVSpeechSynthesizer()
    private var paragraphs: [String] = []
    private var indexOf: [ObjectIdentifier: Int] = [:]
    private var workTitle = ""
    private var author = ""
    private var commandTargets: [(MPRemoteCommand, Any)] = []

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Live settings (read from @AppStorage's backing store)

    private var rate: Float {
        // @AppStorage("reader.ttsRate") stores a Double; nil until the user
        // first changes it, in which case fall back to the platform default.
        if let stored = UserDefaults.standard.object(forKey: Self.rateKey) as? Double {
            return Float(stored)
        }
        return Self.defaultRate
    }

    private var voice: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: Self.voiceKey), !id.isEmpty {
            return AVSpeechSynthesisVoice(identifier: id)
        }
        return nil  // nil → platform default voice for the current language
    }

    // MARK: - Control

    /// Loads a chapter's paragraphs and starts speaking from `paragraph`.
    func play(paragraphs: [String], workTitle: String, author: String,
              chapterLabel: String, from paragraph: Int = 0) {
        guard !paragraphs.isEmpty else { return }
        self.paragraphs = paragraphs
        self.paragraphCount = paragraphs.count
        self.workTitle = workTitle
        self.author = author
        self.chapterLabel = chapterLabel
        isActive = true
        activateSession()
        wireRemoteCommands()
        enqueue(from: max(0, min(paragraph, paragraphs.count - 1)))
    }

    func togglePlayPause() {
        guard isActive else { return }
        if isPlaying { pause() } else { resume() }
    }

    func pause() {
        guard synthesizer.isSpeaking, !synthesizer.isPaused else { return }
        synthesizer.pauseSpeaking(at: .word)
        isPlaying = false
        updateNowPlaying()
    }

    func resume() {
        guard isActive else { return }
        if synthesizer.isPaused {
            synthesizer.continueSpeaking()
        } else if !synthesizer.isSpeaking {
            enqueue(from: currentParagraph)  // restart from where we stopped
        }
        isPlaying = true
        updateNowPlaying()
    }

    /// Jump to the next paragraph, or end the chapter if already at the last.
    func skipForward() {
        let next = currentParagraph + 1
        if next < paragraphs.count {
            enqueue(from: next)
        } else {
            finishChapter()
        }
    }

    func skipBackward() {
        enqueue(from: max(0, currentParagraph - 1))
    }

    /// Tears everything down — used when the reader closes, or when playback
    /// ends with no further chapter.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        indexOf.removeAll()
        paragraphs = []
        isPlaying = false
        isActive = false
        currentParagraph = 0
        paragraphCount = 0
        chapterLabel = ""
        unwireRemoteCommands()
        clearNowPlaying()
        deactivateSession()
    }

    // MARK: - Internals

    private func enqueue(from index: Int) {
        synthesizer.stopSpeaking(at: .immediate)
        indexOf.removeAll()
        guard paragraphs.indices.contains(index) else { return }
        currentParagraph = index
        let v = voice
        let r = rate
        for i in index..<paragraphs.count {
            let utterance = AVSpeechUtterance(string: paragraphs[i])
            utterance.rate = r
            utterance.voice = v
            utterance.postUtteranceDelay = 0.15  // a small breath between paragraphs
            indexOf[ObjectIdentifier(utterance)] = i
            synthesizer.speak(utterance)
        }
        isPlaying = true
        updateNowPlaying()
    }

    private func finishChapter() {
        synthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
        finishedTick &+= 1  // reader decides whether to advance or stop()
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
            MPNowPlayingInfoPropertyPlaybackQueueCount: paragraphCount,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: currentParagraph,
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
                updateNowPlaying()
            }
        }
    }

    @objc nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                             didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            // Only the last paragraph's natural finish ends the chapter;
            // stopSpeaking(.immediate) fires didCancel instead, not didFinish.
            if let i = indexOf[id], i == paragraphs.count - 1 {
                finishChapter()
            }
        }
    }
}
