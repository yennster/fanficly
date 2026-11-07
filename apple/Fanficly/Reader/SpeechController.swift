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
/// iOS Settings → Accessibility → Spoken Content → Voices (or set up Personal Voice
/// under Settings → Accessibility → Personal Voice) and pick one in
/// Reader settings; otherwise a voice for the work's language is used (#184),
/// or the platform default voice when the work is in the device's language.
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
    /// The work's language as AO3 names it ("Español"), for the voice.
    private var workLanguage = ""
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    /// Held while a chapter is loaded so macOS's App Nap doesn't throttle the
    /// app once its window is minimized or hidden: the synthesizer's callbacks
    /// (paragraph tracking, the next chapter) would otherwise stall.
    private var narrationActivity: NSObjectProtocol?
    /// An interruption paused narration that was playing; only then does its
    /// end resume it (narration you paused yourself stays paused).
    private var pausedByInterruption = false

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

    /// The voice picked in Settings; with none (or one that isn't installed
    /// here, synced from another device), a voice for the work's language.
    private var voice: AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: Self.voiceKey), !id.isEmpty,
           let picked = AVSpeechSynthesisVoice(identifier: id) {
            return picked
        }
        return Self.automaticVoice(forWorkLanguage: workLanguage)
    }

    /// An installed voice for the work's language (#184), or nil, which is the
    /// system's voice for its own language: when the work is in that language,
    /// its language is unknown, or no voice speaks it. Novelty voices and
    /// Personal Voice are only ever used when picked.
    static func automaticVoice(forWorkLanguage language: String) -> AVSpeechSynthesisVoice? {
        guard let tag = SpeechLanguage.tag(forWorkLanguage: language) else { return nil }
        let installed = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice)
        }
        let id = SpeechLanguage.voiceID(
            forTag: tag,
            voices: installed.map { .init(id: $0.identifier, language: $0.language, quality: $0.quality.rawValue) },
            defaultLanguage: AVSpeechSynthesisVoice.currentLanguageCode(),
            preferredID: AVSpeechSynthesisVoice(language: tag)?.identifier)
        return id.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
    }

    // MARK: - Control

    /// Loads a chapter's paragraphs and starts speaking from `paragraph`.
    /// False when the chapter has nothing to speak (nothing is loaded then).
    @discardableResult
    func play(paragraphs: [String], workTitle: String, author: String, language: String = "",
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
        self.workLanguage = language
        self.chapterLabel = chapterLabel
        isActive = true
        activateSession()
        if narrationActivity == nil {
            narrationActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Reading a chapter aloud")
        }
        wireRemoteCommands()
        enqueue(from: max(0, paragraph))
        return true
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
        // An interruption (a call, Siri, an alarm) deactivates the session;
        // speaking from the background needs it active again.
        activateSession()
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
        isPlaying = false
        onChapterFinished?()  // reader decides whether to advance or stop()
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
            if let i = indexOf[id], i == spokenIndices.last {
                finishChapter()
            }
        }
    }
}

// MARK: - The work's language (#184)

/// Which installed voice reads a work when no voice is picked in Settings:
/// one for the work's language, so a Spanish work isn't read by an English
/// voice. Pure, so `SpeechLanguageTests` covers it; the Windows app's
/// `SpeechLanguage` (Fanficly.Core) is the same table and rules.
enum SpeechLanguage {
    /// AO3's language names as a work shows them (`dd.language`), plus their
    /// English names and AO3's short codes, lowercased → a BCP-47 tag.
    /// Chinese is handled in `tag(forWorkLanguage:)`: AO3 has several.
    static let names: [String: String] = [
        "english": "en",
        "español": "es", "spanish": "es",
        "français": "fr", "french": "fr",
        "deutsch": "de", "german": "de",
        "русский": "ru", "russian": "ru",
        "日本語": "ja", "japanese": "ja",
        "한국어": "ko", "korean": "ko",
        "português brasileiro": "pt-BR", "ptbr": "pt-BR",
        "português europeu": "pt-PT", "ptpt": "pt-PT",
        "português": "pt", "portuguese": "pt",
        "italiano": "it", "italian": "it",
        "polski": "pl", "polish": "pl",
        "nederlands": "nl", "dutch": "nl",
        "türkçe": "tr", "turkish": "tr",
        "tiếng việt": "vi", "vietnamese": "vi",
        "bahasa indonesia": "id", "indonesian": "id",
        "bahasa malaysia": "ms", "malay": "ms",
        "català": "ca", "catalan": "ca",
        "čeština": "cs", "czech": "cs",
        "dansk": "da", "danish": "da",
        "eesti keel": "et", "eesti": "et", "estonian": "et",
        "suomi": "fi", "finnish": "fi",
        "ελληνικά": "el", "greek": "el",
        "עברית": "he", "hebrew": "he",
        "हिन्दी": "hi", "hindi": "hi",
        "magyar": "hu", "hungarian": "hu",
        "íslenska": "is", "icelandic": "is",
        "latviešu valoda": "lv", "latviešu": "lv", "latvian": "lv",
        "lietuvių kalba": "lt", "lietuvių": "lt", "lithuanian": "lt",
        "norsk": "nb", "norwegian": "nb", "no": "nb",
        "română": "ro", "romanian": "ro",
        "slovenčina": "sk", "slovak": "sk",
        "slovenščina": "sl", "slovenian": "sl", "slv": "sl",
        "svenska": "sv", "swedish": "sv",
        "ไทย": "th", "thai": "th",
        "українська": "uk", "ukrainian": "uk",
        "العربية": "ar", "arabic": "ar",
        "فارسی": "fa", "persian": "fa",
        "filipino": "fil",
        "hrvatski": "hr", "croatian": "hr",
        "српски": "sr", "serbian": "sr",
        "български": "bg", "bulgarian": "bg",
        "gaeilge": "ga", "irish": "ga",
        "cymraeg": "cy", "welsh": "cy",
        "galego": "gl", "galician": "gl",
        "euskara": "eu", "basque": "eu",
        "esperanto": "eo",
        "lingua latina": "la", "latin": "la",
        "kiswahili": "sw", "swahili": "sw",
        "বাংলা": "bn", "bengali": "bn",
        "தமிழ்": "ta", "tamil": "ta",
        "తెలుగు": "te", "telugu": "te",
        "ಕನ್ನಡ": "kn", "kannada": "kn",
        "മലയാളം": "ml", "malayalam": "ml",
        "मराठी": "mr", "marathi": "mr",
        "ગુજરાતી": "gu", "gujarati": "gu",
        "ਪੰਜਾਬੀ": "pa", "punjabi": "pa",
        "اردو": "ur", "urdu": "ur",
        "afrikaans": "af",
        "shqip": "sq", "albanian": "sq",
        "bosanski": "bs", "bosnian": "bs", "bos": "bs",
        "македонски": "mk", "macedonian": "mk",
        "zh": "zh-CN", "yue": "zh-HK",
    ]

