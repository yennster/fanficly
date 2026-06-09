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
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
        completion(timeline)
    }
    
    private func loadLastReadEntry() -> SimpleEntry {
        guard let progress = WidgetProgressStore.load() else {
            return SimpleEntry(date: Date(), storyTitle: "No Recent Story", author: "Open the app to read", progress: 0.0)
        }
        return SimpleEntry(
            date: Date(),
            storyTitle: progress.title,
            author: progress.author,
            progress: progress.clampedProgress,
            chapter: progress.chapter,
            paragraph: progress.paragraph,
            storyId: progress.id
        )
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let storyTitle: String
    let author: String
    let progress: Double
    var chapter: Int? = nil
    var paragraph: Int? = nil
    var storyId: Int? = nil
}

struct FanficlyWidgetEntryView : View {
    @Environment(\.widgetFamily) private var family
    var entry: Provider.Entry

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: isSmall ? 8 : 9) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: isSmall ? 8 : 9, style: .continuous)
                            .fill(.white.opacity(0.12))
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: isSmall ? 14 : 15, weight: .semibold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        Color(red: 1.0, green: 0.58, blue: 0.55),
                                        Color(red: 1.0, green: 0.76, blue: 0.48)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .frame(width: isSmall ? 28 : 30, height: isSmall ? 28 : 30)

                    if !isSmall {
                        Text("Fanficly")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }

                    Spacer(minLength: 6)

                    if entry.storyId != nil && (!isSmall || entry.progress > 0) {
                        Text("\(Int((entry.progress * 100).rounded()))%")
                            .font(.system(size: isSmall ? 11 : 12, weight: .heavy))
                            .foregroundStyle(.white.opacity(0.86))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(minWidth: isSmall ? 38 : 42)
                            .padding(.horizontal, isSmall ? 6 : 8)
                            .padding(.vertical, isSmall ? 5 : 4)
                            .background(.white.opacity(0.11), in: Capsule())
                    }
                }

                VStack(alignment: .leading, spacing: isSmall ? 3 : 4) {
                    Text(entry.storyTitle)
                        .font((isSmall ? Font.headline : Font.title3).weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(isSmall ? 2 : 1)
                        .minimumScaleFactor(0.82)

                    Text(entry.author)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if entry.storyId != nil {
                    VStack(alignment: .leading, spacing: isSmall ? 5 : 6) {
                        Text("Continue reading")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))
                        WidgetProgressBar(value: entry.progress)
                    }
                } else {
                    Text("Open the app to start")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
        }
        .padding(isSmall ? 14 : 16)
        .containerBackground(for: .widget) {
            WidgetGlassBackground()
        }
        .widgetURL(resumeURL)
    }

    private var isSmall: Bool {
        family == .systemSmall
    }

    private var resumeURL: URL? {
        guard let storyId = entry.storyId else { return nil }
        var components = URLComponents()
        components.scheme = "fanficly"
        components.host = "resume"
        components.path = "/\(storyId)"

        var queryItems: [URLQueryItem] = []
        if let chapter = entry.chapter {
            queryItems.append(URLQueryItem(name: "chapter", value: "\(chapter)"))
        }
        if let paragraph = entry.paragraph {
            queryItems.append(URLQueryItem(name: "paragraph", value: "\(paragraph)"))
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return components.url
    }
}

private struct WidgetProgressBar: View {
    let value: Double

    var body: some View {
        GeometryReader { geometry in
            let clamped = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.14))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.42, blue: 0.46),
                                Color(red: 1.0, green: 0.67, blue: 0.45)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * clamped)
                    .shadow(color: Color(red: 1.0, green: 0.38, blue: 0.42).opacity(0.30), radius: 6, y: 1)
            }
        }
        .frame(height: 5)
    }
}

private struct WidgetGlassBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.16, green: 0.12, blue: 0.13),
                    Color(red: 0.08, green: 0.07, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Color(red: 0.95, green: 0.30, blue: 0.38).opacity(0.34),
                    .clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 170
            )

            RadialGradient(
                colors: [
                    Color(red: 1.0, green: 0.61, blue: 0.35).opacity(0.20),
                    .clear
                ],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 150
            )

            RadialGradient(
                colors: [
                    Color(red: 0.74, green: 0.16, blue: 0.28).opacity(0.24),
                    .clear
                ],
                center: .bottomLeading,
                startRadius: 12,
                endRadius: 180
            )

            LinearGradient(
                colors: [
                    .white.opacity(0.14),
                    .clear,
                    .black.opacity(0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
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
