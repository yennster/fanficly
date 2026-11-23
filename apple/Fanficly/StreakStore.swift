import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

public struct StreakInfo: Codable, Equatable, Sendable {
    public let currentStreak: Int
    public let activityDates: [String]
}

public struct WeekdayActivity: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// The one-letter weekday ("M").
    public let name: String
    /// The full weekday name ("Monday"), for VoiceOver.
    public let fullName: String
    public let isToday: Bool
    public let isRead: Bool
    
    public init(id: UUID = UUID(), name: String, fullName: String, isToday: Bool, isRead: Bool) {
        self.id = id
        self.name = name
        self.fullName = fullName
        self.isToday = isToday
        self.isRead = isRead
    }
}

public enum StreakStore {
    public static let appGroupIdentifier = "group.io.github.yennster.fanficly"
    public static let activityDatesKey = "streak.activityDates"
    public static let currentStreakKey = "streak.currentStreak"

    nonisolated(unsafe) private static var cloudObserver: NSObjectProtocol?
    nonisolated(unsafe) private static var cloudSaveTask: Task<Void, Never>?

    public static func recordReadingEvent(on date: Date = .now) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        let dateStr = formatter.string(from: date)
        
        var dates = readDatesLocal()
        if !dates.contains(dateStr) {
            dates.append(dateStr)
            dates.sort()
            
            // Keep history limited to the last 100 days
            if dates.count > 100 {
                dates.removeFirst(dates.count - 100)
            }
            
            let streak = calculateStreak(from: dates, relativeTo: date)
            save(dates: dates, streak: streak)
        }
    }
    
    public static func loadStreakInfo(relativeTo date: Date = .now) -> StreakInfo {
        _ = NSUbiquitousKeyValueStore.default.synchronize()
        
        let localDates = readDatesLocal()
        let cloudDates = readDatesCloud()
        
        var mergedSet = Set(localDates)
        mergedSet.formUnion(cloudDates)
        
        var mergedDates = Array(mergedSet).sorted()
        if mergedDates.count > 100 {
            mergedDates.removeFirst(mergedDates.count - 100)
        }
        
        let streak = calculateStreak(from: mergedDates, relativeTo: date)
        
        if mergedDates != localDates {
            save(dates: mergedDates, streak: streak)
        }
        
        return StreakInfo(currentStreak: streak, activityDates: mergedDates)
    }
    
    public static func calculateStreak(from dates: [String], relativeTo referenceDate: Date = .now) -> Int {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        
        let todayStr = formatter.string(from: referenceDate)
        guard let today = formatter.date(from: todayStr) else { return 0 }
        
        let calendar = Calendar.current
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return 0 }
        let yesterdayStr = formatter.string(from: yesterday)
        
        let dateSet = Set(dates)
        let hasReadToday = dateSet.contains(todayStr)
        let hasReadYesterday = dateSet.contains(yesterdayStr)
        
        guard hasReadToday || hasReadYesterday else {
            return 0
        }
        
        var streak = 0
        var checkDate = hasReadToday ? today : yesterday
        
        while true {
            let checkStr = formatter.string(from: checkDate)
            if dateSet.contains(checkStr) {
                streak += 1
                guard let nextCheck = calendar.date(byAdding: .day, value: -1, to: checkDate) else { break }
                checkDate = nextCheck
            } else {
                break
            }
        }
        
        return streak
    }

    /// The seven days ending on `referenceDate`'s day, oldest first, so today is
    /// the last dot. A rolling window rather than the calendar week, so "Read N
    /// of last 7 days" counts what it says and never shows future days.
    public static func getLast7DaysActivity(from dates: [String], relativeTo referenceDate: Date = .now) -> [WeekdayActivity] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        
        let calendar = Calendar.current
        let dateSet = Set(dates)
        var activities: [WeekdayActivity] = []
        
        let dayNameFormatter = DateFormatter()
        dayNameFormatter.dateFormat = "EEEEE"
        dayNameFormatter.timeZone = TimeZone.current
        
        // Noon avoids a DST change skipping or repeating a day.
        let today = calendar.startOfDay(for: referenceDate)
        let anchor = calendar.date(byAdding: .hour, value: 12, to: today) ?? today
        
        for offset in -6...0 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: anchor) else { continue }
            let dateStr = formatter.string(from: date)
            activities.append(WeekdayActivity(
                name: dayNameFormatter.string(from: date),
                fullName: calendar.standaloneWeekdaySymbols[calendar.component(.weekday, from: date) - 1],
                isToday: offset == 0,
                isRead: dateSet.contains(dateStr)
            ))
        }
        
        return activities
    }

    /// The start of the day after `date`, when the widget's "today" and
    /// streak next change.
    public static func nextMidnight(after date: Date = .now) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: today) ?? date.addingTimeInterval(24 * 60 * 60)
    }
    
    public static func installCloudSyncObserver() {
        guard cloudObserver == nil else { return }
        _ = NSUbiquitousKeyValueStore.default.synchronize()
        syncCloudToLocal()
        
        cloudObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default,
            queue: .main
        ) { _ in
            syncCloudToLocal()
        }
    }
    
    public static func syncCloudToLocal() {
        _ = loadStreakInfo()
        reloadWidgets()
    }
    
    private static func save(dates: [String], streak: Int) {
        writeLocal(dates: dates, streak: streak)
        writeCloud(dates: dates, streak: streak)
        reloadWidgets()
    }
    
    private static func writeLocal(dates: [String], streak: Int) {
        let sharedDefaults = UserDefaults(suiteName: appGroupIdentifier)
        sharedDefaults?.set(dates, forKey: activityDatesKey)
        sharedDefaults?.set(streak, forKey: currentStreakKey)
        
        UserDefaults.standard.set(dates, forKey: activityDatesKey)
        UserDefaults.standard.set(streak, forKey: currentStreakKey)
    }
    
    private static func readDatesLocal() -> [String] {
        let sharedDates = UserDefaults(suiteName: appGroupIdentifier)?.stringArray(forKey: activityDatesKey)
        let standardDates = UserDefaults.standard.stringArray(forKey: activityDatesKey)
        
        return sharedDates ?? standardDates ?? []
    }
    
    private static func readDatesCloud() -> [String] {
        NSUbiquitousKeyValueStore.default.array(forKey: activityDatesKey) as? [String] ?? []
    }
    
    private static func writeCloud(dates: [String], streak: Int) {
        cloudSaveTask?.cancel()
        cloudSaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            
            NSUbiquitousKeyValueStore.default.set(dates, forKey: activityDatesKey)
            NSUbiquitousKeyValueStore.default.set(streak, forKey: currentStreakKey)
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }
    
    private static func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
