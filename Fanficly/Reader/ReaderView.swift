import SwiftUI

struct ReaderView: View {
    let title: String
    let author: String
    let chapters: [AO3ChapterPayload]

    @AppStorage("reader.theme") private var themeRaw: String = ReaderTheme.system.rawValue
    @AppStorage("reader.fontSize") private var fontSizeRaw: Int = ReaderFontSize.medium.rawValue
    @AppStorage("reader.fontFamily") private var fontFamilyRaw: String = ReaderFontFamily.newYork.rawValue
    @AppStorage("reader.width") private var widthRaw: String = ReaderWidth.medium.rawValue
    @Environment(\.colorScheme) private var systemColorScheme

    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .system }
    private var fontSize: ReaderFontSize { ReaderFontSize(rawValue: fontSizeRaw) ?? .medium }
    private var fontFamily: ReaderFontFamily { ReaderFontFamily(rawValue: fontFamilyRaw) ?? .newYork }
    private var width: ReaderWidth { ReaderWidth(rawValue: widthRaw) ?? .medium }

    init(title: String, author: String, chapters: [AO3ChapterPayload]) {
        self.title = title
        self.author = author
        self.chapters = chapters
    }

    init(work: Work) {
        self.title = work.title
        self.author = work.authorName
        self.chapters = work.chapters
            .sorted(by: { $0.index < $1.index })
            .map { AO3ChapterPayload(index: $0.index, title: $0.title, bodyHTML: $0.bodyHTML) }
    }

    init(payload: AO3WorkPayload) {
        self.title = payload.summary.title
        self.author = payload.summary.author
        self.chapters = payload.chapters
    }

    var body: some View {
        let scheme = theme.preferredColorScheme ?? systemColorScheme
        let fg = theme.foreground(for: scheme)
        let bg = theme.background(for: scheme)

        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text(title)
                            .font(fontFamily.font(size: fontSize.cgFloat + 14, weight: .bold))
                        if !author.isEmpty {
                            Text("by \(author)").foregroundStyle(fg.opacity(0.65))
                        }
                        Divider().overlay(fg.opacity(0.2))
                    }
                    .id("__top")

                    ForEach(chapters, id: \.index) { chapter in
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            if !chapter.title.isEmpty {
                                Text(chapter.title)
                                    .font(fontFamily.font(size: fontSize.cgFloat + 4, weight: .semibold))
                            }
                            HTMLText(html: chapter.bodyHTML)
                                .font(fontFamily.font(size: fontSize.cgFloat))
                                .lineSpacing(6)
                                .foregroundStyle(fg)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, Spacing.sm)
                        .id(chapter.index)
                    }
                }
                .frame(maxWidth: width.maxWidth, alignment: .leading)
                .padding()
            }
            .frame(maxWidth: .infinity)
            .background(bg)
            .foregroundStyle(fg)
            .preferredColorScheme(theme.preferredColorScheme)
            .toolbar {
                if chapters.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        chaptersMenu(proxy: proxy)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    typographyMenu
                }
            }
        }
    }

    private func chaptersMenu(proxy: ScrollViewProxy) -> some View {
        Menu {
            ForEach(chapters, id: \.index) { chapter in
                Button {
                    withAnimation { proxy.scrollTo(chapter.index, anchor: .top) }
                } label: {
                    let label = chapter.title.isEmpty
                        ? "Chapter \(chapter.index)"
                        : "Chapter \(chapter.index): \(chapter.title)"
                    Text(label)
                }
            }
        } label: {
            Image(systemName: "list.bullet")
        }
    }

    private var typographyMenu: some View {
        Menu {
            Picker("Theme", selection: $themeRaw) {
                ForEach(ReaderTheme.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Picker("Font", selection: $fontFamilyRaw) {
                ForEach(ReaderFontFamily.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Picker("Font size", selection: $fontSizeRaw) {
                ForEach(ReaderFontSize.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Picker("Width", selection: $widthRaw) {
                ForEach(ReaderWidth.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
        } label: {
            Image(systemName: "textformat.size")
        }
    }
}