    /// The BCP-47 tag for a work's language: an AO3 name ("Español"), an
    /// English one, or a code already (an imported EPUB's `dc:language`).
    /// Nil when it's empty or unknown, which leaves the system's voice.
    static func tag(forWorkLanguage raw: String) -> String? {
        let v = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !v.isEmpty else { return nil }
        // AO3's Chinese languages: 中文-普通话 國語 (Mandarin), 中文-广东话 粵語
        // (Cantonese) and a few more, all written in Chinese characters.
        if v.hasPrefix("中文") || v.hasPrefix("chinese") || v == "mandarin" || v == "cantonese" {
            return v.contains("广东") || v.contains("粵") || v.contains("cantonese") ? "zh-HK" : "zh-CN"
        }
        if let tag = names[v] { return tag }
        if v.range(of: #"^[a-z]{2,3}(?:[-_][a-z0-9]{2,8})*$"#, options: .regularExpression) != nil {
            return v.replacingOccurrences(of: "_", with: "-")
        }
        return nil
    }

    /// An installed voice, as the pure picker sees it. `quality` ranks higher
    /// for better voices (AVSpeechSynthesisVoiceQuality's raw value; the same
    /// for every Windows voice).
    struct Voice: Equatable, Sendable {
        let id: String
        let language: String
        let quality: Int
    }

    /// The language part of a tag ("pt" for "pt-BR"), with Norwegian's two
    /// codes as one.
    static func base(_ tag: String) -> String {
        let b = tag.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return b == "no" ? "nb" : b
    }

    /// Whether one voice reads both tags: the same language, where Mandarin and
    /// Cantonese (zh-HK) count as two.
    static func sameSpokenLanguage(_ a: String, _ b: String) -> Bool {
        guard base(a) == base(b) else { return false }
        func cantonese(_ t: String) -> Bool { t.lowercased().replacingOccurrences(of: "_", with: "-").hasPrefix("zh-hk") }
        return base(a) != "zh" || cantonese(a) == cantonese(b)
    }

    /// The voice to read a work in `tag`'s language with, or nil for the
    /// system's own voice: when the work is in the system voice's language
    /// (`defaultLanguage`), or no installed voice speaks it. Prefers the
    /// exact dialect (pt-BR over pt-PT), then the better voice, then
    /// `preferredID` (the system's pick for that language), then the id.
    /// A Mandarin work only falls back to a Cantonese voice when nothing
    /// else speaks Chinese.
    static func voiceID(forTag tag: String?, voices: [Voice], defaultLanguage: String,
                        preferredID: String? = nil) -> String? {
        guard let tag, !tag.isEmpty else { return nil }
        let want = tag.lowercased()
        let wantBase = base(want)
        guard !sameSpokenLanguage(want, defaultLanguage) else { return nil }
        func dialect(_ v: Voice) -> Int {
            let lang = v.language.lowercased().replacingOccurrences(of: "_", with: "-")
            if lang == want { return 2 }
            if wantBase == "zh", want != "zh-hk", lang == "zh-hk" { return 0 }
            return 1
        }
        let best = voices.filter { base($0.language) == wantBase }.min { a, b in
            let (da, db) = (dialect(a), dialect(b))
            if da != db { return da > db }
            if a.quality != b.quality { return a.quality > b.quality }
            let (pa, pb) = (a.id == preferredID, b.id == preferredID)
            if pa != pb { return pa }
            return a.id < b.id
        }
        return best?.id
    }

    /// Settings' voice list order: the system language's voices first, then
    /// the rest by their languages' names.
    static func listsBefore(_ a: (tag: String, name: String), _ b: (tag: String, name: String),
                            systemLanguage: String) -> Bool {
        let (aSystem, bSystem) = (base(a.tag) == base(systemLanguage), base(b.tag) == base(systemLanguage))
        if aSystem != bSystem { return aSystem }
        let order = a.name.localizedStandardCompare(b.name)
        return order == .orderedSame ? a.tag < b.tag : order == .orderedAscending
    }
}
