import SwiftUI

struct ReaderView: View {
    let title: String
    let author: String
    let chapters: [AO3ChapterPayload]

    @AppStorage("reader.theme") private var themeRaw: String = ReaderTheme.system.rawValue
    @AppStorage("reader.fontSize") private var fontSizeRaw: Int = ReaderFontSize.medium.rawValue
    @Environment(\.colorScheme) private var systemColorScheme

    private var theme: ReaderTheme { ReaderTheme(rawValue: themeRaw) ?? .system }
    private var fontSize: ReaderFontSize { ReaderFontSize(rawValue: fontSizeRaw) ?? .medium }

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
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text(title).font(.system(size: fontSize.cgFloat + 14, weight: .bold, design: .serif))
                Text("by \(author)").foregroundStyle(theme.foreground(for: scheme).opacity(0.65))
                Divider().overlay(theme.foreground(for: scheme).opacity(0.2))
                ForEach(chapters, id: \.index) { chapter in
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        if !chapter.title.isEmpty {
                            Text(chapter.title)
                                .font(.system(size: fontSize.cgFloat + 4, weight: .semibold, design: .serif))
                        }
                        HTMLText(html: chapter.bodyHTML)
                            .font(.system(size: fontSize.cgFloat, design: .serif))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, Spacing.sm)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding()
        }
        .frame(maxWidth: .infinity)
        .background(theme.background(for: scheme))
        .foregroundStyle(theme.foreground(for: scheme))
        .preferredColorScheme(theme.preferredColorScheme)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Theme", selection: $themeRaw) {
                        ForEach(ReaderTheme.allCases) { t in
                            Text(t.displayName).tag(t.rawValue)
                        }
                    }
                    Picker("Font Size", selection: $fontSizeRaw) {
                        ForEach(ReaderFontSize.allCases) { f in
                            Text(f.displayName).tag(f.rawValue)
                        }
                    }
                } label: {
                    Image(systemName: "textformat.size")
                }
            }
        }
    }
}
