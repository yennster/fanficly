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
                let leftW = fullLineWidth * (i == lineCount - 1 ? 0.6 : 1.0)
                let rightW = fullLineWidth * (i == lineCount - 1 ? 0.55 : 1.0)
                
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
        let isSmall = family == .systemSmall
        
        VStack(alignment: .leading, spacing: isSmall ? 8 : 9) {
            // Header Row (Matches Recently Read widget structure)
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.11))
                    Image(systemName: "flame.fill")
                        .font(.system(size: isSmall ? 14 : 16, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color(red: 1.0, green: 0.62, blue: 0.45),
                                    Color(red: 1.0, green: 0.38, blue: 0.42)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
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
            VStack(alignment: .leading, spacing: isSmall ? 3 : 4) {
                Text("\(entry.streak) \(entry.streak == 1 ? "Day" : "Days")")
                    .font((isSmall ? Font.headline : Font.title3).weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text("Reading Streak")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            // Bottom Section: Weekly Progress Dots (Matches Continue Reading & Progress Bar structure)
            VStack(alignment: .leading, spacing: isSmall ? 5 : 6) {
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
                        VStack(spacing: isSmall ? 4 : 5) {
                            Text(day.name)
                                .font(.system(size: isSmall ? 8 : 9, weight: .bold))
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
                                        .stroke(.white, lineWidth: 1)
                                        .frame(width: isSmall ? 15 : 18, height: isSmall ? 15 : 18)
                                }
                            }
                            .frame(width: isSmall ? 15 : 18, height: isSmall ? 15 : 18)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, isSmall ? 4 : 6)
                .padding(.horizontal, isSmall ? 4 : 8)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: isSmall ? 8 : 10))
            }
        }
        .padding(isSmall ? 12 : 14)
        .containerBackground(for: .widget) {
            WidgetGlassBackground()
        }
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

@main
struct FanficlyWidgetsBundle: WidgetBundle {
    var body: some Widget {
        FanficlyWidget()
        StreakWidget()
    }
}
