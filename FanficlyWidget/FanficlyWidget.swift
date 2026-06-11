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
                    AppBookIcon()
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
        .padding(isSmall ? 12 : 14)
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

private struct AppBookIcon: View {
    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            
            let bookW = width * 0.60
            let bookH = height * 0.46
            let cx = width / 2
            let cy = height / 2
            let halfW = bookW / 2
            let halfH = bookH / 2
            let fan: CGFloat = bookH * 0.06
            let spineDrop: CGFloat = bookH * 0.05
            let spineGap: CGFloat = width * 0.018
            let corner: CGFloat = width * 0.015

            func normalize(_ p: CGPoint) -> CGPoint {
                let len = max(1.0, (p.x * p.x + p.y * p.y).squareRoot())
                return CGPoint(x: p.x / len, y: p.y / len)
            }

            func roundedQuadPath(p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, radius: CGFloat) -> Path {
                let pts = [p0, p1, p2, p3]
                var path = Path()
                for i in 0..<4 {
                    let curr = pts[i]
                    let prev = pts[(i + 3) % 4]
                    let next = pts[(i + 1) % 4]
                    let toPrev = normalize(CGPoint(x: prev.x - curr.x, y: prev.y - curr.y))
                    let toNext = normalize(CGPoint(x: next.x - curr.x, y: next.y - curr.y))
                    let start = CGPoint(x: curr.x + toPrev.x * radius, y: curr.y + toPrev.y * radius)
                    let end = CGPoint(x: curr.x + toNext.x * radius, y: curr.y + toNext.y * radius)
                    if i == 0 { path.move(to: start) } else { path.addLine(to: start) }
                    path.addQuadCurve(to: end, control: curr)
                }
                path.closeSubpath()
                return path
            }

            let leftPath = roundedQuadPath(
                p0: CGPoint(x: cx - halfW,    y: cy - halfH + fan),
                p1: CGPoint(x: cx - spineGap, y: cy - halfH + spineDrop),
                p2: CGPoint(x: cx - spineGap, y: cy + halfH - spineDrop),
                p3: CGPoint(x: cx - halfW,    y: cy + halfH - fan),
                radius: corner
            )

            let rightPath = roundedQuadPath(
                p0: CGPoint(x: cx + spineGap, y: cy - halfH + spineDrop),
                p1: CGPoint(x: cx + halfW,    y: cy - halfH + fan),
                p2: CGPoint(x: cx + halfW,    y: cy + halfH - fan),
                p3: CGPoint(x: cx + spineGap, y: cy + halfH - spineDrop),
                radius: corner
            )

            // Fill book pages with white
            context.fill(leftPath, with: .color(.white))
            context.fill(rightPath, with: .color(.white))

            // Cut out text lines by using blendMode .clear
            context.blendMode = .clear

            let lineCount = 5
            let lineH: CGFloat = bookH * 0.045
            let gap = (bookH * 0.62) / CGFloat(lineCount)
            
            let pageWidth = halfW - spineGap
            let pagePadding = pageWidth * 0.16
            let fullLineWidth = pageWidth - (pagePadding * 2)
            
            for i in 0..<lineCount {
                let y = cy - bookH * 0.27 + CGFloat(i) * gap
                let leftW = fullLineWidth * (i == 0 ? 0.6 : 1.0)
                let rightW = fullLineWidth * (i == 0 ? 0.55 : 1.0)
                
                let leftX = cx - halfW + pagePadding
                let rightX = cx + spineGap + pagePadding
                
                let leftRect = CGRect(x: leftX, y: y, width: leftW, height: lineH)
                let rightRect = CGRect(x: rightX, y: y, width: rightW, height: lineH)
                
                context.fill(Path(leftRect), with: .color(.black))
                context.fill(Path(rightRect), with: .color(.black))
            }
        }
    }
}

