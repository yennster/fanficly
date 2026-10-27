import SwiftUI
import SwiftData
import UIKit

/// The period the Stats screen aggregates over. `allTime` has no date interval.
enum StatsPeriod: String, CaseIterable, Identifiable {
    case week, month, year, allTime
    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "Week"
        case .month: "Month"
        case .year: "Year"
        case .allTime: "All Time"
        }
    }

    /// The calendar unit this period steps by; nil for all-time.
    var component: Calendar.Component? {
        switch self {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        case .allTime: nil
        }
    }
}

/// The Stats tab: reading totals and top fandoms/ships/authors for a chosen
/// period (week / month / year / all-time), with ‹ › to page through periods.
/// Works for everyone, on-device; iCloud only syncs the underlying
/// `ReadingStat` rows and the streak across the user's own devices. Reading
/// time is the real active time the reader was open and foregrounded.
struct StatsView: View {
    @Query private var stats: [ReadingStat]
    @Environment(\.displayScale) private var displayScale
    @Environment(\.calendar) private var calendar
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var period: StatsPeriod = .allTime
    /// A date inside the period currently shown; ‹ › moves it by one unit.
    @State private var anchor: Date = Date()
    @State private var shareItem: ShareImageItem?
    /// Stories to finish this year (RM-011); 0 = no goal. Per-device, not synced.
    @AppStorage(ReadingGoal.storageKey) private var yearlyGoal = 0
    @State private var editingGoal = false

    private var snapshots: [ReadingStatSnapshot] { stats.map(\.snapshot) }

    /// The date interval for the selected period; nil for all-time.
    private var interval: DateInterval? {
        guard let component = period.component else { return nil }
        return calendar.dateInterval(of: component, for: anchor)
    }

    private var summary: ReadingStatsSummary {
        ReadingStatsAggregator.summarize(snapshots, interval: interval, calendar: calendar)
    }

    /// The goal ring belongs to this year, so it shows on All Time (the default
    /// view) and on the current year, not on other weeks, months or years.
    private var showsGoal: Bool {
        switch period {
        case .allTime: true
        case .year: interval?.contains(Date()) ?? false
        case .week, .month: false
        }
    }

    /// This year's goal progress; nil when there's no goal. "Finished this
    /// year" uses the yearly wrap's rule (finished, and read on a day this
    /// year): `ReadingStat` keeps no finish date, so a story finished last
    /// year and reopened this year counts too.
    private var goalProgress: ReadingGoalProgress? {
        guard yearlyGoal > 0 else { return nil }
        let now = Date()
        let year = calendar.dateInterval(of: .year, for: now)
        let finished = ReadingStatsAggregator.summarize(snapshots, interval: year, calendar: calendar).storiesRead
        return ReadingStatsAggregator.goalProgress(finished: finished, goal: yearlyGoal, now: now, calendar: calendar)
    }

    private var currentYear: Int { calendar.component(.year, from: Date()) }

    /// Human label for the current period ("This Week", "June 2026", "2025", …).
    private var scopeTitle: String {
        guard let interval else { return "All Time" }
        switch period {
        case .allTime:
            return "All Time"
        case .week:
            if interval.contains(Date()) { return "This Week" }
            let f = DateFormatter()
            f.calendar = calendar
            f.dateFormat = "MMM d"
            let end = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
            return "\(f.string(from: interval.start)) – \(f.string(from: end))"
        case .month:
            let f = DateFormatter()
            f.calendar = calendar
            f.dateFormat = "LLLL yyyy"
            return f.string(from: interval.start)
        case .year:
            return "\(calendar.component(.year, from: interval.start))"
        }
    }

    /// Disable forward paging once the period reaches the one containing today.
    private var canPageForward: Bool {
        guard let interval else { return false }
        return interval.end <= Date()
    }

    /// Disable backward paging when there's no reading data before this period.
    private var canPageBackward: Bool {
        guard let interval,
              let range = ReadingStatsAggregator.dataDateRange(snapshots, calendar: calendar)
        else { return false }
        return range.lowerBound < interval.start
    }

    private func page(_ direction: Int) {
        guard let component = period.component,
              let moved = calendar.date(byAdding: component, value: direction, to: anchor) else { return }
        anchor = moved
    }

