import SwiftUI
import SwiftData

struct LibraryView: View {
    @Query(sort: \Work.savedAt, order: .reverse) private var works: [Work]

    var body: some View {
        Group {
            if works.isEmpty {
                ContentUnavailableView(
                    "Nothing saved yet",
                    systemImage: "books.vertical",
                    description: Text("Works you save offline will appear here.")
                )
            } else {
                List(works) { work in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(work.title).font(.headline)
                        Text("by \(work.authorName)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Library")
    }
}

#Preview {
    NavigationStack { LibraryView() }
}