private struct WidgetGlassBackground: View {
    var body: some View {
        ZStack {
            // Dark maroon to AO3 red base gradient (matching the app icon)
            LinearGradient(
                colors: [
                    Color(red: 0.45, green: 0.00, blue: 0.00),
                    Color(red: 0.60, green: 0.00, blue: 0.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Subtle bright red glow in the top-leading corner
            RadialGradient(
                colors: [
                    Color(red: 1.0, green: 0.35, blue: 0.42).opacity(0.25),
                    .clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 120
            )

            // Subtle vertical highlight to give it depth
            LinearGradient(
                colors: [
                    .white.opacity(0.12),
                    .clear,
                    .black.opacity(0.15)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

struct StreakEntry: TimelineEntry {
    let date: Date
    let streak: Int
    let activityDates: [String]
}

struct StreakProvider: TimelineProvider {
    func placeholder(in context: Context) -> StreakEntry {
        StreakEntry(date: Date(), streak: 5, activityDates: ["2026-06-11", "2026-06-10", "2026-06-09", "2026-06-08", "2026-06-07"])
    }

    func getSnapshot(in context: Context, completion: @escaping (StreakEntry) -> ()) {
        let info = StreakStore.loadStreakInfo()
        completion(StreakEntry(date: Date(), streak: info.currentStreak, activityDates: info.activityDates))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StreakEntry>) -> ()) {
        let info = StreakStore.loadStreakInfo()
        let entry = StreakEntry(date: Date(), streak: info.currentStreak, activityDates: info.activityDates)
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
        completion(timeline)
    }
}

struct StreakWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: StreakProvider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: isSmall ? 8 : 2) {
            // Header Row (Matches Recently Read widget structure)
            HStack(spacing: 8) {
                AppBookIcon()
                    .frame(width: isSmall ? 28 : 30, height: isSmall ? 28 : 30)

                if !isSmall {
                    Text("Fanficly")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 6)

                // Capsule Badge (Matches Recently Read percentage badge style)
                Text("Streak")
                    .font(.system(size: isSmall ? 10 : 12, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: isSmall ? 38 : 42)
                    .padding(.horizontal, isSmall ? 6 : 8)
                    .padding(.vertical, isSmall ? 5 : 4)
                    .background(.white.opacity(0.11), in: Capsule())
            }

            // Middle Section: Streak Count & Title (Matches Title & Author structure)
            VStack(alignment: .leading, spacing: isSmall ? 3 : 0) {
                Text("\(entry.streak) \(entry.streak == 1 ? "Day" : "Days")")
                    .font((isSmall ? Font.headline : Font.title3).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("Reading Streak")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer(minLength: isSmall ? 4 : 2)

            // Bottom Section: Weekly Progress Dots (Matches Continue Reading & Progress Bar structure)
            VStack(alignment: .leading, spacing: isSmall ? 5 : 2) {
                let days = StreakStore.getLast7DaysActivity(from: entry.activityDates, relativeTo: entry.date)
                let readCount = days.filter(\.isRead).count
                
                HStack {
                    Text("Weekly progress")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.72))
                    
                    if !isSmall {
                        Spacer()
                        Text("Read \(readCount) of last 7 days")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                
                HStack(spacing: isSmall ? 4 : 6) {
                    ForEach(days) { day in
                        VStack(spacing: isSmall ? 4 : 2) {
                            Text(day.name)
                                .font(.system(size: isSmall ? 8 : 10, weight: .bold))
                                .foregroundStyle(day.isToday ? .white : .white.opacity(0.5))
                            
                            ZStack {
                                if day.isRead {
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    Color(red: 1.0, green: 0.62, blue: 0.45),
                                                    Color(red: 1.0, green: 0.38, blue: 0.42)
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                        )
                                        .frame(width: isSmall ? 11 : 14, height: isSmall ? 11 : 14)
                                    
                                    Image(systemName: "checkmark")
                                        .font(.system(size: isSmall ? 5 : 7, weight: .black))
                                        .foregroundStyle(.white)
                                } else {
                                    Circle()
                                        .stroke(.white.opacity(0.25), lineWidth: 1.2)
                                        .frame(width: isSmall ? 11 : 14, height: isSmall ? 11 : 14)
                                }
                                
                                if day.isToday {
                                    Circle()
                                        .stroke(.white, lineWidth: 1.5)
                                        .frame(width: isSmall ? 15 : 18, height: isSmall ? 15 : 18)
                                }
                            }
                            .frame(width: isSmall ? 15 : 18, height: isSmall ? 15 : 18)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, isSmall ? 4 : 3)
                .padding(.horizontal, isSmall ? 4 : 8)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: isSmall ? 8 : 10))
            }
        }
        .padding(.horizontal, isSmall ? 12 : 14)
        .padding(.vertical, isSmall ? 12 : 14)
        .containerBackground(for: .widget) {
            WidgetGlassBackground()
        }
    }

    private var isSmall: Bool {
        family == .systemSmall
    }
}

struct StreakWidget: Widget {
    let kind: String = "FanficlyStreakWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StreakProvider()) { entry in
            StreakWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Reading Streak")
        .description("Track your daily reading streak and recent history.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct FanficlyWidget: Widget {
    let kind: String = "FanficlyWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            FanficlyWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Recently Read")
        .description("Track your reading progress on Fanficly.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Subscriptions Tracker & Update Alert Widget

struct SubscriptionsEntry: TimelineEntry {
    let date: Date
    let updates: [WidgetSubscriptionUpdate]
}

struct SubscriptionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> SubscriptionsEntry {
        SubscriptionsEntry(date: Date(), updates: [
            WidgetSubscriptionUpdate(workId: 101, title: "A Coffee Shop Story", author: "AuthorA", chapterCount: 15, isFollowed: true, updatedAt: Date()),
            WidgetSubscriptionUpdate(workId: 102, title: "Space Adventures", author: "AuthorB", chapterCount: 8, isFollowed: false, updatedAt: Date().addingTimeInterval(-3600))
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (SubscriptionsEntry) -> ()) {
        let list = WidgetDataStore.loadLocalSubscriptions()
        completion(SubscriptionsEntry(date: Date(), updates: list))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SubscriptionsEntry>) -> ()) {
        let list = WidgetDataStore.loadLocalSubscriptions()
        let entry = SubscriptionsEntry(date: Date(), updates: list)
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
        completion(timeline)
    }
}

struct SubscriptionsWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: SubscriptionsProvider.Entry

    var body: some View {
        let isSmall = family == .systemSmall
        let updates = entry.updates
        
        VStack(alignment: .leading, spacing: isSmall ? 8 : 9) {
            // Header Row
            HStack(spacing: 8) {
                AppBookIcon()
                    .frame(width: isSmall ? 28 : 30, height: isSmall ? 28 : 30)

                if !isSmall {
                    Text("Fanficly")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.72))
                }

                Spacer()

                Text("Updates")
                    .font(.system(size: isSmall ? 9 : 11, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.86))
                    .padding(.horizontal, isSmall ? 6 : 8)
                    .padding(.vertical, isSmall ? 5 : 4)
                    .background(.white.opacity(0.11), in: Capsule())
            }

            // Middle Section
            if updates.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No Updates")
                        .font((isSmall ? Font.headline : Font.title3).weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Everything is read")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
            } else {
                let first = updates[0]
                if isSmall {
                    Link(destination: URL(string: "fanficly://resume/\(first.workId)")!) {
                        VStack(alignment: .leading, spacing: 2) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(first.title)
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                
                                Text("By \(first.author)")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(updates.count) \(updates.count == 1 ? "Update" : "Updates")")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white.opacity(0.72))
                                Text("Last: Ch \(first.chapterCount)")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    // Medium Family lists top 3 updates
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(updates.prefix(3), id: \.workId) { sub in
                            Link(destination: URL(string: "fanficly://resume/\(sub.workId)")!) {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(sub.title)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        Text(sub.author)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.white.opacity(0.55))
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Text("Ch \(sub.chapterCount)")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.72))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(isSmall ? 12 : 14)
        .containerBackground(for: .widget) {
            WidgetGlassBackground()
        }
    }
}

struct SubscriptionsWidget: Widget {
    let kind: String = "FanficlySubscriptionsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SubscriptionsProvider()) { entry in
            SubscriptionsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Subscriptions")
        .description("Track updates on your followed fanfics.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Custom Folder Quick-Link Widget

struct FolderShortcutEntry: TimelineEntry {
    let date: Date
    let folders: [WidgetFolderShortcut]
}

struct FolderShortcutProvider: TimelineProvider {
    func placeholder(in context: Context) -> FolderShortcutEntry {
        FolderShortcutEntry(date: Date(), folders: [
            WidgetFolderShortcut(name: "To Read", workCount: 15),
            WidgetFolderShortcut(name: "Favorites", workCount: 8),
            WidgetFolderShortcut(name: "Completed", workCount: 42)
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (FolderShortcutEntry) -> ()) {
        let list = WidgetDataStore.loadLocalFolders()
        completion(FolderShortcutEntry(date: Date(), folders: list))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FolderShortcutEntry>) -> ()) {
        let list = WidgetDataStore.loadLocalFolders()
        let entry = FolderShortcutEntry(date: Date(), folders: list)
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
        completion(timeline)
    }
}

struct FolderShortcutWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: FolderShortcutProvider.Entry

    var body: some View {
        let isSmall = family == .systemSmall
        let folders = entry.folders
        
        VStack(alignment: .leading, spacing: isSmall ? 8 : 9) {
            // Header Row
            HStack(spacing: 8) {
                AppBookIcon()
                    .frame(width: isSmall ? 28 : 30, height: isSmall ? 28 : 30)

                if !isSmall {
                    Text("Fanficly")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.72))
                }

                Spacer()

                Text("Folders")
                    .font(.system(size: isSmall ? 9 : 11, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.86))
                    .padding(.horizontal, isSmall ? 6 : 8)
                    .padding(.vertical, isSmall ? 5 : 4)
                    .background(.white.opacity(0.11), in: Capsule())
            }

            // Middle Section
            if folders.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No Folders")
                        .font((isSmall ? Font.headline : Font.title3).weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Organize works in app")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
            } else {
                let first = folders[0]
                if isSmall {
                    Link(destination: URL(string: "fanficly://library?folder=\(first.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!) {
                        VStack(alignment: .leading, spacing: 2) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(first.name)
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                
                                Text("Library Folder")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                            
                            Spacer(minLength: 4)
                            
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(first.workCount)")
                                    .font(.system(size: 32, weight: .bold))
                                    .foregroundStyle(.white)
                                Text(first.workCount == 1 ? "story" : "stories")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    // Medium Family lists top 3 folders
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(folders.prefix(3), id: \.name) { folder in
                            Link(destination: URL(string: "fanficly://library?folder=\(folder.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!) {
                                HStack {
                                    Image(systemName: "folder")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.55))
                                    
                                    Text(folder.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(folder.workCount) \(folder.workCount == 1 ? "story" : "stories")")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(isSmall ? 12 : 14)
        .containerBackground(for: .widget) {
            WidgetGlassBackground()
        }
    }
}

struct FolderShortcutWidget: Widget {
    let kind: String = "FanficlyFolderShortcutWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FolderShortcutProvider()) { entry in
            FolderShortcutWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Folder Shortcuts")
        .description("View and access your custom library folders.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Saved Searches / Fandom Shortcut Widget

struct SavedSearchesEntry: TimelineEntry {
    let date: Date
    let searches: [WidgetSavedSearch]
}

struct SavedSearchesProvider: TimelineProvider {
    func placeholder(in context: Context) -> SavedSearchesEntry {
        SavedSearchesEntry(date: Date(), searches: [
            WidgetSavedSearch(name: "Hermione/Draco", query: "Hermione/Draco", isFilter: false),
            WidgetSavedSearch(name: "MCU Stars", query: "{\"fandoms\":[\"Marvel\"]}", isFilter: true)
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (SavedSearchesEntry) -> ()) {
        let list = WidgetDataStore.loadLocalSavedSearches()
        completion(SavedSearchesEntry(date: Date(), searches: list))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SavedSearchesEntry>) -> ()) {
        let list = WidgetDataStore.loadLocalSavedSearches()
        let entry = SavedSearchesEntry(date: Date(), searches: list)
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(15 * 60)))
        completion(timeline)
    }
}

struct SavedSearchesWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: SavedSearchesProvider.Entry

    var body: some View {
        let isSmall = family == .systemSmall
        let searches = entry.searches
        
        VStack(alignment: .leading, spacing: isSmall ? 8 : 9) {
            // Header Row
            HStack(spacing: 8) {
                AppBookIcon()
                    .frame(width: isSmall ? 28 : 30, height: isSmall ? 28 : 30)

                if !isSmall {
                    Text("Fanficly")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.72))
                }

                Spacer()

                Text("Searches")
                    .font(.system(size: isSmall ? 9 : 11, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.86))
                    .padding(.horizontal, isSmall ? 6 : 8)
                    .padding(.vertical, isSmall ? 5 : 4)
                    .background(.white.opacity(0.11), in: Capsule())
            }

            // Middle Section
            if searches.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No Searches")
                        .font((isSmall ? Font.headline : Font.title3).weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Save search queries in app")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
            } else {
                let first = searches[0]
                let destURL = "fanficly://search?query=\(first.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
                if isSmall {
                    Link(destination: URL(string: destURL)!) {
                        VStack(alignment: .leading, spacing: 2) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(first.name)
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                
                                Text(first.isFilter ? "Saved Filter" : "Saved Search")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                            
                            Spacer(minLength: 4)
                            
                            HStack(spacing: 5) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.72))
                                Text("Run Search")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white.opacity(0.86))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.white.opacity(0.12), in: Capsule())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    // Medium Family lists top 3 searches
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(searches.prefix(3), id: \.name) { item in
                            let itemURL = "fanficly://search?query=\(item.query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
                            Link(destination: URL(string: itemURL)!) {
                                HStack {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.55))
                                    
                                    Text(item.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Spacer()
                                    
                                    Text(item.isFilter ? "Filter" : "Search")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.55))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.white.opacity(0.08), in: Capsule())
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(isSmall ? 12 : 14)
        .containerBackground(for: .widget) {
            WidgetGlassBackground()
        }
    }
}

struct SavedSearchesWidget: Widget {
    let kind: String = "FanficlySavedSearchesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SavedSearchesProvider()) { entry in
            SavedSearchesWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Saved Searches")
        .description("Quickly run your saved search and filter terms.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Random recommendation / "To Read" Pile Widget

struct RecommendationEntry: TimelineEntry {
    let date: Date
    let rec: WidgetRecommendation?
}

struct RecommendationProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecommendationEntry {
        RecommendationEntry(date: Date(), rec: WidgetRecommendation(
            workId: 201,
            title: "A Magnificent Tale of Stars",
            author: "Acura",
            summary: "An epic adventure in a galaxy far away, exploring relationships and new worlds. Highly rated by the community.",
            tags: ["Action", "Sci-Fi", "FandomA"]
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (RecommendationEntry) -> ()) {
        let list = WidgetDataStore.loadLocalRecommendations()
        completion(RecommendationEntry(date: Date(), rec: list.first))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecommendationEntry>) -> ()) {
        let list = WidgetDataStore.loadLocalRecommendations()
        let recommendation = list.randomElement()
        let entry = RecommendationEntry(date: Date(), rec: recommendation)
        let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60)))
        completion(timeline)
    }
}

struct RecommendationWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: RecommendationProvider.Entry

    var body: some View {
        let isSmall = family == .systemSmall
        
        VStack(alignment: .leading, spacing: isSmall ? 8 : 9) {
            // Header Row
            HStack(spacing: 8) {
                AppBookIcon()
                    .frame(width: isSmall ? 28 : 30, height: isSmall ? 28 : 30)

                if !isSmall {
                    Text("Fanficly")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white.opacity(0.72))
                }

                Spacer()

                Text("For You")
                    .font(.system(size: isSmall ? 9 : 11, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.86))
                    .padding(.horizontal, isSmall ? 6 : 8)
                    .padding(.vertical, isSmall ? 5 : 4)
                    .background(.white.opacity(0.11), in: Capsule())
            }

            // Middle Section
            if let rec = entry.rec {
                Link(destination: URL(string: "fanficly://resume/\(rec.workId)")!) {
                    VStack(alignment: .leading, spacing: isSmall ? 4 : 6) {
                        VStack(alignment: .leading, spacing: isSmall ? 2 : 4) {
                            Text(rec.title)
                                .font(isSmall ? .system(size: 14, weight: .semibold) : Font.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(isSmall ? 3 : 1)
                                .minimumScaleFactor(0.82)
                            
                            Text(rec.author)
                                .font(isSmall ? .caption : .subheadline)
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                        
                        if isSmall {
                            Spacer(minLength: 0)
                        } else {
                            Spacer(minLength: 2)
                            
                            VStack(alignment: .leading, spacing: 5) {
                                Text(rec.summary)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.72))
                                    .lineLimit(2)
                                    .layoutPriority(1)
                                
                                if let tag = rec.tags.first {
                                    Text(tag)
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.86))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(.white.opacity(0.11), in: Capsule())
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No Starred Works")
                        .font((isSmall ? Font.headline : Font.title3).weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Star works to get recs")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
            }
        }
        .padding(isSmall ? 12 : 14)
        .containerBackground(for: .widget) {
            WidgetGlassBackground()
        }
    }
}

struct RecommendationWidget: Widget {
    let kind: String = "FanficlyRecommendationWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecommendationProvider()) { entry in
            RecommendationWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Recommendation")
        .description("Spotlights a starred or unread story from your library.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

@main
struct FanficlyWidgetsBundle: WidgetBundle {
    var body: some Widget {
        FanficlyWidget()
        StreakWidget()
        SubscriptionsWidget()
        FolderShortcutWidget()
        SavedSearchesWidget()
        RecommendationWidget()
    }
}
