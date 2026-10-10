import SwiftUI

struct ReaderView: View {
    let title: String
    let author: String
    let authorUsername: String
    let chapters: [AO3ChapterPayload]
    let summary: AO3WorkSummary?
    /// Optional upward report of the chapter currently being read (1-based), so
    /// a parent's "Comments" action can scope to the right chapter. Written
    /// whenever the visible/selected chapter changes.
    var currentChapter: Binding<Int>? = nil

    @AppStorage(ReaderProfile.deviceKey("reader.theme")) private var themeRaw: String = ReaderTheme.system.rawValue
    @AppStorage(ReaderProfile.deviceKey("reader.fontFamily")) private var fontFamilyRaw: String = ReaderFontFamily.newYork.rawValue
    @AppStorage(ReaderProfile.deviceKey("reader.widthPercent")) private var widthPercent: Double = 70.0
    @AppStorage(ReaderProfile.deviceKey("reader.mode")) private var modeRaw: String = ReadingMode.continuous.rawValue
    @AppStorage(ReaderProfile.deviceKey("reader.fontSizePt")) private var fontSizePt: Double = ReaderMetrics.defaultFontSize
    @AppStorage(ReaderProfile.deviceKey("reader.lineSpacingPt")) private var lineSpacingPt: Double = ReaderMetrics.defaultLineSpacing
    @AppStorage(ReaderProfile.deviceKey("reader.paragraphSpacingPt")) private var paragraphSpacingPt: Double = ReaderMetrics.defaultParagraphSpacing
    @AppStorage(ReaderProfile.deviceKey("reader.pageTurnHaptics")) private var pageTurnHaptics: Bool = false
    @AppStorage(ReaderProfile.deviceKey("reader.pageTurnAnimations")) private var pageTurnAnimations: Bool = true
    @AppStorage(ReaderProfile.deviceKey("reader.kerningPt")) private var kerningPt: Double = ReaderMetrics.defaultKerning
    @AppStorage(ReaderProfile.deviceKey("reader.boldText")) private var boldText: Bool = false
    // Page-by-page shows two pages side by side on a wide window (iPhone Duo
    // unfolded, iPad landscape, Mac). Per device but not in reading profiles:
    // it's about the screen's shape, not typography.
    @AppStorage(ReaderProfile.deviceKey("reader.twoPageSpread")) private var twoPageSpread: Bool = true
    // Text width inside each page of a two-page spread (one-page mode keeps
    // widthPercent, the Margins setting).
    @AppStorage(ReaderProfile.deviceKey("reader.spreadWidthPercent")) private var spreadWidthPercent: Double = ReaderSpread.defaultWidthPercent
    // Keep the display awake while reading (like a video player), so the screen
    // doesn't dim/lock mid-page when you go a while without touching it.
    @AppStorage("reader.keepScreenAwake") private var keepScreenAwake: Bool = true
    // Render images embedded in chapters (off = historical text-only reader).
    // Global, not per-device: it's a content/privacy choice, not typography.
    // Every convertParagraphs/speechParagraphs call in the reader must pass
    // this same flag or paragraph indices (anchors, TTS karaoke, progress)
    // drift between modes.
    @AppStorage("reader.showImages") private var showImages: Bool = false
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    // Start of the current active-reading span, for the Stats tab. Set while
    // the reader is open and foregrounded; nil when paused (backgrounded/closed).
    @State private var activeSpanStart: Date?
    @State private var selectedChapterIndex: Int = 1
    @State private var visibleChapterIndex: Int = 1
    @State private var currentAnchor: ReadingAnchor?
    @State private var loadedFromDisk = false
    @State private var isRestoring = false
    @State private var lastSaveAt: Date = .distantPast
    // Paginated-mode one-shot paragraph restore.
    @State private var pendingParagraphRestore: ReadingAnchor?
    @State private var lastAnchorSampleAt: Date = .distantPast
    /// Newest anchor offsets between samples (a reference, so storing them
    /// every scroll frame doesn't re-render). See `scheduleTrailingAnchorSample`.
    @State private var trailingAnchorSample = TrailingAnchorSample()
    // Text-to-speech ("Listen") narration of the current chapter.
    @State private var speech = SpeechController()
    @State private var isUIMinimized: Bool = false
    @State private var listeningChapter: Int?
    // Page-by-page mode
    @State private var paginatedPages: [ChapterPage] = []
    /// Page-by-page selection is always a page id; with a spread on screen the
    /// TabView shows the spread containing it (see spreadSelection).
    @State private var selectedPageId: String = ""
    /// The two-page spread geometry while one is showing (nil = one page).
    @State private var spreadLayout: ReaderSpread.Layout?
    @State private var parsedAtoms: [Int: [ParagraphAtom]] = [:]
    @State private var stableWidth: CGFloat = 0
    @State private var stableHeight: CGFloat = 0
    /// The page area pages are measured for: the page container's height with
    /// the reader controls (nav bar, page footer, narration bar) showing.
    /// Measuring for the chrome-hidden height cut the last lines off whenever
    /// the controls were up; this way a page always fits, and hiding the
    /// controls only adds bottom margin — the page count doesn't change.
    @State private var pageArea = PageAreaTracker()
    /// True while page-by-page shows an open-book spread on iPhone Duo
    /// (bookTopShift): the pages sit at a fixed spot under a transparent top
    /// bar, and the running footer stays put even with the controls hidden.
    @State private var duoBookLayout = false
    private let scrollSpace = "readerScroll"

    // Profile Management
    @AppStorage("app.zoomScale") private var zoomScale: Double = 1.0
    @AppStorage(ReaderProfile.deviceActiveProfileKey) private var activeProfileName: String = "Default"
    @AppStorage("reader.profiles") private var profilesJSON: String = ""
    @State private var showingNewProfileAlert = false
    @State private var newProfileName = ""
    @FocusState private var isReaderFocused: Bool
    @State private var showingErrorAlert = false
    @State private var errorMessage = ""

    private var profiles: [ReaderProfile] {
        ReaderProfile.loadProfiles(from: profilesJSON)
    }

    private func saveCurrentToActiveProfile() {
        var list = profiles
        if let idx = list.firstIndex(where: { $0.name == activeProfileName }) {
            list[idx].themeRaw = themeRaw
            list[idx].fontFamilyRaw = fontFamilyRaw
            list[idx].widthPercent = widthPercent
            list[idx].modeRaw = modeRaw
            list[idx].fontSizePt = fontSizePt
            list[idx].lineSpacingPt = lineSpacingPt
            list[idx].paragraphSpacingPt = paragraphSpacingPt
            list[idx].pageTurnHaptics = pageTurnHaptics
            list[idx].pageTurnAnimations = pageTurnAnimations
            list[idx].kerningPt = kerningPt
            list[idx].boldText = boldText
        } else {
            let newProfile = ReaderProfile(
                name: activeProfileName,
                themeRaw: themeRaw,
                fontFamilyRaw: fontFamilyRaw,
                widthRaw: nil,
                widthPercent: widthPercent,
                modeRaw: modeRaw,
                fontSizePt: fontSizePt,
                lineSpacingPt: lineSpacingPt,
                paragraphSpacingPt: paragraphSpacingPt,
                pageTurnHaptics: pageTurnHaptics,
                pageTurnAnimations: pageTurnAnimations,
                kerningPt: kerningPt,
                boldText: boldText
            )
            list.append(newProfile)
        }
        saveProfiles(list)
        queueBackup()
    }

    private func selectProfile(_ profile: ReaderProfile) {
        activeProfileName = profile.name
        themeRaw = profile.themeRaw
        fontFamilyRaw = profile.fontFamilyRaw
        widthPercent = profile.widthPercent ?? 70.0
        modeRaw = profile.modeRaw
        fontSizePt = profile.fontSizePt
        lineSpacingPt = profile.lineSpacingPt
        paragraphSpacingPt = profile.paragraphSpacingPt
        pageTurnHaptics = profile.pageTurnHaptics
        pageTurnAnimations = profile.pageTurnAnimations
        kerningPt = profile.kerningPt ?? ReaderMetrics.defaultKerning
        boldText = profile.boldText ?? false
        queueBackup()
    }

    private func deleteProfile(_ name: String) {
        var list = profiles
        list.removeAll { $0.name == name }
        if activeProfileName == name {
            activeProfileName = "Default"
            if let defaultProf = list.first(where: { $0.name == "Default" }) {
                selectProfile(defaultProf)
            } else {
                selectProfile(ReaderProfile.defaultProfiles[0])
            }
        }
        saveProfiles(list)
        queueBackup()
    }

    private func saveNewProfile(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if profiles.contains(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
            errorMessage = "A profile named \"\(trimmed)\" already exists."
            showingErrorAlert = true
            return
        }
        activeProfileName = trimmed
        saveCurrentToActiveProfile()
    }

    private func overwriteProfile(_ name: String) {
        var list = profiles
        if let idx = list.firstIndex(where: { $0.name == name }) {
            list[idx].themeRaw = themeRaw
            list[idx].fontFamilyRaw = fontFamilyRaw
            list[idx].widthPercent = widthPercent
            list[idx].modeRaw = modeRaw
            list[idx].fontSizePt = fontSizePt
            list[idx].lineSpacingPt = lineSpacingPt
            list[idx].paragraphSpacingPt = paragraphSpacingPt
            list[idx].pageTurnHaptics = pageTurnHaptics
            list[idx].pageTurnAnimations = pageTurnAnimations
            list[idx].kerningPt = kerningPt
            list[idx].boldText = boldText
            saveProfiles(list)
            queueBackup()
        }
    }

