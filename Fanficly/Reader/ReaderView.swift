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
    // Keep the display awake while reading (like a video player), so the screen
    // doesn't dim/lock mid-page when you go a while without touching it.
    @AppStorage("reader.keepScreenAwake") private var keepScreenAwake: Bool = true
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
    // Text-to-speech ("Listen") narration of the current chapter.
    @State private var speech = SpeechController()
    @State private var isUIMinimized: Bool = false
    @State private var listeningChapter: Int?
    // Page-by-page mode
    @State private var paginatedPages: [ChapterPage] = []
    @State private var selectedPageId: String = ""
    @State private var parsedAtoms: [Int: [ParagraphAtom]] = [:]
    @State private var stableWidth: CGFloat = 0
    @State private var stableHeight: CGFloat = 0
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
        let json = ReaderProfile.saveProfiles(list)
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
    /// the app returns to `.active`, flush on disappear and when it leaves.
    private struct ReaderLifecycleModifier: ViewModifier {
        let keepScreenAwake: Bool
        let scenePhase: ScenePhase
        let applyKeepScreenAwake: (Bool) -> Void
        let startTimer: () -> Void
        let flushTimer: () -> Void
        let stopSpeech: () -> Void

        func body(content: Content) -> some View {
            content
                .onAppear {
                    applyKeepScreenAwake(keepScreenAwake)
                    startTimer()
                }
                .onChange(of: keepScreenAwake) { _, on in applyKeepScreenAwake(on) }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active { startTimer() } else { flushTimer() }
                }
                .onDisappear {
                    stopSpeech()
                    applyKeepScreenAwake(false)
                    flushTimer()
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
        // The reader has no text input, so it must never reserve room for the
        // keyboard. Without this, returning from the background can restore
        // focus to the page (it's `.focusable()` for hardware arrow-key turns,
        // see ReaderKeyPressModifier) and leave iOS holding a phantom keyboard
        // safe-area inset — collapsing the page and leaving a large blank band
        // (~keyboard height) at the bottom. Ignoring the keyboard safe area
        // keeps the page full-height; the home-indicator inset and the bottom
        // narration/footer bars are unaffected.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // Floating narration controls when "Listen" is active.
        .safeAreaInset(edge: .bottom) {
            if speech.isActive {
                narrationBar(fg: fg, bg: bg)
            } else if mode == .pageByPage && !isUIMinimized {
                pageFooterBar(fg: fg, bg: bg)
            }
        }
        // Paint the nav bar with the reader's own background so it blends into
        // the page instead of showing the default translucent gray material.
        .toolbarColorScheme(theme.preferredColorScheme, for: .navigationBar)
        .toolbarBackground(bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
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
                    Label("Maximize", systemImage: "arrow.up.left.and.arrow.down.right")
                }
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
            stopSpeech: { speech.stop() }
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
        speech.play(paragraphs: HTMLToAttributed.speechParagraphs(chapter.bodyHTML),
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
            Button { speech.togglePlayPause() } label: {
                Image(systemName: speech.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            Button { speech.skipForward() } label: { Image(systemName: "forward.fill") }

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
            
            Button {
                speech.stop()
                listeningChapter = nil
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(fg.opacity(0.45))
            }
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
                    .frame(maxWidth: geo.size.width * CGFloat(widthPercent / 100.0), alignment: .leading)
                    .padding(.horizontal, geo.size.width * CGFloat(1.0 - widthPercent / 100.0) / 2.0)
                    .padding(.vertical, Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .coordinateSpace(name: scrollSpace)
                .onPreferenceChange(ChapterOffsetKey.self) { offsets in
                    if let current = ChapterTracking.currentChapter(offsets: offsets) {
                        visibleChapterIndex = current
                    }
                }
                .onPreferenceChange(ScrollAnchorKey.self) { offsets in
                    // Sample at most ~3x/sec so progress tracking never competes
                    // with the scroll for main-thread time.
                    let now = Date()
                    guard now.timeIntervalSince(lastAnchorSampleAt) > 0.35 else { return }
                    lastAnchorSampleAt = now
                    if !isRestoring, let anchor = ChapterTracking.topmostAnchor(offsets) {
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
        ReadingStatsStore.record(
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

    private func readingProgressFraction(for anchor: ReadingAnchor) -> Double {
        let orderedChapters = chapters.sorted { $0.index < $1.index }
        guard !orderedChapters.isEmpty,
              let chapterOffset = orderedChapters.firstIndex(where: { $0.index == anchor.chapter }) else {
            return 0
        }

        let chapter = orderedChapters[chapterOffset]
        let paragraphCount = max(HTMLToAttributed.convertParagraphs(chapter.bodyHTML).count, 1)
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
            .task {
                isRestoring = true
                if let anchor = loadAnchorIfNeeded() {
                    selectedChapterIndex = anchor.chapter
                    if anchor.paragraph > 0 { pendingParagraphRestore = anchor }
                }
                let currentChapters = chapters
                Task.detached(priority: .background) {
                    for chapter in currentChapters {
                        _ = HTMLToAttributed.convertParagraphs(chapter.bodyHTML)
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
                    .frame(maxWidth: geo.size.width * CGFloat(widthPercent / 100.0), alignment: .leading)
                    .padding(.horizontal, geo.size.width * CGFloat(1.0 - widthPercent / 100.0) / 2.0)
                    .padding(.top, Spacing.lg)
                    .padding(.bottom, chapters.count > 1 ? 56 : Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                // Each page has its own scroll space; the handler below only sees
                // this page's paragraph anchors.
                .coordinateSpace(name: scrollSpace)
                .onPreferenceChange(ScrollAnchorKey.self) { offsets in
                    guard chapter.index == selectedChapterIndex, !isRestoring else { return }
                    let now = Date()
                    guard now.timeIntervalSince(lastAnchorSampleAt) > 0.35 else { return }
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
            let trigger = PaginationTrigger(
                chapter: selectedChapterIndex,
                fontSize: fontSizePt / zoomScale,
                fontFamily: fontFamilyRaw,
                widthPercent: widthPercent,
                lineSpacing: lineSpacingPt / zoomScale,
                paragraphSpacing: paragraphSpacingPt / zoomScale,
                kerning: kerningPt / zoomScale,
                boldText: boldText,
                size: CGSize(
                    width: geo.size.width,
                    height: stableHeight > 0 ? stableHeight : immersiveReadingHeight(fallback: geo.size.height)
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
                }
            }
            .background(bg)
            .foregroundStyle(fg)
            
            content
                .task(id: trigger) {
                    await handlePaginationTrigger(trigger)
                }
                .onChange(of: geo.size) { _, newSize in
                    // Keep the page count stable when the reader chrome (nav bar
                    // + page footer) toggles. Hiding/showing that chrome shrinks
                    // and grows `geo.size.height`, but the *reading* viewport —
                    // the area a page fills once chrome is gone — is fixed by the
                    // device, so we pin pagination to that immersive height and
                    // ignore chrome-driven height changes. Only a genuine layout
                    // change (rotation / split-view resize, which also moves the
                    // width) re-derives it.
                    let widthChanged = abs(stableWidth - newSize.width) > 1
                    guard widthChanged || stableWidth == 0 else { return }
                    stableWidth = newSize.width
                    stableHeight = immersiveReadingHeight(fallback: newSize.height)
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

    @ViewBuilder
    private func makePageCell(page: ChapterPage, fg: Color, containerWidth: CGFloat) -> some View {
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
                highlightParagraph: highlightedParagraph(for: page.chapterIndex),
                isScrollable: !isUIMinimized
            )
            .frame(maxWidth: containerWidth * CGFloat(widthPercent / 100.0), alignment: .leading)
            .padding(.horizontal, containerWidth * CGFloat(1.0 - widthPercent / 100.0) / 2.0)
            .padding(.top, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .tag(page.id)
        } else {
            ProgressView()
                .tag(page.id)
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
        await MainActor.run {
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
        guard let page = pagesList.first(where: { $0.id == pageId }) else { return }
        
        if page.chapterIndex != selectedChapterIndex {
            selectedChapterIndex = page.chapterIndex
            visibleChapterIndex = page.chapterIndex
        }
        
        if !isRestoring {
            if let atoms = parsedAtoms[page.chapterIndex], !page.paragraphIndices.isEmpty {
                let firstParaAtomIndex = page.paragraphIndices.lowerBound
                if firstParaAtomIndex < atoms.count {
                    let originalParaIndex = atoms[firstParaAtomIndex].originalParagraphIndex
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
        if let page = pagesList.first(where: { $0.chapterIndex == targetChapter }) {
            if selectedPageId != page.id {
                updatePageSelection(page.id)
            }
        }
    }

    private func turnPageByPage(forward: Bool) {
        guard let currentIndex = paginatedPages.firstIndex(where: { $0.id == selectedPageId }) else { return }
        
        let targetIndex = forward ? currentIndex + 1 : currentIndex - 1
        guard targetIndex >= 0 && targetIndex < paginatedPages.count else { return }
        
        let targetPage = paginatedPages[targetIndex]
        
        if pageTurnHaptics {
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
        }
        
        updatePageSelection(targetPage.id)
    }

    private func restoreOrValidatePageSelection() {
        let pagesList: [ChapterPage] = paginatedPages
        guard !pagesList.isEmpty else { return }
        
        if let anchor = currentAnchor {
            let targetChapter: Int = anchor.chapter
            let targetParagraph: Int = anchor.paragraph
            if let matchingPage = pagesList.first(where: { (page: ChapterPage) -> Bool in
                guard page.chapterIndex == targetChapter else { return false }
                guard let atoms = parsedAtoms[targetChapter] else { return false }
                
                for idx in page.paragraphIndices {
                    if idx < atoms.count && atoms[idx].originalParagraphIndex == targetParagraph {
                        return true
                    }
                }
                return page.paragraphIndices.isEmpty && targetParagraph == 0
            }) {
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
            let currentPageNum = currentPage.pageIndex + 1
            let totalPagesInChapter = chapterPages.count
            
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
                Text("Page \(currentPageNum) of \(totalPagesInChapter)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(fg.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(bg)
            .overlay(alignment: .top) {
                Rectangle().fill(fg.opacity(0.1)).frame(height: 0.5)
            }
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
        let w = trigger.size.width * CGFloat(trigger.widthPercent / 100.0)
        let h = trigger.size.height - 40 // margins
        
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
        
        for chIndex in targetChapters.sorted() {
            guard let chapter = chapters.first(where: { $0.index == chIndex }) else { continue }
            
            let paragraphs = HTMLToAttributed.convertParagraphs(chapter.bodyHTML)
            
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
            allAtoms[chIndex] = atoms
            
            let titleHeaderHeight = estimateTitleHeaderHeight(
                title: title,
                author: author,
                authorUsername: authorUsername,
                summary: summary,
                width: w,
                fontSize: CGFloat(trigger.fontSize),
                fontFamily: fontFamily
            )
            
            let chapterHeaderHeight = estimateChapterHeaderHeight(
                title: chapter.title,
                width: w,
                fontSize: CGFloat(trigger.fontSize),
                fontFamily: fontFamily
            )
            
            let isFirstChapter = chIndex == chapters.first?.index
            let showChapterHeader = chapters.count > 1
            
            let chPages = paginateChapter(
                chapterIndex: chIndex,
                atoms: atoms,
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
                boldText: trigger.boldText
            )

            allPages.append(contentsOf: chPages)
        }
        
        return PaginationResult(pages: allPages, atoms: allAtoms)
    }

    private func calculateHeight(
        for attributedString: AttributedString,
        width: CGFloat,
        fontSize: CGFloat,
        fontFamily: ReaderFontFamily,
        lineSpacing: CGFloat,
        kerning: CGFloat,
        boldText: Bool
    ) -> CGFloat {
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

    private func estimateChapterHeaderHeight(
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

    private func estimateTitleHeaderHeight(
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

    private func paginateChapter(
        chapterIndex: Int,
        atoms: [ParagraphAtom],
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
        boldText: Bool
    ) -> [ChapterPage] {
        var pages: [ChapterPage] = []
        
        var startIndex = 0
        var pageIndex = 0
        
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
            var endIndex = startIndex
            
            var pageMaxHeight = viewportHeight
            
            // Check if this page should display the chapter header
            let displaysChapterHeader = showChapterHeader && (
                isFirstChapter ? (pageIndex == 1) : (pageIndex == 0)
            )
            
            if displaysChapterHeader {
                pageMaxHeight = max(0, viewportHeight - chapterHeaderHeight)
            }
            
            var currentHeight: CGFloat = 0
            var includedAny = false
            
            if pageMaxHeight > 40 {
                var currentBlockParaIndex = atoms[startIndex].originalParagraphIndex
                var currentBlockAtoms: [ParagraphAtom] = [atoms[startIndex]]
                var currentBlockHeight = calculateHeight(
                    for: ReaderPageCell.concatenateAtoms(currentBlockAtoms),
                    width: width,
                    fontSize: fontSize,
                    fontFamily: fontFamily,
                    lineSpacing: lineSpacing,
                    kerning: kerning,
                    boldText: boldText
                )
                
                currentHeight = currentBlockHeight
                includedAny = true
                
                var completedBlocksHeight: CGFloat = 0
                
                while endIndex + 1 < atoms.count {
                    let nextAtom = atoms[endIndex + 1]
                    
                    if nextAtom.originalParagraphIndex == currentBlockParaIndex {
                        let proposedBlockAtoms = currentBlockAtoms + [nextAtom]
                        let proposedBlockHeight = calculateHeight(
                            for: ReaderPageCell.concatenateAtoms(proposedBlockAtoms),
                            width: width,
                            fontSize: fontSize,
                            fontFamily: fontFamily,
                            lineSpacing: lineSpacing,
                            kerning: kerning,
                            boldText: boldText
                        )
                        
                        let potentialHeight = completedBlocksHeight + proposedBlockHeight
                        if potentialHeight <= pageMaxHeight {
                            endIndex += 1
                            currentBlockAtoms = proposedBlockAtoms
                            currentBlockHeight = proposedBlockHeight
                            currentHeight = potentialHeight
                        } else {
                            break
                        }
                    } else {
                        let proposedBlockAtoms = [nextAtom]
                        let proposedBlockHeight = calculateHeight(
                            for: ReaderPageCell.concatenateAtoms(proposedBlockAtoms),
                            width: width,
                            fontSize: fontSize,
                            fontFamily: fontFamily,
                            lineSpacing: lineSpacing,
                            kerning: kerning,
                            boldText: boldText
                        )
                        
                        let potentialHeight = currentHeight + paragraphSpacing + proposedBlockHeight
                        if potentialHeight <= pageMaxHeight {
                            endIndex += 1
                            completedBlocksHeight += currentBlockHeight + paragraphSpacing
                            currentBlockParaIndex = nextAtom.originalParagraphIndex
                            currentBlockAtoms = proposedBlockAtoms
                            currentBlockHeight = proposedBlockHeight
                            currentHeight = potentialHeight
                        } else {
                            break
                        }
                    }
                }
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
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
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
            highlightParagraph: highlightedParagraph(for: chapter.index)
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

            presetMenu("Margins", value: $widthPercent, presets: [
                (name: "Narrow (50%)", value: 50.0),
                (name: "Medium (70%)", value: 70.0),
                (name: "Wide (85%)", value: 85.0),
                (name: "Full (100%)", value: 100.0)
            ], icon: "arrow.left.and.right.square")
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
    let size: CGSize
}

struct PaginationResult {
    let pages: [ChapterPage]
    let atoms: [Int: [ParagraphAtom]]
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
    let isScrollable: Bool
    
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
        Group {
            if showTitleHeader || isScrollable {
                ScrollView(.vertical, showsIndicators: false) {
                    content
                }
            } else {
                content
            }
        }
    }
    
    private var content: some View {
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
                    Text(block.text)
                        .font(font)
                        .tracking(kerning)
                        .bold(boldText)
                        .lineSpacing(lineSpacing)
                        .foregroundStyle(foreground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            highlightParagraph == block.originalParagraphIndex ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
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