    var body: some View {
        Group {
            if stats.isEmpty {
                ContentUnavailableView {
                    Label("No Reading Stats Yet", systemImage: "chart.bar.xaxis")
                } description: {
                    Text("Open a story in the reader and your reading time, top fandoms, and yearly wrap-up will show up here.")
                } actions: {
                    // A new reader can set a goal before their first read.
                    goalSection
                }
            } else {
                let summary = summary
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.xl) {
                        periodControl
                        headerCards(summary)
                        if showsGoal { goalSection }
                        topList("Top Fandoms", systemImage: "books.vertical", items: summary.topFandoms)
                        topList("Top Categories", systemImage: "person.2.square.stack", items: summary.topCategories)
                        topList("Top Ships", systemImage: "heart", items: summary.topRelationships)
                        topList("Top Authors", systemImage: "person", items: summary.topAuthors)
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !stats.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: shareWrap) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .help("Share your reading wrap-up")
                }
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.image])
        }
        .sheet(isPresented: $editingGoal) {
            ReadingGoalSheet(goal: $yearlyGoal, year: currentYear)
        }
    }

    /// The yearly goal ring, or an invitation to set one.
    @ViewBuilder
    private var goalSection: some View {
        if let progress = goalProgress {
            Button { editingGoal = true } label: {
                ReadingGoalCard(progress: progress, year: currentYear)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edits your yearly reading goal")
        } else {
            Button { editingGoal = true } label: {
                Label("Set a \(String(currentYear)) Reading Goal", systemImage: "target")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
        }
    }

    /// Render the wrap-up card to an image and present the share sheet.
    @MainActor private func shareWrap() {
        let card = WrapShareCard(scopeTitle: scopeTitle, summary: summary,
                                 goal: showsGoal ? goalProgress : nil, year: currentYear)
        let renderer = ImageRenderer(content: card)
        renderer.scale = max(displayScale, 2)
        if let image = renderer.uiImage {
            shareItem = ShareImageItem(image: image)
        }
    }

    private var periodControl: some View {
        VStack(spacing: Spacing.md) {
            Group {
                // Four segments clip their titles ("All Ti…") at accessibility
                // text sizes; a menu has room for them.
                if dynamicTypeSize.isAccessibilitySize {
                    Picker("Period", selection: $period) {
                        ForEach(StatsPeriod.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker("Period", selection: $period) {
                        ForEach(StatsPeriod.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            // Reset to the current period when switching granularity.
            .onChange(of: period) { _, _ in anchor = Date() }

            if period != .allTime {
                HStack(spacing: Spacing.sm) {
                    Button { page(-1) } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 44, height: 36)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Previous \(period.title.lowercased())")
                    .disabled(!canPageBackward)

                    Spacer(minLength: 0)
                    Text(scopeTitle)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .multilineTextAlignment(.center)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)

                    Button { page(1) } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 44, height: 36)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Next \(period.title.lowercased())")
                    .disabled(!canPageForward)
                }
                .buttonStyle(.borderless)
                .font(.body.weight(.semibold))
                .padding(.vertical, Spacing.xs)
            }
        }
    }

    private func headerCards(_ summary: ReadingStatsSummary) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(scopeTitle)
                .font(.title2.bold())
            // Adaptive grid so the four stat tiles wrap nicely on phone & iPad.
            // One tile a row at accessibility sizes, so values aren't shrunk to fit.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 280 : 150), spacing: Spacing.md)], spacing: Spacing.md) {
                StatTile(value: "\(summary.storiesRead)",
                         label: summary.storiesRead == 1 ? "Story Finished" : "Stories Finished",
                         systemImage: "checkmark.circle")
                StatTile(value: Self.formatDuration(summary.totalSeconds),
                         label: "Time Read",
                         systemImage: "clock")
                StatTile(value: Self.formatWords(summary.totalWords),
                         label: "Words Read",
                         systemImage: "text.alignleft")
                StatTile(value: "\(StreakStore.loadStreakInfo().currentStreak)",
                         label: "Day Streak",
                         systemImage: "flame")
            }
        }
    }

    @ViewBuilder
    private func topList(_ title: String, systemImage: String, items: [ReadingTagCount]) -> some View {
        if !items.isEmpty {
            let maxCount = items.map(\.count).max() ?? 1
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // Counts every work opened, finished or not, unlike Stories Finished.
                HStack(alignment: .firstTextBaseline) {
                    Label(title, systemImage: systemImage)
                        .font(.headline)
                    Spacer(minLength: Spacing.sm)
                    Text("Stories Opened")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    StatBarRow(name: item.name, count: item.count, fraction: Double(item.count) / Double(maxCount))
                }
            }
        }
    }

    /// "12h 34m" / "45m" / "<1m". Active reading time, never zero-padded.
    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return total <= 0 ? "0m" : "<1m" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    /// Compact word count: "1.2M", "340K", "8,500".
    static func formatWords(_ words: Int) -> String {
        if words >= 1_000_000 {
            return String(format: "%.1fM", Double(words) / 1_000_000)
        } else if words >= 10_000 {
            return "\(words / 1000)K"
        }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: words)) ?? "\(words)"
    }
}

