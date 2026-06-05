import SwiftUI

struct ReaderView: View {
    let title: String
    let author: String
    let authorUsername: String
    let chapters: [AO3ChapterPayload]
    let summary: AO3WorkSummary?

    @AppStorage("reader.theme") private var themeRaw: String = ReaderTheme.system.rawValue
    @AppStorage("reader.fontFamily") private var fontFamilyRaw: String = ReaderFontFamily.newYork.rawValue
    @AppStorage("reader.width") private var widthRaw: String = ReaderWidth.medium.rawValue
    @AppStorage("reader.mode") private var modeRaw: String = ReadingMode.continuous.rawValue
    @AppStorage("reader.fontSizePt") private var fontSizePt: Double = ReaderMetrics.defaultFontSize
    @AppStorage("reader.lineSpacingPt") private var lineSpacingPt: Double = ReaderMetrics.defaultLineSpacing
    @AppStorage("reader.paragraphSpacingPt") private var paragraphSpacingPt: Double = ReaderMetrics.defaultParagraphSpacing
    @AppStorage("reader.pageTurnHaptics") private var pageTurnHaptics: Bool = false
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.modelContext) private var modelContext
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
    @State private var listeningChapter: Int?
    private let scrollSpace = "readerScroll"

    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .system }
    private var fontFamily: ReaderFontFamily { ReaderFontFamily(rawValue: fontFamilyRaw) ?? .newYork }
    private var width: ReaderWidth { ReaderWidth(rawValue: widthRaw) ?? .medium }
    private var mode: ReadingMode { ReadingMode(rawValue: modeRaw) ?? .continuous }
    private var fontSize: CGFloat { CGFloat(fontSizePt) }
    private var lineSpacing: CGFloat { CGFloat(lineSpacingPt) }
    private var paragraphSpacing: CGFloat { CGFloat(paragraphSpacingPt) }

    init(title: String, author: String, chapters: [AO3ChapterPayload], summary: AO3WorkSummary? = nil) {
        self.title = title
        self.author = author
        self.authorUsername = summary?.authorUsername ?? ""
        self.chapters = chapters
        self.summary = summary
    }

    init(work: Work) {
        self.title = work.title
        self.author = work.authorName
        self.authorUsername = work.authorUsername
        self.chapters = work.chapters
            .sorted(by: { $0.index < $1.index })
            .map { AO3ChapterPayload(index: $0.index, title: $0.title, bodyHTML: $0.bodyHTML) }
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

    init(payload: AO3WorkPayload) {
        self.title = payload.summary.title
        self.author = payload.summary.author
        self.authorUsername = payload.summary.authorUsername
        self.chapters = payload.chapters
        self.summary = payload.summary
    }

    var body: some View {
        let scheme = theme.preferredColorScheme ?? systemColorScheme
        let fg = theme.foreground(for: scheme)
        let bg = theme.background(for: scheme)

        Group {
            switch mode {
            case .continuous: continuousBody(fg: fg, bg: bg)
            case .paginated:  paginatedBody(fg: fg, bg: bg)
            }
        }
        // Floating narration controls when "Listen" is active.
        .safeAreaInset(edge: .bottom) {
            if speech.isActive { narrationBar(fg: fg, bg: bg) }
        }
        // Paint the nav bar with the reader's own background so it blends into
        // the page instead of showing the default translucent gray material.
        .toolbarColorScheme(theme.preferredColorScheme, for: .navigationBar)
        .toolbarBackground(bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            if chapters.count > 1 {
                ToolbarItem(placement: .topBarTrailing) { chaptersMenu }
            }
            ToolbarItem(placement: .topBarTrailing) { typographyMenu }
        }
        // When a chapter finishes narrating, roll on to the next (or stop).
        .onChange(of: speech.finishedTick) { _, _ in advanceNarration() }
        // Don't leave audio playing after the reader is dismissed.
        .onDisappear { speech.stop() }
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
        // Speech paragraphs are index-aligned with the rendered ones, so for the
        // chapter you're already reading we can pick up from your position;
        // otherwise start that chapter from the top.
        let chapterIndex = (mode == .paginated ? selectedChapterIndex : visibleChapterIndex)
        let from = (currentAnchor?.chapter == chapterIndex) ? (currentAnchor?.paragraph ?? 0) : 0
        narrate(chapter: chapterIndex, from: from)
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

            VStack(alignment: .leading, spacing: 1) {
                Text(speech.chapterLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("¶ \(speech.spokenPosition) / \(speech.spokenCount)")
                    .font(.caption2)
                    .foregroundStyle(fg.opacity(0.6))
            }
            Spacer()
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

    // MARK: - Continuous

    private func continuousBody(fg: Color, bg: Color) -> some View {
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
                .frame(maxWidth: width.maxColumnWidth, alignment: .leading)
                .padding(.horizontal, width.horizontalPadding)
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
            .safeAreaInset(edge: .top, spacing: 0) {
                if chapters.count > 1 {
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
        if let currentAnchor { saveProgress(currentAnchor, force: true) }
    }

    private func saveProgress(_ anchor: ReadingAnchor, force: Bool = false) {
        guard let id = summary?.id else { return }
        let now = Date()
        if !force && now.timeIntervalSince(lastSaveAt) < 1.5 { return }
        lastSaveAt = now
        ReadingProgressStore.save(ao3Id: id, anchor: anchor, title: title, author: author, in: modelContext)
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
            TabView(selection: $selectedChapterIndex) {
                ForEach(chapters, id: \.index) { chapter in
                    paginatedPage(chapter, fg: fg)
                        .tag(chapter.index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: chapters.count > 1 ? .automatic : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .background(bg)
            .foregroundStyle(fg)
            // Kindle-style tap-to-turn: tapping the left third goes to the
            // previous chapter, the right third to the next; the middle third is
            // a dead zone so taps on mid-page links/text don't flip the page. A
            // *simultaneous* spatial tap leaves the TabView's swipe paging and
            // each page's vertical scroll fully intact (a plain gesture would
            // swallow them). Disabled for single-chapter works (nothing to turn).
            .simultaneousGesture(
                chapters.count > 1
                    ? SpatialTapGesture().onEnded { value in
                        let x = value.location.x
                        if x < geo.size.width / 3 {
                            turnPage(forward: false)
                        } else if x > geo.size.width * 2 / 3 {
                            turnPage(forward: true)
                        }
                    }
                    : nil
            )
            .task {
                isRestoring = true
                if let anchor = loadAnchorIfNeeded() {
                    selectedChapterIndex = anchor.chapter
                    if anchor.paragraph > 0 { pendingParagraphRestore = anchor }
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
        withAnimation(.easeInOut(duration: 0.25)) {
            selectedChapterIndex = target
        }
    }

    private func paginatedPage(_ chapter: AO3ChapterPayload, fg: Color) -> some View {
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
                .frame(maxWidth: width.maxColumnWidth, alignment: .leading)
                .padding(.horizontal, width.horizontalPadding)
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

            presetMenu("Text size", value: $fontSizePt, presets: ReaderMetrics.fontSizePresets,
                       icon: "textformat.size")
            presetMenu("Line spacing", value: $lineSpacingPt, presets: ReaderMetrics.lineSpacingPresets,
                       icon: "arrow.up.and.down.text.horizontal")
            presetMenu("Paragraph spacing", value: $paragraphSpacingPt, presets: ReaderMetrics.paragraphSpacingPresets,
                       icon: "text.justify.left")

            Menu {
                Picker("Margins", selection: $widthRaw) {
                    ForEach(ReaderWidth.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
            } label: {
                Label("Margins · \(width.displayName)", systemImage: "rectangle.compress.vertical")
            }
        } label: {
            Image(systemName: "textformat")
        }
    }

    /// Quick-pick submenu of named presets that set a numeric reader metric.
    /// (The continuous slider for the same value lives in Settings → Reader.)
    private func presetMenu(_ title: String, value: Binding<Double>,
                            presets: [(name: String, value: Double)], icon: String) -> some View {
        let current = presets.first { abs($0.value - value.wrappedValue) < 0.5 }?.name
        return Menu {
            ForEach(presets, id: \.name) { preset in
                Button {
                    value.wrappedValue = preset.value
                } label: {
                    if abs(preset.value - value.wrappedValue) < 0.5 {
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
