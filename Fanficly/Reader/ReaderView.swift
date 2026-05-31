import SwiftUI

struct ReaderView: View {
    let title: String
    let author: String
    let chapters: [AO3ChapterPayload]

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
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                Text(title).font(Typography.readerTitle)
                Text("by \(author)").foregroundStyle(.secondary)
                Divider()
                ForEach(chapters, id: \.index) { chapter in
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        if !chapter.title.isEmpty {
                            Text(chapter.title).font(.title3).bold()
                        }
                        HTMLText(html: chapter.bodyHTML)
                            .font(Typography.readerBody)
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
        .background(Color(.systemBackground))
    }
}