private struct StatTile: View {
    let value: String
    let label: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
            Text(value)
                .font(.title.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

/// A progress ring with the reader's yearly goal and pace ("On pace", "3 ahead").
private struct ReadingGoalCard: View {
    let progress: ReadingGoalProgress
    let year: Int

    var body: some View {
        HStack(spacing: Spacing.lg) {
            ReadingGoalRing(fraction: progress.fraction, lineWidth: 8,
                            track: Color.secondary.opacity(0.15), fill: .accentColor)
                .frame(width: 64, height: 64)
                .overlay {
                    Text("\(Int((progress.fraction * 100).rounded(.down)))%")
                        .font(.caption.weight(.bold).monospacedDigit())
                }
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("\(String(year)) Goal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(progress.finished) of \(progress.goal) \(progress.goal == 1 ? "story" : "stories")")
                    .font(.headline)
                    .monospacedDigit()
                Text(progress.paceLabel)
                    .font(.subheadline)
                    .foregroundStyle(progress.ahead < 0 && !progress.isComplete ? Color.secondary : Color.accentColor)
            }
            Spacer(minLength: 0)
            Image(systemName: "pencil")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(String(year)) reading goal: \(progress.finished) of \(progress.goal) \(progress.goal == 1 ? "story" : "stories") finished, \(progress.paceLabel)")
    }
}

/// A circular progress ring, filled clockwise from the top.
struct ReadingGoalRing: View {
    let fraction: Double
    let lineWidth: CGFloat
    let track: Color
    let fill: Color

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(fill, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }
}

/// Sets or removes the yearly goal. Keeps a draft so Cancel leaves it alone.
private struct ReadingGoalSheet: View {
    @Binding var goal: Int
    let year: Int
    @Environment(\.dismiss) private var dismiss
    @State private var draft = 12

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $draft, in: 1...1000) {
                        Text("\(draft) \(draft == 1 ? "story" : "stories")")
                            .monospacedDigit()
                    }
                } header: {
                    Text("Stories to finish in \(String(year))")
                } footer: {
                    Text("Your goal stays on this device and isn't synced.")
                }
                if goal > 0 {
                    Section {
                        Button("Remove Goal", role: .destructive) {
                            goal = 0
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Reading Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        goal = draft
                        dismiss()
                    }
                }
            }
            .onAppear { if goal > 0 { draft = goal } }
        }
        .presentationDetents([.medium])
    }
}

private struct StatBarRow: View {
    let name: String
    let count: Int
    let fraction: Double
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack {
                Text(name)
                    .font(.subheadline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 1)
                Spacer(minLength: Spacing.sm)
                Text("\(count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(count) \(count == 1 ? "story" : "stories") opened")
    }
}

/// Carries a rendered share image into `.sheet(item:)`.
struct ShareImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// A polished, portrait "Year in Review" card rendered to an image for sharing.
/// Sized for a clean 3:4 export; `ImageRenderer` rasterises it off-screen.
struct WrapShareCard: View {
    let scopeTitle: String
    let summary: ReadingStatsSummary
    /// This year's goal, shown as a ring when set and the card covers this year.
    var goal: ReadingGoalProgress? = nil
    /// The goal's year, named on the card since the All Time card shows it too.
    var year: Int = Calendar.current.component(.year, from: Date())

    /// Fanficly brand indigo (#3B2E8C), matching the App Store marketing canvas.
    private let brand = Color(red: 0x3B / 255, green: 0x2E / 255, blue: 0x8C / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text("My Reading")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text(scopeTitle)
                    .font(.system(size: 34, weight: .heavy, design: .serif))
                    .foregroundStyle(.white)
            }

            HStack(spacing: 14) {
                // Stories counts finished works only; the lists below count every
                // work opened, so each number says which it is.
                bigStat("\(summary.storiesRead)", summary.storiesRead == 1 ? "story finished" : "stories finished")
                bigStat(StatsView.formatDuration(summary.totalSeconds), "read")
                bigStat(StatsView.formatWords(summary.totalWords), "words read")
            }

            if let goal {
                goalRow(goal)
            }

            // A goal row takes a list line from each block so the card keeps its size.
            if !summary.topFandoms.isEmpty {
                listBlock("Top Fandoms", items: summary.topFandoms.prefix(goal == nil ? 4 : 3))
            }
            if !summary.topRelationships.isEmpty {
                listBlock("Top Ships", items: summary.topRelationships.prefix(goal == nil ? 3 : 2))
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                // The app icon itself (AppIconMark, written by bin/make-icon.swift),
                // in the home-screen icon's continuous corners.
                Image("AppIconMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 18 * 0.2237, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18 * 0.2237, style: .continuous)
                            .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                    )
                    .accessibilityHidden(true)
                Text("Made with Fanficly")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white.opacity(0.85))
        }
        .padding(28)
        .frame(width: 360, height: 480, alignment: .topLeading)
        .background(
            LinearGradient(colors: [brand, brand.opacity(0.78), .black.opacity(0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private func bigStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func goalRow(_ goal: ReadingGoalProgress) -> some View {
        HStack(spacing: 12) {
            ReadingGoalRing(fraction: goal.fraction, lineWidth: 5,
                            track: .white.opacity(0.2), fill: .white)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(goal.finished) of \(goal.goal) \(goal.goal == 1 ? "story" : "stories") · \(String(year)) goal")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(goal.paceLabel)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private func listBlock(_ title: String, items: ArraySlice<ReadingTagCount>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased())
                Spacer()
                Text("STORIES OPENED")
            }
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white.opacity(0.6))
            ForEach(Array(items)) { item in
                HStack {
                    Text(item.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                    Text("\(item.count)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
    }
}
