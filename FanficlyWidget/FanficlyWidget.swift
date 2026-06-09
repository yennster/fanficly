import WidgetKit
import SwiftUI

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), storyTitle: "A Coffee Shop Tale", author: "yennster", progress: 0.35)
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> ()) {
        let entry = loadLastReadEntry()
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
        let entry = loadLastReadEntry()
        let timeline = Timeline(entries: [entry], policy: .atEnd)
        completion(timeline)
    }
    
    private func loadLastReadEntry() -> SimpleEntry {
        guard let suite = UserDefaults(suiteName: "group.io.github.yennster.fanficly"),
              let data = suite.data(forKey: "lastReadProgress"),
              let progress = try? JSONDecoder().decode(WidgetStoryProgress.self, from: data) else {
            return SimpleEntry(date: Date(), storyTitle: "No Recent Story", author: "Open the app to read", progress: 0.0)
        }
        return SimpleEntry(
            date: Date(),
            storyTitle: progress.title,
            author: progress.author,
            progress: progress.progress,
            storyId: progress.id
        )
    }
}

struct WidgetStoryProgress: Codable {
    let id: Int
    let title: String
    let author: String
    let progress: Double
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let storyTitle: String
    let author: String
    let progress: Double
    var storyId: Int? = nil
}

struct FanficlyWidgetEntryView : View {
    var entry: Provider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "book.fill")
                    .foregroundColor(.accentColor)
                Text("Fanficly")
                    .font(.caption.weight(.bold))
                    .foregroundColor(.secondary)
            }
            
            Text(entry.storyTitle)
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            
            Text(entry.author)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
            
            Spacer()
            
            if entry.progress > 0 {
                VStack(spacing: 4) {
                    HStack {
                        Text("\(Int(entry.progress * 100))% Read")
                            .font(.caption2.weight(.semibold))
                        Spacer()
                    }
                    ProgressView(value: entry.progress)
                        .tint(.accentColor)
                }
            } else {
                Text("Ready to start reading")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .containerBackground(for: .widget) {
            Color(.systemBackground)
        }
        .widgetURL(entry.storyId != nil ? URL(string: "fanficly://work/\(entry.storyId!)") : nil)
    }
}

@main
struct FanficlyWidget: Widget {
    let kind: String = "FanficlyWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            FanficlyWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Recently Read")
        .description("Track your reading progress on Fanficly.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