    private func saveProfiles(_ list: [ReaderProfile]) {
        // Diffing against the stored JSON stamps edits and tombstones removed
        // names, so deletions survive the cloud merge in publishLocalProfiles.
        let json = ReaderProfile.saveProfiles(list, previousJSON: profilesJSON)
        profilesJSON = json
        ReaderProfileSyncStore.publishLocalProfiles(json)
    }

    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .system }
    private var fontFamily: ReaderFontFamily { ReaderFontFamily(rawValue: fontFamilyRaw) ?? .newYork }
    private var mode: ReadingMode { ReadingMode(rawValue: modeRaw) ?? .continuous }
    private var fontSize: CGFloat { CGFloat(fontSizePt) / CGFloat(zoomScale) }
    private var lineSpacing: CGFloat { CGFloat(lineSpacingPt) / CGFloat(zoomScale) }
    private var paragraphSpacing: CGFloat { CGFloat(paragraphSpacingPt) / CGFloat(zoomScale) }
    private var kerning: CGFloat { CGFloat(kerningPt) / CGFloat(zoomScale) }

    init(title: String, author: String, chapters: [AO3ChapterPayload], summary: AO3WorkSummary? = nil) {
        ReaderProfile.migrateLegacySettingsIfNeeded()
        self.title = title
        self.author = author
        self.authorUsername = summary?.authorUsername ?? ""
        self.chapters = chapters
        self.summary = summary
    }

    init(work: Work, currentChapter: Binding<Int>? = nil) {
        ReaderProfile.migrateLegacySettingsIfNeeded()
        self.currentChapter = currentChapter
        self.title = work.title
        self.author = work.authorName
        self.authorUsername = work.authorUsername
        self.chapters = work.chapters
            .sorted(by: { $0.index < $1.index })
            .map { AO3ChapterPayload(index: $0.index, title: $0.title, bodyHTML: $0.bodyHTML, aoId: $0.aoId) }
        self.summary = AO3WorkSummary(
            id: work.ao3Id,
            title: work.title,
            author: work.authorName,
            authorUsername: work.authorUsername,
            summary: work.summary,
            rating: work.rating,
            warnings: work.warnings,
            categories: work.categories,
            fandoms: work.fandoms,
            characters: work.characters,
            relationships: work.relationships,
            freeforms: work.freeforms,
            wordCount: work.wordCount,
            chapterCount: work.chapterCount,
            totalChapters: work.totalChapters,
            language: work.language,
            kudos: work.kudos,
            hits: work.hits,
            isComplete: work.isComplete,
            updatedAt: work.updatedAt
        )
    }

    init(payload: AO3WorkPayload, currentChapter: Binding<Int>? = nil) {
        ReaderProfile.migrateLegacySettingsIfNeeded()
        self.currentChapter = currentChapter
        self.title = payload.summary.title
        self.author = payload.summary.author
        self.authorUsername = payload.summary.authorUsername
        self.chapters = payload.chapters
        self.summary = payload.summary
    }

    /// The chapter the reader is actually on: the visible one in continuous
    /// scroll, the selected page in paginated / page-by-page.
    private var effectiveChapterIndex: Int {
        mode == .continuous ? visibleChapterIndex : selectedChapterIndex
    }

    /// Push the current chapter up to a parent (for its Comments action).
    private func reportCurrentChapter() {
        currentChapter?.wrappedValue = effectiveChapterIndex
    }

    /// Reports the current chapter on change + first appearance, kept off the
    /// main reader chain so the SwiftUI type-checker stays within budget.
    private struct ChapterReportModifier: ViewModifier {
        let chapter: Int
        let report: () -> Void
        func body(content: Content) -> some View {
            content
                .onChange(of: chapter) { _, _ in report() }
                .onAppear { report() }
        }
    }

    /// Reader lifecycle, lifted out of the main body chain so it type-checks
    /// independently. Keeps the screen awake while reading, tears down speech on
    /// exit, and drives the Stats active-reading timer: start on appear and when
    /// the app returns to `.active` while this reader is visible, flush on
    /// disappear and when it leaves.
    private struct ReaderLifecycleModifier: ViewModifier {
        let keepScreenAwake: Bool
        let scenePhase: ScenePhase
        let applyKeepScreenAwake: (Bool) -> Void
        let startTimer: () -> Void
        let flushTimer: () -> Void
        let stopSpeech: () -> Void
        let readerClosed: () -> Void

        /// Whether this reader is actually on screen. A reader left in the
        /// NavigationStack under a pushed view (author page, another reader)
        /// still receives scenePhase changes; without this check every return
        /// to `.active` would restart its timer and record phantom reading
        /// time — two stacked readers double-counting the same wall-clock span.
        @State private var isVisible = false

        func body(content: Content) -> some View {
            content
                .onAppear {
                    isVisible = true
                    applyKeepScreenAwake(keepScreenAwake)
                    startTimer()
                }
                .onChange(of: keepScreenAwake) { _, on in applyKeepScreenAwake(on) }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        if isVisible { startTimer() }
                    } else {
                        flushTimer()
                    }
                }
                .onDisappear {
                    isVisible = false
                    stopSpeech()
                    applyKeepScreenAwake(false)
                    flushTimer()
                    readerClosed()
                }
        }
    }

    var body: some View {
        let scheme = theme.preferredColorScheme ?? systemColorScheme
        let fg = theme.foreground(for: scheme)
        let bg = theme.background(for: scheme)

        Group {
            switch mode {
            case .continuous: continuousBody(fg: fg, bg: bg)
            case .paginated:  paginatedBody(fg: fg, bg: bg)
            case .pageByPage: pageByPageBody(fg: fg, bg: bg)
            }
        }
        // Floating narration controls when "Listen" is active.
        .safeAreaInset(edge: .bottom) {
            if speech.isActive {
                narrationBar(fg: fg, bg: bg)
            } else if mode == .pageByPage && (!isUIMinimized || duoBookLayout) {
                pageFooterBar(fg: fg, bg: bg)
            }
        }
        // The reader has no text input, so it must never reserve room for the
        // keyboard. Without this, focus landing on the page (it's
        // `.focusable()` for hardware arrow-key turns, see
        // ReaderKeyPressModifier), e.g. on returning from the background,
        // can leave iOS holding a phantom keyboard safe-area inset with no
        // keyboard on screen. Applied outside the bottom bars, not just the
        // page: inside, the page footer / narration bar still rode up on the
        // phantom inset, with a keyboard-high blank band under it, and
        // page-by-page measured its pages for the squashed area above it.
        // The home-indicator inset is unaffected.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // Paint the nav bar with the reader's own background so it blends into
        // the page instead of showing the default translucent gray material.
        .toolbarColorScheme(theme.preferredColorScheme, for: .navigationBar)
        .toolbarBackground(bg, for: .navigationBar)
        .toolbarBackground(duoBookLayout ? .hidden : .visible, for: .navigationBar)
        .toolbar(isUIMinimized ? .hidden : .visible, for: .navigationBar)
        .toolbar {
            if chapters.count > 1 {
                ToolbarItem(placement: .topBarTrailing) { chaptersMenu }
            }
            ToolbarItem(placement: .topBarTrailing) { typographyMenu }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isUIMinimized = true
                    }
                } label: {
                    Label("Hide reader controls", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                // Hiding the toolbar removes every visible way back for
                // VoiceOver users; the custom "Show reader controls" action on
                // the reader body (readerChromeAccessibilityActions) is the
                // escape hatch — keep them in sync.
                .accessibilityHint("Hides the toolbar. To bring it back, use the Show Reader Controls action on the story text.")
            }
        }
        // When a chapter finishes narrating, roll on to the next (or stop).
        .onChange(of: speech.finishedTick) { _, _ in advanceNarration() }
        // Keep a parent informed of the chapter being read (for its Comments
        // action). A ViewModifier so its onChange/onAppear are type-checked
        // outside this already-long chain (which otherwise times out).
        .modifier(ChapterReportModifier(chapter: effectiveChapterIndex, report: reportCurrentChapter))
        // Screen-awake + speech teardown + the Stats active-reading timer, all
        // in one ViewModifier so this long body chain stays within the
        // type-checker's budget (see ChapterReportModifier for the same reason).
        .modifier(ReaderLifecycleModifier(
            keepScreenAwake: keepScreenAwake,
            scenePhase: scenePhase,
            applyKeepScreenAwake: { applyKeepScreenAwake($0) },
            startTimer: { startReadingTimer() },
            flushTimer: { recordReadingSpan(restart: false) },
            stopSpeech: { speech.stop() },
            readerClosed: {
                ReviewPrompter.shared.readerClosed(stats: { ReadingStatsStore.snapshots(in: modelContext) })
            }
        ))
        .onChange(of: themeRaw) { _, _ in queueBackup() }
        .onChange(of: fontFamilyRaw) { _, _ in queueBackup() }
        .onChange(of: widthPercent) { _, _ in queueBackup() }
        .onChange(of: modeRaw) { _, _ in queueBackup() }
        .onChange(of: fontSizePt) { _, _ in queueBackup() }
        .onChange(of: lineSpacingPt) { _, _ in queueBackup() }
        .onChange(of: paragraphSpacingPt) { _, _ in queueBackup() }
        .onChange(of: pageTurnHaptics) { _, _ in queueBackup() }
        .onChange(of: pageTurnAnimations) { _, _ in queueBackup() }
        .onChange(of: kerningPt) { _, _ in queueBackup() }
        .onChange(of: boldText) { _, _ in queueBackup() }
        .modifier(ReaderKeyPressModifier(
            mode: mode,
            isReaderFocused: $isReaderFocused,
            turnPageByPage: { turnPageByPage(forward: $0) },
            turnPage: { turnPage(forward: $0) }
        ))
    }

    private func queueBackup() {
        iCloudSyncManager.shared.queueBackup(context: modelContext)
    }

    /// Disables the system idle timer so the display stays awake while reading.
    /// Always passes `false` on exit to hand control back to the OS.
    private func applyKeepScreenAwake(_ enabled: Bool) {
        UIApplication.shared.isIdleTimerDisabled = enabled
    }

    // MARK: - Narration (text-to-speech)

    /// Lives at the top of the typography (Aa) menu rather than as its own
    /// toolbar icon — the reader's nav bar already carries several actions and
    /// the live controls live in the bottom bar once playback starts.
    @ViewBuilder
    private var listenMenuButton: some View {
        Button {
            if speech.isActive {
                speech.stop()
                listeningChapter = nil
            } else {
                startNarration()
            }
        } label: {
            Label(speech.isActive ? "Stop listening" : "Listen to chapter",
                  systemImage: speech.isActive ? "stop.circle" : "headphones")
        }
    }

    private func startNarration() {
        // Speech paragraphs are index-aligned with the rendered ones, so pick up
        // from your live reading position. `currentAnchor` carries both the
        // chapter and paragraph you're on (across all three reading modes), so
        // prefer it; fall back to the effective chapter from the top when no
        // anchor has been sampled yet.
        if let anchor = currentAnchor {
            narrate(chapter: anchor.chapter, from: anchor.paragraph)
        } else {
            narrate(chapter: effectiveChapterIndex, from: 0)
        }
    }

    /// Jump narration to a specific chapter (from its top), keeping the visible
    /// page in sync so the reader follows along.
    private func narrate(toChapter index: Int) {
        guard index != listeningChapter else { return }
        selectedChapterIndex = index
        visibleChapterIndex = index
        narrate(chapter: index, from: 0)
    }

    private func narrate(chapter index: Int, from paragraph: Int) {
        guard let chapter = chapters.first(where: { $0.index == index }) else { return }
        let label = chapter.title.isEmpty ? "Chapter \(index)" : "Chapter \(index): \(chapter.title)"
        listeningChapter = index
        speech.play(paragraphs: HTMLToAttributed.speechParagraphs(chapter.bodyHTML, includeImages: showImages),
                    workTitle: title, author: author, chapterLabel: label, from: paragraph)
    }

    private func advanceNarration() {
        guard let current = listeningChapter,
              let target = ChapterTracking.adjacentChapter(in: chapters.map(\.index),
                                                           current: current, forward: true) else {
            speech.stop()
            listeningChapter = nil
            return
        }
        // Follow along visually so the page tracks what's being read.
        selectedChapterIndex = target
        visibleChapterIndex = target
        narrate(chapter: target, from: 0)
    }

    private func narrationBar(fg: Color, bg: Color) -> some View {
        HStack(spacing: 20) {
            Button { speech.skipBackward() } label: { Image(systemName: "backward.fill") }
                .accessibilityLabel("Previous paragraph")
            Button { speech.togglePlayPause() } label: {
                Image(systemName: speech.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .accessibilityLabel(speech.isPlaying ? "Pause" : "Play")
            Button { speech.skipForward() } label: { Image(systemName: "forward.fill") }
                .accessibilityLabel("Next paragraph")

            if chapters.count > 1 {
                Menu {
                    Picker("Chapter", selection: chapterNarrationBinding) {
                        ForEach(chapters, id: \.index) { ch in
                            Text(ch.title.isEmpty ? "Chapter \(ch.index)"
                                                  : "Chapter \(ch.index): \(ch.title)")
                                .tag(ch.index)
                        }
                    }
                } label: {
                    narrationStatus(fg: fg, showChevron: true)
                }
                .foregroundStyle(fg)
                .accessibilityHint("Choose a chapter to listen to.")
            } else {
                narrationStatus(fg: fg, showChevron: false)
            }
            Spacer()

            // Speaking rate selection menu
            Menu {
                ForEach([0.5, 0.8, 1.0, 1.2, 1.5, 1.8, 2.0], id: \.self) { rate in
                    Button {
                        speech.rateMultiplier = rate
                    } label: {
                        HStack {
                            Text(String(format: "%.1f×", rate))
                            if abs(speech.rateMultiplier - rate) < 0.05 {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text(String(format: "%.1f×", speech.rateMultiplier))
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(fg.opacity(0.12))
                    .cornerRadius(5)
            }
            .accessibilityLabel("Speaking rate")
            .accessibilityValue(String(format: "%.1f times normal speed", speech.rateMultiplier))

            Button {
                speech.stop()
                listeningChapter = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(fg.opacity(0.45))
            }
            .accessibilityLabel("Stop listening")
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(bg)
        .overlay(alignment: .top) {
            Rectangle().fill(fg.opacity(0.12)).frame(height: 0.5)
        }
    }

    /// The chapter label + "¶ x / y" readout shown in the narration bar.
    /// `showChevron` hints that it's a tappable chapter picker.
    private func narrationStatus(fg: Color, showChevron: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Text(speech.chapterLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if showChevron {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(fg.opacity(0.6))
                }
            }
            Text("¶ \(speech.spokenPosition) / \(speech.spokenCount)")
                .font(.caption2)
                .foregroundStyle(fg.opacity(0.6))
        }
        // "¶ 3 / 40" reads as "pilcrow sign" to VoiceOver — speak it properly.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now reading")
        .accessibilityValue("\(speech.chapterLabel), paragraph \(speech.spokenPosition) of \(speech.spokenCount)")
    }

    /// Drives the narration-bar chapter Picker: reads the chapter being read
    /// aloud, and on selection jumps narration to the picked chapter.
    private var chapterNarrationBinding: Binding<Int> {
        Binding(
            get: { listeningChapter ?? effectiveChapterIndex },
            set: { narrate(toChapter: $0) }
        )
    }

    // MARK: - Continuous

    private func continuousBody(fg: Color, bg: Color) -> some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                        titleHeader(fg: fg)
                            .id("__top")
                            .trackChapterOffset(index: 0, in: scrollSpace)

                        ForEach(chapters, id: \.index) { chapter in
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                if chapters.count > 1 {
                                    chapterHeader(chapter, fg: fg)
                                }
                                chapterBlock(chapter, fg: fg)
                            }
                            .id(chapter.index)
                            .trackChapterOffset(index: chapter.index, in: scrollSpace)
                        }
                    }
                    .frame(maxWidth: columnWidth(geo.size.width), alignment: .leading)
                    .padding(.horizontal, (geo.size.width - columnWidth(geo.size.width)) / 2)
                    .padding(.vertical, Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .coordinateSpace(name: scrollSpace)
                // Rotation, an iPhone Duo fold/unfold or a Split View resize
                // reflows the text, and the old offset would land on a
                // different paragraph — put the one you were on back on top.
                .onChange(of: geo.size.width) { old, new in
                    guard abs(old - new) > 1 else { return }
                    beginResize(width: new)
                    guard let anchor = currentAnchor else { return }
                    isRestoring = true
                    Task { await reanchor(to: anchor, proxy: proxy) }
                }
                .onPreferenceChange(ChapterOffsetKey.self) { offsets in
                    if let current = ChapterTracking.currentChapter(offsets: offsets) {
                        visibleChapterIndex = current
                    }
                }
                .onPreferenceChange(ScrollAnchorKey.self) { offsets in
                    // A resize (rotation, iPhone Duo fold, Split View) reflows the
                    // text and moves every anchor without the reader scrolling;
                    // ignore it so `reanchor` restores the pre-resize paragraph.
                    if trailingAnchorSample.width == 0 { trailingAnchorSample.width = geo.size.width }
                    guard abs(trailingAnchorSample.width - geo.size.width) <= 1 else { return }
                    trailingAnchorSample.offsets = offsets
                    guard !isRestoring else { return }
                    // Reaching the very end always registers — bypassing the
                    // sample throttle — so a final flick to the bottom can't
                    // be dropped and progress can actually hit 100%.
                    if let end = endOfContentAnchor(offsets, viewportHeight: geo.size.height) {
                        lastAnchorSampleAt = Date()
                        currentAnchor = end
                        return
                    }
                    // Sample at most ~3x/sec so progress tracking never competes
                    // with the scroll for main-thread time.
                    let now = Date()
                    guard now.timeIntervalSince(lastAnchorSampleAt) > 0.35 else {
                        scheduleTrailingAnchorSample { currentAnchor = $0 }
                        return
                    }
                    lastAnchorSampleAt = now
                    if let anchor = ChapterTracking.topmostAnchor(offsets) {
                        currentAnchor = anchor
                    }
                }
                .background(bg)
                .foregroundStyle(fg)
                .simultaneousGesture(
                    TapGesture().onEnded {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isUIMinimized.toggle()
                        }
                    }
                )
                .accessibilityAction(named: chromeAccessibilityActionName()) {
                    toggleChromeAccessibly()
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if chapters.count > 1 && !isUIMinimized {
                        chapterIndicatorBar(fg: fg, bg: bg)
                    }
                }
                .onChange(of: selectedChapterIndex) { _, newIndex in
                    proxy.scrollTo(newIndex, anchor: .top)
                    Task {
                        try? await Task.sleep(nanoseconds: 60_000_000)
                        proxy.scrollTo(newIndex, anchor: .top)
                    }
                }
                .onChange(of: currentAnchor) { _, anchor in
                    if let anchor { saveProgress(anchor) }
                }
                // Karaoke: keep the paragraph being read aloud in view.
                .onChange(of: speech.currentParagraph) { _, _ in scrollToSpokenParagraph(proxy) }
                .onChange(of: listeningChapter) { _, _ in scrollToSpokenParagraph(proxy) }
                .task { await restoreContinuous(proxy: proxy) }
                .onDisappear { persistNow() }
            }
        }
    }

    /// Scrolls the currently-narrated paragraph toward the upper third of the
    /// viewport (continuous mode). No-op unless narration is running.
    private func scrollToSpokenParagraph(_ proxy: ScrollViewProxy) {
        guard speech.isActive, let chapter = listeningChapter else { return }
        let key = ChapterTracking.key(chapter: chapter, paragraph: speech.currentParagraph)
        withAnimation(.easeInOut(duration: 0.3)) {
            proxy.scrollTo(key, anchor: UnitPoint(x: 0.5, y: 0.32))
        }
    }

    private func restoreContinuous(proxy: ScrollViewProxy) async {
        let anchor = loadAnchorIfNeeded()
        guard let anchor, anchor.chapter > 1 || anchor.paragraph > 0 else { return }
        isRestoring = true
        try? await Task.sleep(nanoseconds: 250_000_000)
        proxy.scrollTo(anchor.chapter, anchor: .top)
        // Paragraphs render asynchronously, so the exact paragraph id may
        // not exist yet — retry until it lands.
        let key = ChapterTracking.key(chapter: anchor.chapter, paragraph: anchor.paragraph)
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 180_000_000)
            proxy.scrollTo(key, anchor: .top)
        }
        isRestoring = false
    }

    /// Loads the saved anchor from disk the first time; afterwards returns
    /// the live in-memory anchor (so mode switches re-anchor correctly).
    private func loadAnchorIfNeeded() -> ReadingAnchor? {
        if !loadedFromDisk {
            loadedFromDisk = true
            if let id = summary?.id, let saved = ReadingProgressStore.load(ao3Id: id, in: modelContext) {
                currentAnchor = saved
                selectedChapterIndex = saved.chapter
            }
        }
        return currentAnchor
    }

    private func persistNow() {
        if let currentAnchor { saveProgress(currentAnchor, force: true, syncWidgetImmediately: true) }
    }

    // MARK: - Reading-time stats

    /// Begin (or resume) timing an active reading span.
    private func startReadingTimer() {
        activeSpanStart = Date()
    }

    /// Record the elapsed active-reading time since `activeSpanStart` into the
    /// reading-stats store, then either clear or restart the span. A single span
    /// is capped at 4 hours so a reader left foregrounded (e.g. overnight) can't
    /// inflate the totals.
    private func recordReadingSpan(restart: Bool) {
        guard let start = activeSpanStart else {
            if restart { activeSpanStart = Date() }
            return
        }
        let elapsed = Date().timeIntervalSince(start)
        activeSpanStart = restart ? Date() : nil
        guard elapsed >= 1, let summary else { return }
        let capped = min(elapsed, 4 * 3600)
        // Credit only as far as the reader has actually read, so words-read and
        // "finished" status track real progress rather than the work's length.
        let progress = currentAnchor.map(readingProgressFraction(for:)) ?? 0
        let justFinished = ReadingStatsStore.record(
            ao3Id: summary.id,
            title: title,
            author: author,
            fandoms: summary.fandoms,
            categories: summary.categories,
            relationships: summary.relationships,
            rating: summary.rating,
            wordCount: summary.wordCount,
            seconds: capped,
            progress: progress,
            isComplete: summary.isComplete,
            in: modelContext
        )
        if justFinished { ReviewPrompter.shared.storyFinished() }
    }

    /// Periodically persist the in-progress span so a force-quit doesn't lose a
    /// long uninterrupted session. Only flushes once the span exceeds two minutes.
    private func checkpointReadingTime() {
        guard let start = activeSpanStart, Date().timeIntervalSince(start) >= 120 else { return }
        recordReadingSpan(restart: true)
    }

    private func saveProgress(_ anchor: ReadingAnchor, force: Bool = false, syncWidgetImmediately: Bool = false) {
        guard let id = summary?.id else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastSaveAt) < 1.5 { return }
        lastSaveAt = now
        checkpointReadingTime()
        ReadingProgressStore.save(
            ao3Id: id,
            anchor: anchor,
            title: title,
            author: author,
            progress: readingProgressFraction(for: anchor),
            syncWidgetImmediately: syncWidgetImmediately,
            in: modelContext
        )
    }

    /// The final paragraph of the final chapter, when its top edge is on
    /// screen — i.e. the reader has reached the very end of the work — else
    /// nil. Reported as the anchor so `readingProgressFraction` reads 1.0;
    /// stride-sampled topmost anchors alone top out a viewport short of the
    /// end, leaving fully-read works stuck below the Finished threshold.
    private func endOfContentAnchor(_ offsets: [String: CGFloat], viewportHeight: CGFloat) -> ReadingAnchor? {
        guard let last = chapters.max(by: { $0.index < $1.index }),
              // Only convert (cached, but not free) once the last chapter's
              // anchors are actually being laid out near the viewport.
              offsets.keys.contains(where: { $0.hasPrefix("c\(last.index)-p") }) else { return nil }
        let lastParagraph = HTMLToAttributed.convertParagraphs(last.bodyHTML).count - 1
        return ChapterTracking.endOfContentAnchor(
            offsets,
            lastChapter: last.index,
            lastParagraph: lastParagraph,
            viewportHeight: viewportHeight
        )
    }

    private func readingProgressFraction(for anchor: ReadingAnchor) -> Double {
        let orderedChapters = chapters.sorted { $0.index < $1.index }
        guard !orderedChapters.isEmpty,
              let chapterOffset = orderedChapters.firstIndex(where: { $0.index == anchor.chapter }) else {
            return 0
        }

        let chapter = orderedChapters[chapterOffset]
        let paragraphCount = max(HTMLToAttributed.convertParagraphs(chapter.bodyHTML, includeImages: showImages).count, 1)
        let paragraphDenominator = max(paragraphCount - 1, 1)
        let paragraphProgress = min(max(Double(anchor.paragraph) / Double(paragraphDenominator), 0), 1)
        let rawProgress = (Double(chapterOffset) + paragraphProgress) / Double(orderedChapters.count)
        return min(max(rawProgress, 0), 1)
    }

    private func nearbyChapterIndexes(current: Int) -> Set<Int> {
        let order = chapters.map(\.index)
        var indexes: Set<Int> = [current]
        if let previous = ChapterTracking.adjacentChapter(in: order, current: current, forward: false) {
            indexes.insert(previous)
        }
        if let next = ChapterTracking.adjacentChapter(in: order, current: current, forward: true) {
            indexes.insert(next)
        }
        return indexes
    }

    private func nearbyPageIds(radius: Int) -> Set<String> {
        guard !paginatedPages.isEmpty else { return [] }
        guard let currentIndex = paginatedPages.firstIndex(where: { $0.id == selectedPageId }) else {
            return Set(paginatedPages.prefix(max(radius * 2 + 1, 1)).map(\.id))
        }

        let lower = max(0, currentIndex - radius)
        let upper = min(paginatedPages.count - 1, currentIndex + radius)
        return Set(paginatedPages[lower...upper].map(\.id))
    }

    private func chapterIndicatorBar(fg: Color, bg: Color) -> some View {
        let chapter = chapters.first(where: { $0.index == visibleChapterIndex })
        let label = chapter?.title.isEmpty == false
            ? "Chapter \(visibleChapterIndex) · \(chapter!.title)"
            : "Chapter \(visibleChapterIndex) of \(chapters.count)"
        return HStack {
            Text(label)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(fg.opacity(0.85))
            Spacer()
            Text("\(visibleChapterIndex)/\(chapters.count)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(fg.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(bg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(fg.opacity(0.1)).frame(height: 0.5)
        }
        // One element instead of two loose Texts ("Chapter 3 · Title" + "3/12").
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), chapter \(visibleChapterIndex) of \(chapters.count)")
    }

    private func chapterHeader(_ chapter: AO3ChapterPayload, fg: Color) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Rectangle().fill(Color.accentColor.opacity(0.3)).frame(height: 1)
                Text("CHAPTER \(chapter.index)")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
                Rectangle().fill(Color.accentColor.opacity(0.3)).frame(height: 1)
            }
            if !chapter.title.isEmpty {
                Text(chapter.title)
                    .font(fontFamily.font(size: fontSize + 5, weight: .bold))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.sm)
    }

    // MARK: - Paginated

    private func paginatedBody(fg: Color, bg: Color) -> some View {
        GeometryReader { geo in
            let activeChapterIndexes = nearbyChapterIndexes(current: selectedChapterIndex)
            TabView(selection: $selectedChapterIndex) {
                ForEach(chapters, id: \.index) { chapter in
                    if activeChapterIndexes.contains(chapter.index) {
                        paginatedPage(chapter, fg: fg)
                            .tag(chapter.index)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .tag(chapter.index)
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: (chapters.count > 1 && !isUIMinimized) ? .automatic : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .background(bg)
            .foregroundStyle(fg)
            // Tap-to-turn: tapping the left third goes to the
            // previous chapter, the right third to the next; the middle third is
            // a dead zone so taps on mid-page links/text don't flip the page. A
            // *simultaneous* spatial tap leaves the TabView's swipe paging and
            // each page's vertical scroll fully intact (a plain gesture would
            // swallow them). Disabled for single-chapter works (nothing to turn).
            .simultaneousGesture(
                TapGesture().onEnded {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isUIMinimized.toggle()
                    }
                }
            )
            .accessibilityAction(named: "Next chapter") { accessibilityTurnChapter(forward: true) }
            .accessibilityAction(named: "Previous chapter") { accessibilityTurnChapter(forward: false) }
            .accessibilityAction(named: chromeAccessibilityActionName()) { toggleChromeAccessibly() }
            .task {
                isRestoring = true
                if let anchor = loadAnchorIfNeeded() {
                    selectedChapterIndex = anchor.chapter
                    if anchor.paragraph > 0 { pendingParagraphRestore = anchor }
                }
                let currentChapters = chapters
                let include = showImages
                Task.detached(priority: .background) {
                    for chapter in currentChapters {
                        _ = HTMLToAttributed.convertParagraphs(chapter.bodyHTML, includeImages: include)
                    }
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
                isRestoring = false
            }
            .onChange(of: selectedChapterIndex) { _, chapter in
                visibleChapterIndex = chapter
                if !isRestoring && pendingParagraphRestore == nil {
                    let anchor = ReadingAnchor(chapter: chapter, paragraph: 0)
                    currentAnchor = anchor
                    saveProgress(anchor, force: true)
                }
            }
            // Optional light tap on a page turn (tap-to-turn or swipe), off by
            // default. Suppressed while restoring so opening a work doesn't buzz.
            .sensoryFeedback(trigger: selectedChapterIndex) { _, _ in
                (pageTurnHaptics && !isRestoring && pendingParagraphRestore == nil)
                    ? .impact(weight: .light) : nil
            }
            .onDisappear { persistNow() }
        }
    }

    /// Advances to the adjacent chapter (the unit of a "page" in paginated
    /// mode), clamped to the ends. Used by the tap-to-turn zones; the TabView
    /// animates the selection change into a page slide.
    private func turnPage(forward: Bool) {
        let order = chapters.map(\.index)
        guard let target = ChapterTracking.adjacentChapter(in: order, current: selectedChapterIndex, forward: forward)
        else { return }
        selectedChapterIndex = target
    }

    private func paginatedPage(_ chapter: AO3ChapterPayload, fg: Color) -> some View {
        GeometryReader { geo in
            ScrollViewReader { pageProxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        if chapter.index == chapters.first?.index {
                            titleHeader(fg: fg)
                        }
                        if chapters.count > 1 {
                            chapterHeader(chapter, fg: fg)
                        }
                        chapterBlock(chapter, fg: fg)
                    }
                    .frame(maxWidth: columnWidth(geo.size.width), alignment: .leading)
                    .padding(.horizontal, (geo.size.width - columnWidth(geo.size.width)) / 2)
                    .padding(.top, Spacing.lg)
                    .padding(.bottom, chapters.count > 1 ? 56 : Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                // Each page has its own scroll space; the handler below only sees
                // this page's paragraph anchors.
                .coordinateSpace(name: scrollSpace)
                .onPreferenceChange(ScrollAnchorKey.self) { offsets in
                    guard chapter.index == selectedChapterIndex else { return }
                    // A resize (rotation, iPhone Duo fold, Split View) reflows the
                    // text and moves every anchor without the reader scrolling;
                    // ignore it so `reanchor` restores the pre-resize paragraph.
                    if trailingAnchorSample.width == 0 { trailingAnchorSample.width = geo.size.width }
                    guard abs(trailingAnchorSample.width - geo.size.width) <= 1 else { return }
                    trailingAnchorSample.offsets = offsets
                    guard !isRestoring else { return }
                    // End of the work on screen registers immediately (no
                    // sample throttle) so the final scroll can't be dropped —
                    // same as continuous mode. This page's coordinate space
                    // only carries its own chapter's anchors, so this hits
                    // only on the last chapter's page.
                    if let end = endOfContentAnchor(offsets, viewportHeight: geo.size.height) {
                        lastAnchorSampleAt = Date()
                        currentAnchor = end
                        saveProgress(end)
                        return
                    }
                    let now = Date()
                    guard now.timeIntervalSince(lastAnchorSampleAt) > 0.35 else {
                        scheduleTrailingAnchorSample { anchor in
                            let updated = ReadingAnchor(chapter: chapter.index, paragraph: anchor.paragraph)
                            currentAnchor = updated
                            saveProgress(updated)
                        }
                        return
                    }
                    lastAnchorSampleAt = now
                    if let anchor = ChapterTracking.topmostAnchor(offsets) {
                        let updated = ReadingAnchor(chapter: chapter.index, paragraph: anchor.paragraph)
                        currentAnchor = updated
                        saveProgress(updated)
                    }
                }
                .task(id: selectedChapterIndex) {
                    await restorePaginatedParagraph(chapter: chapter, proxy: pageProxy)
                }
                .onChange(of: geo.size.width) { old, new in
                    guard abs(old - new) > 1, chapter.index == selectedChapterIndex else { return }
                    beginResize(width: new)
                    guard let anchor = currentAnchor else { return }
                    isRestoring = true
                    Task { await reanchor(to: anchor, proxy: pageProxy) }
                }
                // Karaoke: follow the narrated paragraph on this page.
                .onChange(of: speech.currentParagraph) { _, p in
                    guard speech.isActive, chapter.index == listeningChapter else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        pageProxy.scrollTo(ChapterTracking.key(chapter: chapter.index, paragraph: p),
                                           anchor: UnitPoint(x: 0.5, y: 0.32))
                    }
                }
            }
        }
    }

    /// Records the scroll position once updates go quiet. The ~3/sec sample
    /// throttle alone drops the last updates of a fling, so the spot it came
    /// to rest on was never recorded: the tracked anchor (and so saved
    /// progress, and the re-anchor after a resize) could sit a whole fling
    /// behind what's on screen.
    private func scheduleTrailingAnchorSample(_ apply: @escaping @MainActor (ReadingAnchor) -> Void) {
        guard trailingAnchorSample.task == nil else { return }
        trailingAnchorSample.task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            trailingAnchorSample.task = nil
            guard !isRestoring, let anchor = ChapterTracking.topmostAnchor(trailingAnchorSample.offsets) else { return }
            lastAnchorSampleAt = Date()
            apply(anchor)
        }
    }

    /// A resize starts: anchor samples resume at the new width, and a pending
    /// trailing sample (taken from the old layout) is dropped.
    private func beginResize(width: CGFloat) {
        trailingAnchorSample.width = width
        trailingAnchorSample.task?.cancel()
        trailingAnchorSample.task = nil
    }

    /// Phone settings get the line-length cap — see `ReaderMetrics.textColumnWidth`.
    @MainActor private static var limitsLineLength: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// A page's top and bottom margin, inside the area between the reader's
    /// bars. Pagination subtracts exactly this, so measured pages match drawn ones.
    static let pageVerticalMargin: CGFloat = 12

    private func columnWidth(_ containerWidth: CGFloat, widthPercent percent: Double? = nil) -> CGFloat {
        ReaderMetrics.textColumnWidth(containerWidth: containerWidth, widthPercent: percent ?? widthPercent,
                                      fontSize: fontSizePt, limitLineLength: Self.limitsLineLength)
    }

    /// Scrolls the paragraph that was on top back to the top once a resize
    /// has reflowed the text (the tracked anchor is always a rendered one).
    private func reanchor(to anchor: ReadingAnchor, proxy: ScrollViewProxy) async {
        defer { isRestoring = false }
        guard anchor.chapter > 1 || anchor.paragraph > 0 else { return }
        let key = ChapterTracking.key(chapter: anchor.chapter, paragraph: anchor.paragraph)
        for delay: UInt64 in [120, 280] {
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
            proxy.scrollTo(key, anchor: .top)
        }
    }

    private func restorePaginatedParagraph(chapter: AO3ChapterPayload, proxy: ScrollViewProxy) async {
        guard chapter.index == selectedChapterIndex,
              let pending = pendingParagraphRestore,
              pending.chapter == chapter.index,
              pending.paragraph > 0 else { return }
        pendingParagraphRestore = nil  // consume — one shot
        isRestoring = true
        let key = ChapterTracking.key(chapter: chapter.index, paragraph: pending.paragraph)
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 180_000_000)
            proxy.scrollTo(key, anchor: .top)
        }
        isRestoring = false
    }

    // MARK: - Page-by-page mode

    private func pageByPageBody(fg: Color, bg: Color) -> some View {
        GeometryReader { geo in
            let topShift = bookTopShift(geo)
            let area = geo.size.height + topShift
            let areaSample = PageAreaSample(width: geo.size.width, height: area, controlsUp: !isUIMinimized)
            let readingHeight = pageArea.pageHeight > 0 ? pageArea.pageHeight : area
            // Two pages side by side when the window is wide enough; both are
            // paginated at the spread's page width, gutter on iPhone Duo's fold.
            let spread = twoPageSpread
                ? ReaderSpread.layout(containerSize: CGSize(width: geo.size.width, height: readingHeight),
                                      fold: foldFrame(geo))
                : nil
            let trigger = PaginationTrigger(
                chapter: selectedChapterIndex,
                fontSize: fontSizePt / zoomScale,
                fontFamily: fontFamilyRaw,
                widthPercent: spread == nil ? widthPercent : spreadWidthPercent,
                lineSpacing: lineSpacingPt / zoomScale,
                paragraphSpacing: paragraphSpacingPt / zoomScale,
                kerning: kerningPt / zoomScale,
                boldText: boldText,
                showImages: showImages,
                size: CGSize(
                    width: spread?.pageWidth ?? geo.size.width,
                    // The narration bar replaces the page footer as a bottom
                    // inset, so its height is already out of the page area;
                    // the change re-triggers pagination and
                    // restoreOrValidatePageSelection re-lands on the anchor.
                    height: readingHeight
                )
            )
            
            let content = Group {
                if paginatedPages.isEmpty {
                    VStack {
                        Spacer()
                        ProgressView()
                            .tint(fg.opacity(0.5))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Group {
                        if let spread {
                            spreadTabView(layout: spread, fg: fg)
                        } else {
                            let activePageIds = nearbyPageIds(radius: 2)
                            TabView(selection: $selectedPageId) {
                                ForEach(paginatedPages, id: \.id) { page in
                                    if activePageIds.contains(page.id) {
                                        makePageCell(page: page, fg: fg, containerWidth: geo.size.width)
                                    } else {
                                        Color.clear
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .tag(page.id)
                                    }
                                }
                            }
                            .tabViewStyle(.page(indexDisplayMode: .never))
                        }
                    }
                    .simultaneousGesture(
                        SpatialTapGesture().onEnded { value in
                            let x = value.location.x
                            let w = geo.size.width
                            if x < w / 3 {
                                turnPageByPage(forward: false)
                            } else if x > w * 2 / 3 {
                                turnPageByPage(forward: true)
                            } else {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isUIMinimized.toggle()
                                }
                            }
                        }
                    )
                    .accessibilityAction(named: "Next page") { accessibilityTurnPage(forward: true) }
                    .accessibilityAction(named: "Previous page") { accessibilityTurnPage(forward: false) }
                    .accessibilityAction(named: chromeAccessibilityActionName()) { toggleChromeAccessibly() }
                }
            }
            .background(bg)
            .foregroundStyle(fg)
            
            content
                // Pin the pages' top (see bookTopShift).
                .frame(width: geo.size.width, height: geo.size.height + topShift)
                .offset(y: -topShift)
                .task(id: trigger) {
                    await handlePaginationTrigger(trigger)
                }
                .onChange(of: spread, initial: true) { _, layout in
                    spreadLayout = layout
                }
                .onChange(of: isDuoBook(geo), initial: true) { _, book in
                    duoBookLayout = book
                }
                .onChange(of: geo.size, initial: true) { _, newSize in
                    // Pages are measured for the page area with the controls
                    // (nav bar, page footer, narration bar) up, so a page always
                    // fits on screen and hiding them adds margin without
                    // changing the page count. Pages shrink here at once; they
                    // grow back in the settle task below. A genuine layout
                    // change — rotation, a split-view resize (both move the
                    // width), or the window's own height moving (iPhone Duo
                    // pins a picture-in-picture video above the app) — starts
                    // the measurement over.
                    let immersive = immersiveReadingHeight(fallback: newSize.height)
                    let area = newSize.height + bookTopShift(geo)
                    let widthChanged = abs(stableWidth - newSize.width) > 1
                    let windowHeightChanged = abs(stableHeight - immersive) > 1
                    if widthChanged || windowHeightChanged || stableWidth == 0 {
                        stableWidth = newSize.width
                        stableHeight = immersive
                        pageArea.reset(to: area)
                    } else {
                        pageArea.observe(area)
                    }
                }
                .task(id: areaSample) {
                    // Pages grow back once the area has held still, so a
                    // moment's smaller area can't leave every page short. The
                    // wait also skips the in-between sizes while the bars
                    // animate in or out: toggling the controls doesn't
                    // repaginate.
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled else { return }
                    pageArea.settle(areaSample.height, controlsUp: areaSample.controlsUp)
                }
                .onAppear {
                    isRestoring = true
                }
                .onDisappear {
                    persistNow()
                }
                .onChange(of: selectedPageId) { _, pageId in
                    handlePageIdChange(pageId)
                }
                .onChange(of: selectedChapterIndex) { _, newChapter in
                    handleChapterIndexChange(newChapter)
                }
                .onChange(of: speech.currentParagraph) { _, p in
                    handleSpeechParagraphChange(p)
                }
                .onChange(of: listeningChapter) { _, chapter in
                    handleListeningChapterChange(chapter)
                }
        }
    }

    private func makePageCell(page: ChapterPage, fg: Color, containerWidth: CGFloat) -> some View {
        pageCellContent(page: page, fg: fg, containerWidth: containerWidth, widthPercent: widthPercent)
            .contentShape(Rectangle())
            .tag(page.id)
    }

    /// Page-by-page on an unfolded iPhone Duo wide enough for a spread: laid
    /// out like a printed book (see bookTopShift).
    private func isDuoBook(_ geo: GeometryProxy) -> Bool {
        twoPageSpread && geo.size.width >= ReaderSpread.minimumWidth && foldFrame(geo) != nil
    }

    /// How far to move the pages up (positive) or down (negative) so their top
    /// sits `duoTopMargin` below the top of the display, whatever the bars do.
    /// On iPhone Duo the top bar holds only the sidebar button (the reader's
    /// other controls sit in the vertical strip) and the left page's text
    /// starts well clear of it, so the pages use the bar's height instead of
    /// leaving it blank. With the controls hidden the bar's inset goes to zero;
    /// shifting down then keeps the text from jumping up to the display's edge.
    private func bookTopShift(_ geo: GeometryProxy) -> CGFloat {
        guard isDuoBook(geo) else { return 0 }
        return geo.safeAreaInsets.top - Self.duoTopMargin
    }

    /// Where an open-book spread's pages start on iPhone Duo: clear of the
    /// display's rounded corners and camera, with room to breathe.
    private static let duoTopMargin: CGFloat = 32

    /// iPhone Duo's fold (its division region) in the geometry's space, if any.
    /// Lying flat ("open") the fold is inactive — the display reads as one —
    /// but it's still where the gutter belongs, so inactive regions count too.
    private func foldFrame(_ geo: GeometryProxy) -> CGRect? {
        // reservedRegions is new in the iOS 27.1 SDK (SwiftUICore 8.0.85):
        // the #if keeps older Xcodes (CI) compiling, #available the older OSes.
        #if canImport(SwiftUICore, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            let regions = geo.reservedRegions(kind: .division, options: .includeInactive)
            return (regions.first(where: \.isActive) ?? regions.first)?.frame
        }
        #endif
        return nil
    }

    /// Page-by-page as an open book: one TabView page per spread. Selection
    /// stays a page id (progress, restore and narration all work in pages);
    /// the TabView shows whichever spread contains it.
    private func spreadTabView(layout: ReaderSpread.Layout, fg: Color) -> some View {
        let spreads = ReaderSpread.spreads(from: paginatedPages)
        let active = nearbySpreadIds(spreads, radius: 1)
        return TabView(selection: Binding(
            get: { spreads.first(where: { $0.contains(selectedPageId) })?.id ?? selectedPageId },
            set: { selectedPageId = $0 }
        )) {
            ForEach(spreads) { spread in
                if active.contains(spread.id) {
                    makeSpreadCell(spread, layout: layout, fg: fg)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .tag(spread.id)
                }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private func makeSpreadCell(_ spread: ReaderSpread.Spread, layout: ReaderSpread.Layout, fg: Color) -> some View {
        let percent = spreadWidthPercent
        return HStack(spacing: 0) {
            Color.clear.frame(width: max(0, layout.leftX))
            pageCellContent(page: spread.left, fg: fg, containerWidth: layout.pageWidth, widthPercent: percent)
                .frame(width: layout.pageWidth)
            // The gutter: blank space on the fold. No drawn crease — the
            // hardware fold is the only seam, even lying flat.
            Color.clear.frame(width: layout.gutter.upperBound - layout.gutter.lowerBound)
            Group {
                if let right = spread.right {
                    pageCellContent(page: right, fg: fg, containerWidth: layout.pageWidth, widthPercent: percent)
                } else {
                    Color.clear
                }
            }
            .frame(width: layout.pageWidth)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Blank areas (margins, gutter, below the text) take taps too, so the
        // tap-to-turn and show/hide-controls zones work anywhere on the page.
        .contentShape(Rectangle())
        .tag(spread.id)
    }

    private func nearbySpreadIds(_ spreads: [ReaderSpread.Spread], radius: Int) -> Set<String> {
        guard !spreads.isEmpty else { return [] }
        guard let i = spreads.firstIndex(where: { $0.contains(selectedPageId) }) else {
            return Set(spreads.prefix(radius * 2 + 1).map(\.id))
        }
        return Set(spreads[max(0, i - radius)...min(spreads.count - 1, i + radius)].map(\.id))
    }

    @ViewBuilder
    private func pageCellContent(page: ChapterPage, fg: Color, containerWidth: CGFloat, widthPercent requested: Double) -> some View {
        // The title page holds only the work header (no story text, so nothing
        // is paginated against its width): keep it at least the standard width
        // so narrow margins don't crush its metadata row.
        let percent = page.paragraphIndices.isEmpty ? max(requested, ReaderSpread.defaultWidthPercent) : requested
        if let chapter = chapters.first(where: { $0.index == page.chapterIndex }),
           let atoms = parsedAtoms[page.chapterIndex] {
            
            ReaderPageCell(
                page: page,
                chapter: chapter,
                atoms: atoms,
                showTitleHeader: page.pageIndex == 0 && page.chapterIndex == chapters.first?.index,
                showChapterHeader: (page.pageIndex == 0 && page.chapterIndex != chapters.first?.index && chapters.count > 1) ||
                                   (page.pageIndex == 1 && page.chapterIndex == chapters.first?.index && chapters.count > 1),
                titleHeaderView: AnyView(titleHeader(fg: fg)),
                chapterHeaderView: AnyView(chapterHeader(chapter, fg: fg)),
                font: fontFamily.font(size: fontSize),
                lineSpacing: lineSpacing,
                paragraphSpacing: paragraphSpacing,
                kerning: kerning,
                boldText: boldText,
                foreground: fg,
                highlightParagraph: highlightedParagraph(for: page.chapterIndex)
            )
            .frame(maxWidth: columnWidth(containerWidth, widthPercent: percent), alignment: .leading)
            .padding(.horizontal, (containerWidth - columnWidth(containerWidth, widthPercent: percent)) / 2)
            .padding(.vertical, Self.pageVerticalMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ProgressView()
        }
    }

    private func handlePaginationTrigger(_ trigger: PaginationTrigger) async {
        await MainActor.run {
            _ = loadAnchorIfNeeded()
        }
        if trigger.chapter != selectedChapterIndex {
            return
        }
        
        await MainActor.run {
            isRestoring = true
        }

        let result = await performPagination(trigger: trigger)
        // A newer trigger (a resize mid-pagination, e.g. the sidebar
        // collapsing) cancels this task; applying its now-stale pages after
        // the newer ones produced pages taller than the screen.
        guard !Task.isCancelled else { return }
        await MainActor.run {
            guard !Task.isCancelled else { return }
            var activeChapters = Set<Int>()
            activeChapters.insert(selectedChapterIndex)
            if let prev = ChapterTracking.adjacentChapter(in: chapters.map(\.index), current: selectedChapterIndex, forward: false) {
                activeChapters.insert(prev)
            }
            if let next = ChapterTracking.adjacentChapter(in: chapters.map(\.index), current: selectedChapterIndex, forward: true) {
                activeChapters.insert(next)
            }
            
            self.parsedAtoms = self.parsedAtoms.filter { activeChapters.contains($0.key) }
            self.parsedAtoms.merge(result.atoms) { _, new in new }
            self.paginatedPages = result.pages
            
            restoreOrValidatePageSelection()
        }
    }

    private func handlePageIdChange(_ pageId: String) {
        guard mode == .pageByPage else { return }
        let pagesList = self.paginatedPages
        guard var page = pagesList.first(where: { $0.id == pageId }) else { return }
        // A spread selects its left page; when its right page ends the work,
        // anchor there instead so reading to the last line still reads 100%.
        if spreadLayout != nil,
           let right = ReaderSpread.spreads(from: pagesList).first(where: { $0.left.id == pageId })?.right,
           right.chapterIndex == chapters.map(\.index).max(),
           let atoms = parsedAtoms[right.chapterIndex],
           right.paragraphIndices.upperBound >= atoms.count {
            page = right
        }
        
        if page.chapterIndex != selectedChapterIndex {
            selectedChapterIndex = page.chapterIndex
            visibleChapterIndex = page.chapterIndex
        }
        
        if !isRestoring {
            if let atoms = parsedAtoms[page.chapterIndex], !page.paragraphIndices.isEmpty {
                // Landing on the work's final page puts the end of the content
                // on screen: anchor to its last paragraph, not its first, so
                // progress reads 100% (a first-paragraph anchor tops out a
                // page short of the Finished threshold). Restore still lands
                // on the same page — it matches pages by contained paragraph.
                let isFinalPage = page.chapterIndex == chapters.map(\.index).max()
                    && page.paragraphIndices.upperBound >= atoms.count
                let anchorAtomIndex = isFinalPage
                    ? page.paragraphIndices.upperBound - 1
                    : page.paragraphIndices.lowerBound
                if anchorAtomIndex < atoms.count {
                    let originalParaIndex = atoms[anchorAtomIndex].originalParagraphIndex
                    let anchor = ReadingAnchor(chapter: page.chapterIndex, paragraph: originalParaIndex)
                    currentAnchor = anchor
                    saveProgress(anchor)
                }
            } else {
                let anchor = ReadingAnchor(chapter: page.chapterIndex, paragraph: 0)
                currentAnchor = anchor
                saveProgress(anchor)
            }
        }
    }

    private func handleChapterIndexChange(_ newChapter: Int) {
        guard mode == .pageByPage else { return }
        guard !isRestoring else { return }
        let pagesList = self.paginatedPages
        guard !pagesList.isEmpty else { return }
        let currentPage = pagesList.first { $0.id == selectedPageId }
        if currentPage?.chapterIndex != newChapter {
            let anchor = ReadingAnchor(chapter: newChapter, paragraph: 0)
            currentAnchor = anchor
            saveProgress(anchor, force: true)
        }
    }

    private func updatePageSelection(_ pageId: String) {
        if pageTurnAnimations && !reduceMotion {
            selectedPageId = pageId
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selectedPageId = pageId
            }
        }
    }

    private func handleSpeechParagraphChange(_ p: Int) {
        guard mode == .pageByPage else { return }
        guard speech.isActive else { return }
        guard let chapter = listeningChapter else { return }
        
        let pagesList = self.paginatedPages
        if let atoms = parsedAtoms[chapter] {
            if let atomIndex = atoms.firstIndex(where: { $0.originalParagraphIndex == p }) {
                if let page = pagesList.first(where: { $0.chapterIndex == chapter && $0.paragraphIndices.contains(atomIndex) }) {
                    if selectedPageId != page.id {
                        updatePageSelection(page.id)
                    }
                }
            }
        }
    }

    private func handleListeningChapterChange(_ chapter: Int?) {
        guard mode == .pageByPage else { return }
        guard speech.isActive else { return }
        guard let targetChapter = chapter else { return }
        
        let pagesList = self.paginatedPages
        // Narration starting in the chapter on screen picks up from the page
        // you're on (handleSpeechParagraphChange follows it from there).
        if pagesList.first(where: { $0.id == selectedPageId })?.chapterIndex == targetChapter { return }
        // Moving to another chapter: its first page with text, not the work's
        // header-only title page.
        if let page = pagesList.first(where: { $0.chapterIndex == targetChapter && !$0.paragraphIndices.isEmpty }) {
            if selectedPageId != page.id {
                updatePageSelection(page.id)
            }
        }
    }

    private func turnPageByPage(forward: Bool) {
        let targetId: String
        if spreadLayout != nil {
            // A spread turns two pages at a time.
            let spreads = ReaderSpread.spreads(from: paginatedPages)
            guard let current = spreads.firstIndex(where: { $0.contains(selectedPageId) }) else { return }
            let target = forward ? current + 1 : current - 1
            guard spreads.indices.contains(target) else { return }
            targetId = spreads[target].id
        } else {
            guard let currentIndex = paginatedPages.firstIndex(where: { $0.id == selectedPageId }) else { return }
            let targetIndex = forward ? currentIndex + 1 : currentIndex - 1
            guard targetIndex >= 0 && targetIndex < paginatedPages.count else { return }
            targetId = paginatedPages[targetIndex].id
        }

        if pageTurnHaptics {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }

        updatePageSelection(targetId)
    }

    // MARK: - VoiceOver equivalents for the invisible tap zones

    // The tap-to-turn thirds and the chrome-toggle tap are invisible targets
    // VoiceOver can never discover, so the same operations are exposed as
    // custom accessibility actions on the reader body (SwiftUI propagates them
    // to every focused element inside).

    private func toggleChromeAccessibly() {
        withAnimation(.easeInOut(duration: 0.2)) { isUIMinimized.toggle() }
        UIAccessibility.post(notification: .announcement,
                             argument: isUIMinimized ? "Reader controls hidden" : "Reader controls shown")
    }

    private func accessibilityTurnChapter(forward: Bool) {
        let target = selectedChapterIndex + (forward ? 1 : -1)
        guard chapters.contains(where: { $0.index == target }) else { return }
        selectedChapterIndex = target
        UIAccessibility.post(notification: .pageScrolled,
                             argument: "Chapter \(target) of \(chapters.count)")
    }

    private func accessibilityTurnPage(forward: Bool) {
        turnPageByPage(forward: forward)
        if let page = paginatedPages.first(where: { $0.id == selectedPageId }) {
            let total = paginatedPages.filter { $0.chapterIndex == page.chapterIndex }.count
            UIAccessibility.post(notification: .pageScrolled,
                                 argument: "Page \(page.pageIndex + 1) of \(total), chapter \(page.chapterIndex)")
        }
    }

    /// The chrome toggle, as a custom action whose name tracks the state.
    private func chromeAccessibilityActionName() -> String {
        isUIMinimized ? "Show reader controls" : "Hide reader controls"
    }

    private func restoreOrValidatePageSelection() {
        let pagesList: [ChapterPage] = paginatedPages
        guard !pagesList.isEmpty else { return }
        
        if let anchor = currentAnchor {
            let targetChapter: Int = anchor.chapter
            let targetParagraph: Int = anchor.paragraph
            func holdsAnchor(_ page: ChapterPage) -> Bool {
                guard page.chapterIndex == targetChapter, let atoms = parsedAtoms[targetChapter] else { return false }
                return page.paragraphIndices.contains { $0 < atoms.count && atoms[$0].originalParagraphIndex == targetParagraph }
            }
            // The work's header-only title page also stands for paragraph 0.
            func isTitlePageForAnchor(_ page: ChapterPage) -> Bool {
                page.chapterIndex == targetChapter && page.paragraphIndices.isEmpty && targetParagraph == 0
            }
            // Re-paginating (a resize, the narration bar appearing) keeps the
            // page you're on while it still holds the anchor. Otherwise prefer
            // the page with the paragraph over the title page: matching the
            // title page first sent a reader on the first page of text back to
            // the cover every time the layout changed.
            let current = pagesList.first { $0.id == selectedPageId }
            if let current, holdsAnchor(current) || isTitlePageForAnchor(current) {
                isRestoring = false
                return
            }
            if let matchingPage = pagesList.first(where: holdsAnchor) ?? pagesList.first(where: isTitlePageForAnchor) {
                selectedPageId = matchingPage.id
                isRestoring = false
                return
            }
            
            let chapterPages = pagesList.filter { $0.chapterIndex == targetChapter }
            if !chapterPages.isEmpty {
                guard let atoms = parsedAtoms[targetChapter] else { return }
                let closest = chapterPages.first { page in
                    guard !page.paragraphIndices.isEmpty else { return false }
                    let firstIdx = page.paragraphIndices.lowerBound
                    return firstIdx < atoms.count && atoms[firstIdx].originalParagraphIndex >= targetParagraph
                } ?? chapterPages.last!
                selectedPageId = closest.id
                isRestoring = false
                return
            }
        }
        
        let targetPageId = selectedPageId
        if !pagesList.contains(where: { (page: ChapterPage) -> Bool in page.id == targetPageId }) {
            let targetChapter = selectedChapterIndex
            if let firstPage = pagesList.first(where: { (page: ChapterPage) -> Bool in
                page.chapterIndex == targetChapter
            }) {
                selectedPageId = firstPage.id
            } else if let firstPage = pagesList.first {
                selectedPageId = firstPage.id
            }
        }
        isRestoring = false
    }

    @ViewBuilder
    private func pageFooterBar(fg: Color, bg: Color) -> some View {
        let pagesList: [ChapterPage] = paginatedPages
        let targetId = selectedPageId
        if let currentPage = pagesList.first(where: { (page: ChapterPage) -> Bool in
            page.id == targetId
        }) {
            let chapterPages = pagesList.filter { $0.chapterIndex == currentPage.chapterIndex }
            let totalPagesInChapter = chapterPages.count
            // A spread shows two pages: "Pages 3–4 of 12".
            let onScreen = spreadLayout == nil ? nil
                : ReaderSpread.spreads(from: pagesList).first(where: { $0.contains(targetId) })
            let firstNum = (onScreen?.left ?? currentPage).pageIndex + 1
            let pageLabel = onScreen?.right.map { "Pages \(firstNum)–\($0.pageIndex + 1) of \(totalPagesInChapter)" }
                ?? "Page \(firstNum) of \(totalPagesInChapter)"
            
            let chapter = chapters.first(where: { $0.index == currentPage.chapterIndex })
            let label = chapter?.title.isEmpty == false
                ? "Chapter \(currentPage.chapterIndex) · \(chapter!.title)"
                : "Chapter \(currentPage.chapterIndex) of \(chapters.count)"
                
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(fg.opacity(0.85))
                Spacer()
                Text(pageLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(fg.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(bg)
            .overlay(alignment: .top) {
                Rectangle().fill(fg.opacity(0.1)).frame(height: 0.5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label), \(pageLabel.lowercased())")
            // ReaderLayoutTests finds the footer (and reads the page number) by this.
            .accessibilityIdentifier("reader.pageFooter")
            // On iPhone Duo the footer stays while the controls are hidden;
            // tapping it brings them back (as does a tap mid-page).
            .contentShape(Rectangle())
            .onTapGesture {
                guard isUIMinimized else { return }
                withAnimation(.easeInOut(duration: 0.2)) { isUIMinimized = false }
            }
            .accessibilityAddTraits(isUIMinimized ? .isButton : [])
            .accessibilityHint(isUIMinimized ? "Shows the reader controls" : "")
        }
    }

    // MARK: - Pagination algorithm helpers

    /// The height a page fills once the reader chrome is hidden: the device
    /// window minus only its hardware safe-area insets (status bar / home
    /// indicator). It does not change when the nav bar or page footer toggle,
    /// so pinning pagination to it keeps the page count stable as the user
    /// shows/hides the chrome. Falls back to the supplied live height when no
    /// window is reachable (SwiftUI previews / unit tests).
    private func immersiveReadingHeight(fallback: CGFloat) -> CGFloat {
        guard let window = ReaderView.activeKeyWindow() else { return fallback }
        let insets = window.safeAreaInsets
        let height = window.bounds.height - insets.top - insets.bottom
        return height > 100 ? height : fallback
    }

    private static func activeKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    private func performPagination(trigger: PaginationTrigger) async -> PaginationResult {
        // Must match `makePageCell`'s column, or pages are measured at one
        // width and drawn at another.
        let w = ReaderMetrics.textColumnWidth(containerWidth: trigger.size.width,
                                              widthPercent: trigger.widthPercent,
                                              fontSize: trigger.fontSize,
                                              limitLineLength: Self.limitsLineLength)
        let h = trigger.size.height - 2 * Self.pageVerticalMargin
        
        guard w > 50 && h > 100 else {
            return PaginationResult(pages: [], atoms: [:])
        }
        
        var targetChapters: [Int] = [trigger.chapter]
        if let prev = ChapterTracking.adjacentChapter(in: chapters.map(\.index), current: trigger.chapter, forward: false) {
            targetChapters.append(prev)
        }
        if let next = ChapterTracking.adjacentChapter(in: chapters.map(\.index), current: trigger.chapter, forward: true) {
            targetChapters.append(next)
        }
        
        var allPages: [ChapterPage] = []
        var allAtoms: [Int: [ParagraphAtom]] = [:]
        let drawnHeight = ReaderPaginator.measuresDrawnPages
            ? ReaderPaginator.drawnHeightMeasure(width: w, fontSize: CGFloat(trigger.fontSize), fontFamily: fontFamily,
                                                 lineSpacing: CGFloat(trigger.lineSpacing),
                                                 paragraphSpacing: CGFloat(trigger.paragraphSpacing),
                                                 kerning: CGFloat(trigger.kerning), boldText: trigger.boldText)
            : nil
        
        for chIndex in targetChapters.sorted() {
            guard let chapter = chapters.first(where: { $0.index == chIndex }) else { continue }
            
            var atoms = ReaderPaginator.atoms(fromChapterHTML: chapter.bodyHTML, includeImages: trigger.showImages)
            let titleHeaderHeight = ReaderPaginator.estimateTitleHeaderHeight(
                title: title,
                author: author,
                authorUsername: authorUsername,
                summary: summary,
                width: w,
                fontSize: CGFloat(trigger.fontSize),
                fontFamily: fontFamily
            )
            
            let chapterHeaderHeight = ReaderPaginator.estimateChapterHeaderHeight(
                title: chapter.title,
                width: w,
                fontSize: CGFloat(trigger.fontSize),
                fontFamily: fontFamily
            )
            
            let isFirstChapter = chIndex == chapters.first?.index
            let showChapterHeader = chapters.count > 1
            
            // Pagination may split a sentence at a line end (see splitAtomToFit),
            // so the atoms are stored after it — pages index into the split list.
            let chPages = ReaderPaginator.paginateChapter(
                chapterIndex: chIndex,
                atoms: &atoms,
                width: w,
                viewportHeight: h,
                titleHeaderHeight: titleHeaderHeight,
                chapterHeaderHeight: chapterHeaderHeight,
                isFirstChapter: isFirstChapter,
                showChapterHeader: showChapterHeader,
                fontSize: CGFloat(trigger.fontSize),
                fontFamily: fontFamily,
                lineSpacing: CGFloat(trigger.lineSpacing),
                paragraphSpacing: CGFloat(trigger.paragraphSpacing),
                kerning: CGFloat(trigger.kerning),
                boldText: trigger.boldText,
                drawnHeight: drawnHeight
            )

            allAtoms[chIndex] = atoms
            allPages.append(contentsOf: chPages)
        }
        
        return PaginationResult(pages: allPages, atoms: allAtoms)
    }

    private func titleHeader(fg: Color) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(fontFamily.font(size: fontSize + 14, weight: .bold))
            if !author.isEmpty {
                if authorUsername.isEmpty {
                    Text("by \(author)").foregroundStyle(fg.opacity(0.65))
                } else {
                    // Tappable byline → the author's other works.
                    NavigationLink(value: AuthorRef(username: authorUsername, displayName: author)) {
                        HStack(spacing: 4) {
                            Text("by \(author)")
                            Image(systemName: "chevron.right").font(.caption2)
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHint("Shows this author's other works.")
                }
            }
            if let summary {
                WorkHeaderMetadata(summary: summary, foreground: fg)
                if !summary.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Summary")
                            .font(.caption.smallCaps())
                            .foregroundStyle(fg.opacity(0.55))
                        HTMLText(html: summary.summary)
                            .font(fontFamily.font(size: fontSize - 1))
                            .foregroundStyle(fg.opacity(0.85))
                    }
                }
            }
            Divider().overlay(fg.opacity(0.2))
        }
    }

    private func chapterBlock(_ chapter: AO3ChapterPayload, fg: Color) -> some View {
        ChapterContentView(
            chapterIndex: chapter.index,
            html: chapter.bodyHTML,
            font: fontFamily.font(size: fontSize),
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            foreground: fg,
            scrollSpace: scrollSpace,
            kerning: kerning,
            boldText: boldText,
            highlightParagraph: highlightedParagraph(for: chapter.index),
            showImages: showImages
        )
        .padding(.vertical, Spacing.sm)
    }

    /// The paragraph to karaoke-highlight in `chapterIndex`, or nil when that
    /// chapter isn't the one currently being narrated.
    private func highlightedParagraph(for chapterIndex: Int) -> Int? {
        guard speech.isActive, listeningChapter == chapterIndex else { return nil }
        return speech.currentParagraph
    }

    private var chaptersMenu: some View {
        Menu {
            Picker("Jump to chapter", selection: $selectedChapterIndex) {
                ForEach(chapters, id: \.index) { chapter in
                    let label = chapter.title.isEmpty
                        ? "Chapter \(chapter.index)"
                        : "Chapter \(chapter.index): \(chapter.title)"
                    Text(label).tag(chapter.index)
                }
            }
        } label: {
            Image(systemName: "list.bullet")
        }
        .accessibilityLabel("Chapters")
    }

    private var typographyMenu: some View {
        Menu {
            listenMenuButton
            Divider()

            Menu {
                ForEach(profiles) { profile in
                    Menu {
                        Button("Select Profile") {
                            selectProfile(profile)
                        }
                        if profile.name != "Default" {
                            Button("Save Current Settings Here") {
                                overwriteProfile(profile.name)
                            }
                            Button("Delete", role: .destructive) {
                                deleteProfile(profile.name)
                            }
                        }
                    } label: {
                        HStack {
                            Text(profile.name)
                            if profile.name == activeProfileName {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                
                Divider()
                
                Button("Save Current as New Profile...") {
                    newProfileName = ""
                    showingNewProfileAlert = true
                }
            } label: {
                Label("Profile · \(activeProfileName)", systemImage: "person.crop.circle")
            }

            Divider()

            Menu {
                Picker("Reading mode", selection: $modeRaw) {
                    ForEach(ReadingMode.allCases) {
                        Label($0.displayName, systemImage: $0.symbol).tag($0.rawValue)
                    }
                }

            } label: {
                Label("Reading mode · \(mode.displayName)", systemImage: "book.pages")
            }

            if mode == .pageByPage {
                // One or two pages side by side (two only on a wide window:
                // iPhone Duo unfolded, iPad in landscape, the Mac).
                Picker(selection: $twoPageSpread) {
                    Label("One page", systemImage: "rectangle.portrait").tag(false)
                    Label("Two pages", systemImage: "book.pages").tag(true)
                } label: {
                    Label("Pages on screen · \(twoPageSpread ? "Two" : "One")", systemImage: "book.pages")
                }
                .pickerStyle(.menu)
            }

            Menu {
                Picker("Theme", selection: $themeRaw) {
                    ForEach(ReaderTheme.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
            } label: {
                Label("Theme · \(theme.displayName)", systemImage: "paintpalette")
            }

            Menu {
                Picker("Font", selection: $fontFamilyRaw) {
                    ForEach(ReaderFontFamily.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
            } label: {
                Label("Font · \(fontFamily.displayName)", systemImage: "character")
            }

            Toggle(isOn: $boldText) {
                Label("Bold text", systemImage: "bold")
            }

            presetMenu("Text size", value: $fontSizePt, presets: ReaderMetrics.fontSizePresets,
                       icon: "textformat.size")
            presetMenu("Line spacing", value: $lineSpacingPt, presets: ReaderMetrics.lineSpacingPresets,
                       icon: "arrow.up.and.down.text.horizontal")
            presetMenu("Paragraph spacing", value: $paragraphSpacingPt, presets: ReaderMetrics.paragraphSpacingPresets,
                       icon: "text.justify.left")
            presetMenu("Character spacing", value: $kerningPt, presets: ReaderMetrics.kerningPresets,
                       icon: "character.textbox")

            // Margins adjust whichever layout is on screen: a two-page spread
            // has its own width, so tuning one never disturbs the other.
            if spreadLayout != nil {
                presetMenu("Page margins", value: $spreadWidthPercent, presets: ReaderSpread.widthPresets,
                           icon: "arrow.left.and.right.square")
            } else {
                presetMenu("Margins", value: $widthPercent, presets: [
                    (name: "Narrow (50%)", value: 50.0),
                    (name: "Medium (70%)", value: 70.0),
                    (name: "Wide (85%)", value: 85.0),
                    (name: "Full (100%)", value: 100.0)
                ], icon: "arrow.left.and.right.square")
            }
        } label: {
            Image(systemName: "textformat")
        }
        .accessibilityLabel("Reader settings")
        .accessibilityIdentifier("reader_settings_button")
        .alert("New Profile", isPresented: $showingNewProfileAlert) {
            TextField("Profile Name", text: $newProfileName)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                saveNewProfile(name: newProfileName)
            }
        } message: {
            Text("Enter a name for this reader settings configuration profile.")
        }
        .alert(errorMessage, isPresented: $showingErrorAlert) {
            Button("OK", role: .cancel) { }
        }
    }

    /// Quick-pick submenu of named presets that set a numeric reader metric.
    /// (The continuous slider for the same value lives in Settings → Reader.)
    private func presetMenu(_ title: String, value: Binding<Double>,
                            presets: [(name: String, value: Double)], icon: String) -> some View {
        // Mark only the single nearest preset, and only when the value sits
        // essentially on it — so closely-spaced presets (e.g. character
        // spacing, which steps by 0.2) never light up two checkmarks, and
        // slider-tuned values correctly read as "Custom".
        let nearest = presets.min { abs($0.value - value.wrappedValue) < abs($1.value - value.wrappedValue) }
        let current = nearest.flatMap { abs($0.value - value.wrappedValue) < 0.05 ? $0.name : nil }
        return Menu {
            ForEach(presets, id: \.name) { preset in
                Button {
                    value.wrappedValue = preset.value
                } label: {
                    if preset.name == current {
                        Label(preset.name, systemImage: "checkmark")
                    } else {
                        Text(preset.name)
                    }
                }
            }
        } label: {
            Label("\(title) · \(current ?? "Custom")", systemImage: icon)
        }
    }
}

struct ChapterPage: Identifiable, Hashable {
    let id: String
    let chapterIndex: Int
    let pageIndex: Int
    let paragraphIndices: Range<Int>
}

struct ParagraphAtom: Identifiable, Hashable {
    let id = UUID()
    let originalParagraphIndex: Int
    let text: AttributedString
    let isContinuation: Bool
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: ParagraphAtom, rhs: ParagraphAtom) -> Bool {
        lhs.id == rhs.id
    }
}

struct PaginationTrigger: Equatable {
    let chapter: Int
    let fontSize: Double
    let fontFamily: String
    let widthPercent: Double
    let lineSpacing: Double
    let paragraphSpacing: Double
    let kerning: Double
    let boldText: Bool
    let showImages: Bool
    let size: CGSize
}

/// What page-by-page's settle task waits on: any change restarts the wait.
private struct PageAreaSample: Equatable {
    let width: CGFloat
    let height: CGFloat
    let controlsUp: Bool
}

struct PaginationResult {
    let pages: [ChapterPage]
    let atoms: [Int: [ParagraphAtom]]
}

/// Page-by-page's pagination: splits chapters into pages that fit a page
/// area. Pure (no view state), so it's unit-tested across device sizes and
/// reader settings (ReaderPaginationTests). Main-actor like the reader that
/// runs it: it measures with ReaderPageCell's own helpers.
@MainActor
enum ReaderPaginator {
    /// A chapter's paragraphs as sentence atoms, the unit pages are packed in.
    /// `includeImages` must match the reader's images setting, or paragraph
    /// indices drift between modes.
    static func atoms(fromChapterHTML html: String, includeImages: Bool) -> [ParagraphAtom] {
        let paragraphs = HTMLToAttributed.convertParagraphs(html, includeImages: includeImages)
        var atoms: [ParagraphAtom] = []
        for (pIndex, para) in paragraphs.enumerated() {
            let sentences = HTMLToAttributed.splitIntoSentences(para)
            for (sIndex, sentence) in sentences.enumerated() {
                atoms.append(ParagraphAtom(
                    originalParagraphIndex: pIndex,
                    text: sentence,
                    isContinuation: sIndex > 0
                ))
            }
        }
        return atoms
    }

    /// Splits `atom` (a sentence) so its first part, laid out after `leading`
    /// (atoms of the same paragraph already on the page), fits in `budget`.
    /// It keeps the longest run of whole words that fits, which is exactly
    /// where a line ends, so the page fills to its last line and the sentence
    /// carries on at the top of the next one, like a printed book. Returns nil
    /// when not even one word fits, or for an image slot.
    static func splitAtomToFit(_ atom: ParagraphAtom, after leading: [ParagraphAtom], budget: CGFloat,
                                measure: (AttributedString) -> CGFloat) -> (ParagraphAtom, ParagraphAtom)? {
        guard HTMLToAttributed.imageAttachmentURL(in: atom.text) == nil else { return nil }
        let chars = Array(atom.text.characters)
        // Candidate break points: just before each space (the space is dropped).
        let breaks = chars.indices.filter { chars[$0] == " " && $0 > 0 }
        guard !breaks.isEmpty else { return nil }
        func head(_ k: Int) -> AttributedString {
            let end = atom.text.characters.index(atom.text.startIndex, offsetBy: breaks[k])
            return AttributedString(atom.text[atom.text.startIndex..<end])
        }
        func fits(_ k: Int) -> Bool {
            let part = ParagraphAtom(originalParagraphIndex: atom.originalParagraphIndex, text: head(k),
                                     isContinuation: atom.isContinuation)
            return measure(ReaderPageCell.concatenateAtoms(leading + [part])) <= budget
        }
        guard fits(0) else { return nil }
        var lo = 0, hi = breaks.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if fits(mid) { lo = mid } else { hi = mid - 1 }
        }
        let start = atom.text.characters.index(atom.text.startIndex, offsetBy: breaks[lo] + 1)
        let rest = AttributedString(atom.text[start...])
        guard !rest.characters.isEmpty else { return nil }
        return (ParagraphAtom(originalParagraphIndex: atom.originalParagraphIndex, text: head(lo),
                              isContinuation: atom.isContinuation),
                ParagraphAtom(originalParagraphIndex: atom.originalParagraphIndex, text: rest,
                              isContinuation: true))
    }

    static func calculateHeight(
        for attributedString: AttributedString,
        width: CGFloat,
        fontSize: CGFloat,
        fontFamily: ReaderFontFamily,
        lineSpacing: CGFloat,
        kerning: CGFloat,
        boldText: Bool
    ) -> CGFloat {
        // An image slot renders as a fixed-height image cell, not text, so its
        // measured height is that fixed height — text measurement of the
        // placeholder character would badly under-count it.
        if HTMLToAttributed.imageAttachmentURL(in: attributedString) != nil {
            return ReaderInlineImage.slotHeight
        }
        let ns = NSAttributedString(attributedString)
        let mutableNs = NSMutableAttributedString(attributedString: ns)

        mutableNs.enumerateAttribute(.font, in: NSRange(location: 0, length: mutableNs.length), options: []) { value, range, _ in
            let originalFont = value as? UIFont ?? UIFont.systemFont(ofSize: fontSize)
            // `boldText` forces every run bold; bold glyphs are wider, so the
            // measurement must match the rendered `.bold()` or pages overflow.
            let isBold = boldText || originalFont.fontDescriptor.symbolicTraits.contains(.traitBold)
            let isItalic = originalFont.fontDescriptor.symbolicTraits.contains(.traitItalic)
            
            var targetFont = fontFamily.uiFont(size: fontSize)
            var traits = UIFontDescriptor.SymbolicTraits()
            if isBold { traits.insert(.traitBold) }
            if isItalic { traits.insert(.traitItalic) }
            if !traits.isEmpty {
                if let desc = targetFont.fontDescriptor.withSymbolicTraits(traits) {
                    targetFont = UIFont(descriptor: desc, size: fontSize)
                }
            }
            mutableNs.addAttribute(.font, value: targetFont, range: range)
        }
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing
        mutableNs.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSRange(location: 0, length: mutableNs.length))

        // Mirror the rendered `.tracking(kerning)`: wider tracking wraps sooner,
        // so the height estimate has to include it too.
        if kerning != 0 {
            mutableNs.addAttribute(.kern, value: kerning, range: NSRange(location: 0, length: mutableNs.length))
        }

        let constraintSize = CGSize(width: width, height: .greatestFiniteMagnitude)
        let rect = mutableNs.boundingRect(with: constraintSize, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return ceil(rect.height)
    }

    static func estimateChapterHeaderHeight(
        title: String,
        width: CGFloat,
        fontSize: CGFloat,
        fontFamily: ReaderFontFamily
    ) -> CGFloat {
        var height: CGFloat = 42 + 15
        if !title.isEmpty {
            let titleFont = fontFamily.uiFont(size: fontSize + 5)
            let constraintSize = CGSize(width: width, height: .greatestFiniteMagnitude)
            let attrString = NSAttributedString(string: title, attributes: [.font: titleFont])
            let rect = attrString.boundingRect(with: constraintSize, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            height += ceil(rect.height) + 10
        }
        return height
    }

    static func estimateTitleHeaderHeight(
        title: String,
        author: String,
        authorUsername: String,
        summary: AO3WorkSummary?,
        width: CGFloat,
        fontSize: CGFloat,
        fontFamily: ReaderFontFamily
    ) -> CGFloat {
        var height: CGFloat = 0
        
        let titleFont = fontFamily.uiFont(size: fontSize + 14)
        let titleRect = NSAttributedString(string: title, attributes: [.font: titleFont])
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        height += ceil(titleRect.height) + 14
        
        if !author.isEmpty {
            let authorFont = UIFont.systemFont(ofSize: fontSize)
            let authorRect = NSAttributedString(string: "by \(author)", attributes: [.font: authorFont])
                .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            height += ceil(authorRect.height) + 14
        }
        
        height += 80
        
        if let summary, !summary.summary.isEmpty {
            height += 15 + 4
            let plainSummary = summary.summary.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            let summaryFont = fontFamily.uiFont(size: fontSize - 1)
            let summaryRect = NSAttributedString(string: plainSummary, attributes: [.font: summaryFont])
                .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            height += ceil(summaryRect.height) + 14
        }
        
        height += 10
        
        return height
    }

    static func paginateChapter(
        chapterIndex: Int,
        atoms: inout [ParagraphAtom],
        width: CGFloat,
        viewportHeight: CGFloat,
        titleHeaderHeight: CGFloat,
        chapterHeaderHeight: CGFloat,
        isFirstChapter: Bool,
        showChapterHeader: Bool,
        fontSize: CGFloat,
        fontFamily: ReaderFontFamily,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        kerning: CGFloat,
        boldText: Bool,
        drawnHeight: DrawnHeight? = nil
    ) -> [ChapterPage] {
        var pages: [ChapterPage] = []
        
        var startIndex = 0
        var pageIndex = 0

        let measure: (AttributedString) -> CGFloat = { text in
            calculateHeight(for: text, width: width, fontSize: fontSize, fontFamily: fontFamily,
                            lineSpacing: lineSpacing, kerning: kerning, boldText: boldText)
        }
        // Two lines of body text: two line heights plus the gap between them.
        let twoLines = 2 * fontFamily.uiFont(size: fontSize).lineHeight + lineSpacing
        
        if isFirstChapter {
            // Page 0 is a dedicated cover/metadata page with no story text.
            pages.append(ChapterPage(
                id: "c\(chapterIndex)-p0",
                chapterIndex: chapterIndex,
                pageIndex: 0,
                paragraphIndices: 0..<0
            ))
            pageIndex = 1
        }
        
        while startIndex < atoms.count {
            var pageMaxHeight = viewportHeight
            
            // Check if this page should display the chapter header
            let displaysChapterHeader = showChapterHeader && (
                isFirstChapter ? (pageIndex == 1) : (pageIndex == 0)
            )
            
            if displaysChapterHeader {
                pageMaxHeight = max(0, viewportHeight - chapterHeaderHeight)
            }

            // Pack against a slightly smaller budget than the page, so small
            // differences between boundingRect and SwiftUI's Text layout
            // leave headroom instead of running a page's last line under
            // the footer.
            let reserve = min(24, max(8, pageMaxHeight * 0.02))
            var endIndex = startIndex
            var includedAny = false
            if pageMaxHeight > 40, let drawnHeight {
                endIndex = fitPage(&atoms, from: startIndex, pageHeight: pageMaxHeight, reserve: reserve,
                                   paragraphSpacing: paragraphSpacing, twoLines: twoLines,
                                   measure: measure, drawnHeight: drawnHeight)
                includedAny = true
            } else if pageMaxHeight > 40 {
                endIndex = packPage(&atoms, from: startIndex, budget: pageMaxHeight - reserve,
                                    paragraphSpacing: paragraphSpacing, twoLines: twoLines, measure: measure)
                includedAny = true
            }
            
            let range: Range<Int>
            if includedAny {
                range = startIndex..<(endIndex + 1)
                startIndex = endIndex + 1
            } else {
                range = startIndex..<startIndex
            }
            
            pages.append(ChapterPage(
                id: "c\(chapterIndex)-p\(pageIndex)",
                chapterIndex: chapterIndex,
                pageIndex: pageIndex,
                paragraphIndices: range
            ))
            pageIndex += 1
        }
        
        if pages.isEmpty {
            pages.append(ChapterPage(
                id: "c\(chapterIndex)-p0",
                chapterIndex: chapterIndex,
                pageIndex: 0,
                paragraphIndices: 0..<0
            ))
        }
        
        return pages
    }

    /// A page's text as SwiftUI draws it: the height of atoms[range] laid out
    /// in ReaderPageCell's own view.
    typealias DrawnHeight = @MainActor (_ atoms: [ParagraphAtom], _ range: Range<Int>) -> CGFloat

    /// Whether packed pages are checked against SwiftUI's layout. On iOS,
    /// boundingRect measures text exactly as SwiftUI draws it; under the Mac's
    /// text metrics it doesn't: New York lines draw a point taller at 13 and
    /// 18 pt, and 13 pt text fits more words on a line. Measured on CI, those
    /// ran default-font pages up to 14 pt past their area (the last line cut
    /// off) and left small-text pages ~50 pt short. A build-time check, not
    /// the idiom: the Mac app doesn't report the Mac idiom everywhere.
    static var measuresDrawnPages: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }

    /// Measures pages with ReaderPageCell's view, reusing one hosting controller.
    static func drawnHeightMeasure(width: CGFloat, fontSize: CGFloat, fontFamily: ReaderFontFamily,
                                   lineSpacing: CGFloat, paragraphSpacing: CGFloat, kerning: CGFloat,
                                   boldText: Bool) -> DrawnHeight {
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        let chapter = AO3ChapterPayload(index: 0, title: "", bodyHTML: "")
        let font = fontFamily.font(size: fontSize)
        return { atoms, range in
            let cell = ReaderPageCell(
                page: ChapterPage(id: "measure", chapterIndex: 0, pageIndex: 0, paragraphIndices: range),
                chapter: chapter, atoms: atoms, showTitleHeader: false, showChapterHeader: false,
                titleHeaderView: nil, chapterHeaderView: AnyView(EmptyView()),
                font: font, lineSpacing: lineSpacing, paragraphSpacing: paragraphSpacing,
                kerning: kerning, boldText: boldText, foreground: .primary, highlightParagraph: nil)
            host.rootView = AnyView(cell.pageContent
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true))
            return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
        }
    }

    /// Packs a page with boundingRect, then checks it against SwiftUI's
    /// layout and packs it again with a corrected budget: less when it runs
    /// past the page as drawn, more when it leaves more room than a
    /// paragraph that can't start on two lines explains. Keeps the fullest
    /// packing that fits; a few tries, each one boundingRect pass plus one
    /// SwiftUI measurement. Returns the page's last atom.
    private static func fitPage(_ atoms: inout [ParagraphAtom], from start: Int, pageHeight: CGFloat, reserve: CGFloat,
                                paragraphSpacing: CGFloat, twoLines: CGFloat,
                                measure: (AttributedString) -> CGFloat, drawnHeight: DrawnHeight) -> Int {
        let unpacked = atoms
        var budget = pageHeight - reserve
        var fullest: (atoms: [ParagraphAtom], end: Int, drawn: CGFloat)?
        var latest: (atoms: [ParagraphAtom], end: Int) = (unpacked, start)
        for _ in 0..<4 {
            var trial = unpacked
            let end = packPage(&trial, from: start, budget: budget, paragraphSpacing: paragraphSpacing,
                               twoLines: twoLines, measure: measure)
            latest = (trial, end)
            let drawn = drawnHeight(trial, start..<(end + 1))
            if drawn > pageHeight {
                budget -= drawn - pageHeight + 1
                continue
            }
            if drawn > (fullest?.drawn ?? -1) { fullest = (trial, end, drawn) }
            let spare = pageHeight - reserve - drawn
            guard end + 1 < trial.count, spare > paragraphSpacing + twoLines else { break }
            budget += spare
        }
        // Nothing fit (a page of one unbreakable sentence): take the last try.
        let chosen = fullest.map { (atoms: $0.atoms, end: $0.end) } ?? latest
        atoms = chosen.atoms
        return chosen.end
    }

    /// Fills a page from `startIndex` with as much as `budget` holds, by
    /// boundingRect. May split a sentence at a line end (the rest becomes a
    /// new atom right after it). Returns the page's last atom.
    private static func packPage(_ atoms: inout [ParagraphAtom], from startIndex: Int, budget packingBudget: CGFloat,
                                 paragraphSpacing: CGFloat, twoLines: CGFloat,
                                 measure: (AttributedString) -> CGFloat) -> Int {
        var endIndex = startIndex
        var currentBlockParaIndex = atoms[startIndex].originalParagraphIndex
        var currentBlockAtoms: [ParagraphAtom] = [atoms[startIndex]]
        var currentBlockHeight = measure(ReaderPageCell.concatenateAtoms(currentBlockAtoms))
        // A single sentence taller than the page: break it at a line
        // end rather than letting the page overflow.
        if currentBlockHeight > packingBudget,
           let (head, tail) = splitAtomToFit(atoms[startIndex], after: [], budget: packingBudget, measure: measure) {
            atoms[startIndex] = head
            atoms.insert(tail, at: startIndex + 1)
            currentBlockAtoms = [head]
            currentBlockHeight = measure(head.text)
        }

        var currentHeight = currentBlockHeight
        var completedBlocksHeight: CGFloat = 0

        while endIndex + 1 < atoms.count {
            let nextAtom = atoms[endIndex + 1]

            if nextAtom.originalParagraphIndex == currentBlockParaIndex {
                let proposedBlockAtoms = currentBlockAtoms + [nextAtom]
                let proposedBlockHeight = measure(ReaderPageCell.concatenateAtoms(proposedBlockAtoms))
                let potentialHeight = completedBlocksHeight + proposedBlockHeight
                if potentialHeight <= packingBudget {
                    endIndex += 1
                    currentBlockAtoms = proposedBlockAtoms
                    currentBlockHeight = proposedBlockHeight
                    currentHeight = potentialHeight
                } else {
                    // Fill the page to its last line, like a printed
                    // book: the sentence continues on the next page.
                    if let (head, tail) = splitAtomToFit(nextAtom, after: currentBlockAtoms,
                                                         budget: packingBudget - completedBlocksHeight,
                                                         measure: measure) {
                        atoms[endIndex + 1] = head
                        atoms.insert(tail, at: endIndex + 2)
                        endIndex += 1
                    }
                    break
                }
            } else {
                let proposedBlockAtoms = [nextAtom]
                let proposedBlockHeight = measure(ReaderPageCell.concatenateAtoms(proposedBlockAtoms))
                let potentialHeight = currentHeight + paragraphSpacing + proposedBlockHeight
                if potentialHeight <= packingBudget {
                    endIndex += 1
                    completedBlocksHeight += currentBlockHeight + paragraphSpacing
                    currentBlockParaIndex = nextAtom.originalParagraphIndex
                    currentBlockAtoms = proposedBlockAtoms
                    currentBlockHeight = proposedBlockHeight
                    currentHeight = potentialHeight
                } else {
                    // Start the paragraph here only if at least two of
                    // its lines fit (no lone opening line at the foot
                    // of a page); otherwise it opens the next page.
                    let room = packingBudget - currentHeight - paragraphSpacing
                    if room >= twoLines,
                       let (head, tail) = splitAtomToFit(nextAtom, after: [], budget: room, measure: measure) {
                        atoms[endIndex + 1] = head
                        atoms.insert(tail, at: endIndex + 2)
                        endIndex += 1
                    }
                    break
                }
            }
        }
        return endIndex
    }
}

struct ReaderPageCell: View {
    let page: ChapterPage
    let chapter: AO3ChapterPayload
    let atoms: [ParagraphAtom]
    let showTitleHeader: Bool
    let showChapterHeader: Bool
    let titleHeaderView: AnyView?
    let chapterHeaderView: AnyView
    
    let font: Font
    let lineSpacing: CGFloat
    let paragraphSpacing: CGFloat
    let kerning: CGFloat
    let boldText: Bool
    let foreground: Color
    let highlightParagraph: Int?

    private var renderedBlocks: [RenderedBlock] {
        var blocks: [RenderedBlock] = []
        let indices = Array(page.paragraphIndices)
        guard !indices.isEmpty else { return [] }
        
        var currentOriginalIndex = atoms[indices[0]].originalParagraphIndex
        var currentAtoms: [ParagraphAtom] = [atoms[indices[0]]]
        
        for index in indices.dropFirst() {
            if index < atoms.count {
                let atom = atoms[index]
                if atom.originalParagraphIndex == currentOriginalIndex {
                    currentAtoms.append(atom)
                } else {
                    blocks.append(RenderedBlock(
                        id: currentOriginalIndex,
                        originalParagraphIndex: currentOriginalIndex,
                        text: ReaderPageCell.concatenateAtoms(currentAtoms)
                    ))
                    currentOriginalIndex = atom.originalParagraphIndex
                    currentAtoms = [atom]
                }
            }
        }
        
        if !currentAtoms.isEmpty {
            blocks.append(RenderedBlock(
                id: currentOriginalIndex,
                originalParagraphIndex: currentOriginalIndex,
                text: ReaderPageCell.concatenateAtoms(currentAtoms)
            ))
        }
        
        return blocks
    }
    
    struct RenderedBlock: Identifiable {
        let id: Int
        let originalParagraphIndex: Int
        let text: AttributedString
    }
    
    static func concatenateAtoms(_ atoms: [ParagraphAtom]) -> AttributedString {
        var result = AttributedString()
        for (i, atom) in atoms.enumerated() {
            if i > 0 {
                let prevString = String(result.characters)
                let nextString = String(atom.text.characters)
                let needsSpace = !prevString.isEmpty && 
                                 !nextString.isEmpty && 
                                 !prevString.hasSuffix(" ") && 
                                 !prevString.hasSuffix("\n") && 
                                 !nextString.hasPrefix(" ") && 
                                 !nextString.hasPrefix("\n")
                if needsSpace {
                    result.append(AttributedString(" "))
                }
            }
            result.append(atom.text)
        }
        return result
    }
    
    var body: some View {
        // Always the ScrollView, even with the UI minimized: a bare VStack in
        // the fixed-height TabView page lets SwiftUI compress the paragraph
        // Texts whenever the paginator's boundingRect estimate under-measures
        // the rendered layout (worst on Mac Catalyst), which truncated
        // mid-page paragraphs to "…". basedOnSize keeps an exact-fit page
        // inert — it only scrolls when the page genuinely overflows.
        ScrollView(.vertical, showsIndicators: false) {
            pageContent
        }
        .scrollBounceBehavior(.basedOnSize)
    }
    
    /// The page as laid out inside its scroll view. Internal so
    /// ReaderPaginationTests can check SwiftUI draws pages within the height
    /// the paginator measured them for.
    var pageContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showTitleHeader, let titleHeaderView {
                titleHeaderView
                    .padding(.bottom, Spacing.lg)
            }
            if showChapterHeader {
                chapterHeaderView
                    .padding(.bottom, Spacing.sm)
            }
            
            VStack(alignment: .leading, spacing: paragraphSpacing) {
                ForEach(renderedBlocks) { block in
                    if let imageURL = HTMLToAttributed.imageAttachmentURL(in: block.text) {
                        // Renders at ReaderInlineImage.slotHeight — the same
                        // height the paginator budgeted for this block.
                        ReaderInlineImage(url: imageURL)
                    } else {
                        Text(block.text)
                            .font(font)
                            .tracking(kerning)
                            .bold(boldText)
                            .lineSpacing(lineSpacing)
                            .foregroundStyle(foreground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // Story text must never ellipsize: take the full
                            // ideal height even if a parent proposes less.
                            .fixedSize(horizontal: false, vertical: true)
                            .background(
                                highlightParagraph == block.originalParagraphIndex ? Color.accentColor.opacity(0.15) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct ReaderKeyPressModifier: ViewModifier {
    let mode: ReadingMode
    @FocusState.Binding var isReaderFocused: Bool
    let turnPageByPage: (Bool) -> Void
    let turnPage: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($isReaderFocused)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                if mode == .pageByPage {
                    if press.key == .leftArrow {
                        turnPageByPage(false)
                        return .handled
                    } else if press.key == .rightArrow {
                        turnPageByPage(true)
                        return .handled
                    }
                } else if mode == .paginated {
                    if press.key == .leftArrow {
                        turnPage(false)
                        return .handled
                    } else if press.key == .rightArrow {
                        turnPage(true)
                        return .handled
                    }
                }
                return .ignored
            }
            .onAppear {
                isReaderFocused = true
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    isReaderFocused = true
                }
            )
    }
}

/// Mutable holder for the reader's trailing scroll-anchor sample.
@MainActor
final class TrailingAnchorSample {
    var offsets: [String: CGFloat] = [:]
    /// The container width the samples belong to; updates at any other width
    /// are a resize reflowing the text, not the reader scrolling.
    var width: CGFloat = 0
    var task: Task<Void, Never>?
}
