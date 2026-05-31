import SwiftUI

struct ReaderView: View {
    let title: String
    let author: String
    let chapters: [AO3ChapterPayload]
    let summary: AO3WorkSummary?

    @AppStorage("reader.theme") private var themeRaw: String = ReaderTheme.system.rawValue
    @AppStorage("reader.fontSize") private var fontSizeRaw: Int = ReaderFontSize.medium.rawValue
    @AppStorage("reader.fontFamily") private var fontFamilyRaw: String = ReaderFontFamily.newYork.rawValue
    @AppStorage("reader.width") private var widthRaw: String = ReaderWidth.medium.rawValue
    @AppStorage("reader.mode") private var modeRaw: String = ReadingMode.continuous.rawValue
    @AppStorage("reader.lineSpacing") private var lineSpacingRaw: String = ReaderLineSpacing.normal.rawValue
    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.modelContext) private var modelContext
    @State private var selectedChapterIndex: Int = 1
    @State private var visibleChapterIndex: Int = 1
    @State private var titleOffset: CGFloat = .greatestFiniteMagnitude
    @State private var currentAnchor: ReadingAnchor?
    @State private var pendingRestore: ReadingAnchor?
    @State private var hasRestored = false
    private let scrollSpace = "readerScroll"

    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .system }
    private var fontSize: ReaderFontSize { ReaderFontSize(rawValue: fontSizeRaw) ?? .medium }
    private var fontFamily: ReaderFontFamily { ReaderFontFamily(rawValue: fontFamilyRaw) ?? .newYork }
    private var width: ReaderWidth { ReaderWidth(rawValue: widthRaw) ?? .medium }
    private var mode: ReadingMode { ReadingMode(rawValue: modeRaw) ?? .continuous }
    private var lineSpacing: ReaderLineSpacing { ReaderLineSpacing(rawValue: lineSpacingRaw) ?? .normal }

    init(title: String, author: String, chapters: [AO3ChapterPayload], summary: AO3WorkSummary? = nil) {
        self.title = title
        self.author = author
        self.chapters = chapters
        self.summary = summary
    }

    init(work: Work) {
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

    init(payload: AO3WorkPayload) {
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
        .preferredColorScheme(theme.preferredColorScheme)
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
                titleOffset = offsets[0] ?? .greatestFiniteMagnitude
            }
            .onPreferenceChange(ScrollAnchorKey.self) { offsets in
                if hasRestored, let anchor = ChapterTracking.topmostAnchor(offsets) {
                    currentAnchor = anchor
                }
            }
            .background(bg)
            .foregroundStyle(fg)
            .safeAreaInset(edge: .top, spacing: 0) {
                // Always-visible slim bar showing the current chapter.
                if chapters.count > 1 {
                    chapterIndicatorBar(fg: fg, bg: bg)
                }
            }
            .onChange(of: selectedChapterIndex) { _, newIndex in
                // Jump straight to the chapter — no animated scroll through
                // everything in between.
                proxy.scrollTo(newIndex, anchor: .top)
            }
            .onChange(of: currentAnchor) { _, anchor in
                if let anchor { saveProgress(anchor) }
            }
            .task { await restore(proxy: proxy) }
            .onDisappear { if let currentAnchor { saveProgress(currentAnchor, force: true) } }
        }
    }

    private func restore(proxy: ScrollViewProxy) async {
        guard !hasRestored, let id = summary?.id else { hasRestored = true; return }
        let saved = ReadingProgressStore.load(ao3Id: id, in: modelContext)
        try? await Task.sleep(nanoseconds: 300_000_000)  // let first layout settle
        if let saved, saved.chapter > 1 || saved.paragraph > 0 {
            // Scroll to the chapter first (a top-level lazy id), which renders
            // its paragraphs, then home in on the exact paragraph.
            proxy.scrollTo(saved.chapter, anchor: .top)
            try? await Task.sleep(nanoseconds: 250_000_000)
            proxy.scrollTo(ChapterTracking.key(chapter: saved.chapter, paragraph: saved.paragraph), anchor: .top)
        }
        hasRestored = true
    }

    @State private var lastSaveAt: Date = .distantPast
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
                    .font(fontFamily.font(size: fontSize.cgFloat + 5, weight: .bold))
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
                    .padding(.vertical, Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .tag(chapter.index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: chapters.count > 1 ? .automatic : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .background(bg)
        .foregroundStyle(fg)
        .task {
            // Restore the chapter (paginated mode is chapter-granular).
            guard !hasRestored, let id = summary?.id else { hasRestored = true; return }
            if let saved = ReadingProgressStore.load(ao3Id: id, in: modelContext) {
                selectedChapterIndex = saved.chapter
            }
            hasRestored = true
        }
        .onChange(of: selectedChapterIndex) { _, chapter in
            if hasRestored {
                saveProgress(ReadingAnchor(chapter: chapter, paragraph: 0), force: true)
            }
        }
    }

    private func titleHeader(fg: Color) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(fontFamily.font(size: fontSize.cgFloat + 14, weight: .bold))
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
                            .font(fontFamily.font(size: fontSize.cgFloat - 1))
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
            font: fontFamily.font(size: fontSize.cgFloat),
            lineSpacing: lineSpacing.points,
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

            Menu {
                Picker("Text size", selection: $fontSizeRaw) {
                    ForEach(ReaderFontSize.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
            } label: {
                Label("Text size · \(fontSize.displayName)", systemImage: "textformat.size")
            }

            Menu {
                Picker("Line spacing", selection: $lineSpacingRaw) {
                    ForEach(ReaderLineSpacing.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
            } label: {
                Label("Line spacing · \(lineSpacing.displayName)", systemImage: "arrow.up.and.down.text.horizontal")
            }

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
}
