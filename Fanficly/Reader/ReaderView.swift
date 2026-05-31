import SwiftUI

struct ReaderView: View {
    let title: String
    let author: String
    let chapters: [AO3ChapterPayload]
    let summary: AO3WorkSummary?
    /// Reports chrome show/hide as the user scrolls, so the parent — which owns
    /// the nav-bar items — can hide the whole bar. Applying `.toolbar(.hidden)`
    /// from inside the reader is unreliable when items are declared one level up.
    var onChromeChange: ((Bool) -> Void)? = nil

    @AppStorage("reader.theme") private var themeRaw: String = ReaderTheme.system.rawValue
    @AppStorage("reader.fontFamily") private var fontFamilyRaw: String = ReaderFontFamily.newYork.rawValue
    @AppStorage("reader.width") private var widthRaw: String = ReaderWidth.medium.rawValue
    @AppStorage("reader.mode") private var modeRaw: String = ReadingMode.continuous.rawValue
    @AppStorage("reader.fontSizePt") private var fontSizePt: Double = ReaderMetrics.defaultFontSize
    @AppStorage("reader.lineSpacingPt") private var lineSpacingPt: Double = ReaderMetrics.defaultLineSpacing
    @AppStorage("reader.paragraphSpacingPt") private var paragraphSpacingPt: Double = ReaderMetrics.defaultParagraphSpacing
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.modelContext) private var modelContext
    @State private var selectedChapterIndex: Int = 1
    @State private var visibleChapterIndex: Int = 1
    @State private var currentAnchor: ReadingAnchor?
    @State private var loadedFromDisk = false
    @State private var isRestoring = false
    @State private var lastSaveAt: Date = .distantPast
    // Chrome auto-hide on scroll.
    @State private var chromeHidden = false
    @State private var lastScrollOffset: CGFloat = 0
    @State private var scrollAccum: CGFloat = 0
    // Paginated-mode one-shot paragraph restore.
    @State private var pendingParagraphRestore: ReadingAnchor?
    @State private var lastAnchorSampleAt: Date = .distantPast
    private let scrollSpace = "readerScroll"

    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .system }
    private var fontFamily: ReaderFontFamily { ReaderFontFamily(rawValue: fontFamilyRaw) ?? .newYork }
    private var width: ReaderWidth { ReaderWidth(rawValue: widthRaw) ?? .medium }
    private var mode: ReadingMode { ReadingMode(rawValue: modeRaw) ?? .continuous }
    private var fontSize: CGFloat { CGFloat(fontSizePt) }
    private var lineSpacing: CGFloat { CGFloat(lineSpacingPt) }
    private var paragraphSpacing: CGFloat { CGFloat(paragraphSpacingPt) }

    init(title: String, author: String, chapters: [AO3ChapterPayload], summary: AO3WorkSummary? = nil,
         onChromeChange: ((Bool) -> Void)? = nil) {
        self.title = title
        self.author = author
        self.chapters = chapters
        self.summary = summary
        self.onChromeChange = onChromeChange
    }

    init(work: Work, onChromeChange: ((Bool) -> Void)? = nil) {
        self.onChromeChange = onChromeChange
        self.title = work.title
        self.author = work.authorName
        self.chapters = work.chapters
            .sorted(by: { $0.index < $1.index })
            .map { AO3ChapterPayload(index: $0.index, title: $0.title, bodyHTML: $0.bodyHTML) }
        self.summary = AO3WorkSummary(
            id: work.ao3Id,
            title: work.title,
            author: work.authorName,
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

    init(payload: AO3WorkPayload, onChromeChange: ((Bool) -> Void)? = nil) {
        self.onChromeChange = onChromeChange
        self.title = payload.summary.title
        self.author = payload.summary.author
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
        // Theme only the nav bar to match the reader, NOT the whole window.
        // `.preferredColorScheme` would propagate up to the scene, forcing the
        // Browse/Library views underneath into the reader's scheme — so leaving
        // a light reader made the app visibly flip back to dark a beat later.
        // `.toolbarColorScheme` is scoped to the bar, so there's nothing to
        // unwind on exit. The reader's body already paints its own fg/bg.
        .toolbarColorScheme(theme.preferredColorScheme, for: .navigationBar)
        // Paint the nav bar with the reader's own background instead of the
        // default translucent gray material, so the bar blends into the page
        // (the buttons keep their own pills). `.hidden` left the window's gray
        // showing through, so force it visible and colored.
        .toolbarBackground(bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .statusBarHidden(chromeHidden)
        .toolbar {
            if chapters.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    chaptersMenu
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                typographyMenu
            }
        }
        // The parent owns the nav bar (its items live there), so it applies the
        // .toolbar(.hidden) — we just tell it when the scroll state flips.
        .onChange(of: chromeHidden) { _, hidden in onChromeChange?(hidden) }
        .onChange(of: modeRaw) { _, _ in
            // Mode switched — show chrome and re-anchor in the new mode.
            chromeHidden = false
        }
        .onAppear { onChromeChange?(chromeHidden) }
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
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ScrollOffsetKey.self,
                                               value: geo.frame(in: .named(scrollSpace)).minY)
                    }
                )
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
            .onPreferenceChange(ScrollOffsetKey.self) { offset in
                updateChrome(forScrollOffset: offset)
            }
            .background(bg)
            .foregroundStyle(fg)
            .safeAreaInset(edge: .top, spacing: 0) {
                if chapters.count > 1 && !chromeHidden {
                    chapterIndicatorBar(fg: fg, bg: bg)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onChange(of: selectedChapterIndex) { _, newIndex in
                // Reveal chrome so the chapter-bar inset is reserved, then
                // scroll — a second pass after layout lands it correctly
                // (below the nav) instead of cut off underneath it.
                if chromeHidden { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden = false } }
                proxy.scrollTo(newIndex, anchor: .top)
                Task {
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    proxy.scrollTo(newIndex, anchor: .top)
                }
            }
            .onChange(of: currentAnchor) { _, anchor in
                if let anchor { saveProgress(anchor) }
            }
            .task { await restoreContinuous(proxy: proxy) }
            .onDisappear { persistNow() }
        }
    }

    private func updateChrome(forScrollOffset offset: CGFloat) {
        let delta = offset - lastScrollOffset
        lastScrollOffset = offset
        // Right at the very top: always show chrome.
        if offset > -16 {
            if chromeHidden { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden = false } }
            scrollAccum = 0
            return
        }
        guard abs(delta) > 0.5 else { return }
        // Reset the accumulator when direction flips.
        if (delta < 0) != (scrollAccum < 0) { scrollAccum = 0 }
        scrollAccum += delta
        if scrollAccum < -18, !chromeHidden {            // scrolled down a bit
            withAnimation(.easeInOut(duration: 0.2)) { chromeHidden = true }
            scrollAccum = 0
        } else if scrollAccum > 16, chromeHidden {        // scrolled up a bit
            withAnimation(.easeInOut(duration: 0.2)) { chromeHidden = false }
            scrollAccum = 0
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
        .background(.ultraThinMaterial)
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
        .onDisappear { persistNow() }
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
                Text("by \(author)").foregroundStyle(fg.opacity(0.65))
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
            scrollSpace: scrollSpace
        )
        .padding(.vertical, Spacing.sm)
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
