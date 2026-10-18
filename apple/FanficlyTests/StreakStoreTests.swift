import XCTest
@testable import Fanficly

final class StreakStoreTests: XCTestCase {
    
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()
    
    private func date(from str: String) -> Date {
        return formatter.date(from: str)!
    }
    
    func test_calculateStreak_emptyDates() {
        let reference = date(from: "2026-06-11")
        let result = StreakStore.calculateStreak(from: [], relativeTo: reference)
        XCTAssertEqual(result, 0)
    }
    
    func test_calculateStreak_onlyToday() {
        let reference = date(from: "2026-06-11")
        let result = StreakStore.calculateStreak(from: ["2026-06-11"], relativeTo: reference)
        XCTAssertEqual(result, 1)
    }
    
    func test_calculateStreak_onlyYesterday() {
        let reference = date(from: "2026-06-11")
        let result = StreakStore.calculateStreak(from: ["2026-06-10"], relativeTo: reference)
        XCTAssertEqual(result, 1)
    }
    
    func test_calculateStreak_onlyTwoDaysAgo() {
        let reference = date(from: "2026-06-11")
        let result = StreakStore.calculateStreak(from: ["2026-06-09"], relativeTo: reference)
        XCTAssertEqual(result, 0) // Streak is broken
    }
    
    func test_calculateStreak_consecutiveDays() {
        let reference = date(from: "2026-06-11")
        
        // Contiguous including today
        let result1 = StreakStore.calculateStreak(from: ["2026-06-09", "2026-06-10", "2026-06-11"], relativeTo: reference)
        XCTAssertEqual(result1, 3)
        
        // Contiguous ending yesterday
        let result2 = StreakStore.calculateStreak(from: ["2026-06-09", "2026-06-10"], relativeTo: reference)
        XCTAssertEqual(result2, 2)
        
        // Skipped day breaks the streak
        let result3 = StreakStore.calculateStreak(from: ["2026-06-08", "2026-06-10", "2026-06-11"], relativeTo: reference)
        XCTAssertEqual(result3, 2) // June 9 was skipped
    }
    
    func test_getLast7DaysActivity() {
        let reference = date(from: "2026-06-11") // June 11, 2026 is a Thursday
        let dates = ["2026-06-11", "2026-06-10", "2026-06-08"] // Read Thursday, Wednesday, Monday. Skipped Tuesday, Sunday, Saturday, Friday.
        
        let activities = StreakStore.getLast7DaysActivity(from: dates, relativeTo: reference)
        
        XCTAssertEqual(activities.count, 7)
        
        let calendar = Calendar.current
        let firstWeekday = calendar.firstWeekday
        
        if firstWeekday == 1 { // Sunday start
            // Days: Sun 7, Mon 8, Tue 9, Wed 10, Thu 11, Fri 12, Sat 13
            // index 0: Sun (isToday: false, isRead: false)
            XCTAssertFalse(activities[0].isToday)
            XCTAssertFalse(activities[0].isRead)
            XCTAssertEqual(activities[0].name, "S")
            
            // index 1: Mon (isToday: false, isRead: true)
            XCTAssertFalse(activities[1].isToday)
            XCTAssertTrue(activities[1].isRead)
            XCTAssertEqual(activities[1].name, "M")
            
            // index 3: Wed (isToday: false, isRead: true)
            XCTAssertFalse(activities[3].isToday)
            XCTAssertTrue(activities[3].isRead)
            XCTAssertEqual(activities[3].name, "W")
            
            // index 4: Thu (isToday: true, isRead: true)
            XCTAssertTrue(activities[4].isToday)
            XCTAssertTrue(activities[4].isRead)
            XCTAssertEqual(activities[4].name, "T")
        } else if firstWeekday == 2 { // Monday start
            // Days: Mon 8, Tue 9, Wed 10, Thu 11, Fri 12, Sat 13, Sun 14
            // index 0: Mon (isToday: false, isRead: true)
            XCTAssertFalse(activities[0].isToday)
            XCTAssertTrue(activities[0].isRead)
            XCTAssertEqual(activities[0].name, "M")
            
            // index 2: Wed (isToday: false, isRead: true)
            XCTAssertFalse(activities[2].isToday)
            XCTAssertTrue(activities[2].isRead)
            XCTAssertEqual(activities[2].name, "W")
            
            // index 3: Thu (isToday: true, isRead: true)
            XCTAssertTrue(activities[3].isToday)
            XCTAssertTrue(activities[3].isRead)
            XCTAssertEqual(activities[3].name, "T")
        } else {
            // General assertion: there must be exactly one today
            let todayCount = activities.filter(\.isToday).count
            XCTAssertEqual(todayCount, 1)
        }
    }
}
