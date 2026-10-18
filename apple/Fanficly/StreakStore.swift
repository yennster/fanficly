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
    public let name: String
    public let isToday: Bool
    public let isRead: Bool
    
    public init(id: UUID = UUID(), name: String, isToday: Bool, isRead: Bool) {
        self.id = id
        self.name = name
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

    public static func getLast7DaysActivity(from dates: [String], relativeTo referenceDate: Date = .now) -> [WeekdayActivity] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        
        let calendar = Calendar.current
        var activities: [WeekdayActivity] = []
        
        let dayNameFormatter = DateFormatter()
        dayNameFormatter.dateFormat = "EEEEE"
        dayNameFormatter.timeZone = TimeZone.current
        
        let todayStr = formatter.string(from: referenceDate)
        
        // Find the start of the week for the referenceDate respecting the calendar settings (firstWeekday)
        var startOfWeek = referenceDate
        var interval: TimeInterval = 0
        if !calendar.dateInterval(of: .weekOfYear, start: &startOfWeek, interval: &interval, for: referenceDate) {
            // Fallback: manually calculate start of week based on firstWeekday
            let currentWeekday = calendar.component(.weekday, from: referenceDate)
            let firstWeekday = calendar.firstWeekday
            let offset = (currentWeekday - firstWeekday + 7) % 7
            startOfWeek = calendar.date(byAdding: .day, value: -offset, to: referenceDate) ?? referenceDate
        }
        
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: startOfWeek) else { continue }
            let dateStr = formatter.string(from: date)
            let isRead = dates.contains(dateStr)
            let isToday = (dateStr == todayStr)
            let name = dayNameFormatter.string(from: date)
            activities.append(WeekdayActivity(name: name, isToday: isToday, isRead: isRead))
        }
        
        return activities
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
