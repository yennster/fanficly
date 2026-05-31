import SwiftUI

struct ReaderView: View {
    let work: Work

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(work.title).font(.title).bold()
                Text("by \(work.authorName)").foregroundStyle(.secondary)
                Divider()
                ForEach(work.chapters.sorted(by: { $0.index < $1.index })) { chapter in
                    VStack(alignment: .leading, spacing: 8) {
                        if !chapter.title.isEmpty {
                            Text(chapter.title).font(.title3).bold()
                        }
                        Text(chapter.bodyHTML)
                            .font(.system(.body, design: .serif))
                            .lineSpacing(6)
                    }
                    .padding(.vertical, 8)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding()
        }
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
    }
}
