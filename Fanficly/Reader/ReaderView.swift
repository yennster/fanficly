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
    @State private var selectedChapterIndex: Int = 1
    @State private var visibleChapterIndex: Int = 1
    @State private var titleOffset: CGFloat = .greatestFiniteMagnitude
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
            .background(bg)
            .foregroundStyle(fg)
            .overlay(alignment: .top) {
                // Only show once the work title has scrolled off the top,
                // so the pill never overlaps the title.
                if chapters.count > 1 && titleOffset < -30 {
                    chapterIndicatorPill(fg: fg, bg: bg)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: titleOffset < -30)
            .onChange(of: selectedChapterIndex) { _, newIndex in
                withAnimation { proxy.scrollTo(newIndex, anchor: .top) }
            }
        }
    }

    private func chapterIndicatorPill(fg: Color, bg: Color) -> some View {
        let chapter = chapters.first(where: { $0.index == visibleChapterIndex })
        let label = chapter?.title.isEmpty == false
            ? "Ch. \(visibleChapterIndex) · \(chapter!.title)"
            : "Chapter \(visibleChapterIndex) of \(chapters.count)"
        return Text(label)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(fg.opacity(0.12)))
            .foregroundStyle(fg.opacity(0.9))
            .padding(.top, 6)
            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
    }

    private func chapterHeader(_ chapter: AO3ChapterPayload, fg: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("CHAPTER \(chapter.index)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                Rectangle()
                    .fill(fg.opacity(0.15))
                    .frame(height: 1)
            }
            if !chapter.title.isEmpty {
                Text(chapter.title)
                    .font(fontFamily.font(size: fontSize.cgFloat + 5, weight: .bold))
            }
        }
        .padding(.top, Spacing.lg)
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
        HTMLText(html: chapter.bodyHTML)
            .font(fontFamily.font(size: fontSize.cgFloat))
            .lineSpacing(lineSpacing.points)
            .foregroundStyle(fg)
            .textSelection(.enabled)
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
            Section("Reading mode") {
                Picker("Reading mode", selection: $modeRaw) {
                    ForEach(ReadingMode.allCases) {
                        Label($0.displayName, systemImage: $0.symbol).tag($0.rawValue)
                    }
                }
            }
            Section("Theme") {
                Picker("Theme", selection: $themeRaw) {
                    ForEach(ReaderTheme.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
            }
            Section("Font") {
                Picker("Font", selection: $fontFamilyRaw) {
                    ForEach(ReaderFontFamily.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
            }
            Section("Font size") {
                Picker("Font size", selection: $fontSizeRaw) {
                    ForEach(ReaderFontSize.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
            }
            Section("Line spacing") {
                Picker("Line spacing", selection: $lineSpacingRaw) {
                    ForEach(ReaderLineSpacing.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
            }
            Section("Text width") {
                Picker("Text width", selection: $widthRaw) {
                    ForEach(ReaderWidth.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
            }
        } label: {
            Image(systemName: "textformat")
        }
    }
}
