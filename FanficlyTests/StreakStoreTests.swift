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
        
        // The last item (offset 0) must be today (Thursday, June 11)
        let todayActivity = activities[6]
        XCTAssertTrue(todayActivity.isToday)
        XCTAssertTrue(todayActivity.isRead)
        XCTAssertEqual(todayActivity.name, "T") // "T" for Thursday (single letter EEEEE)
        
        // Offset -1 is Wednesday, June 10
        let wednesdayActivity = activities[5]
        XCTAssertFalse(wednesdayActivity.isToday)
        XCTAssertTrue(wednesdayActivity.isRead)
        XCTAssertEqual(wednesdayActivity.name, "W")
        
        // Offset -2 is Tuesday, June 9
        let tuesdayActivity = activities[4]
        XCTAssertFalse(tuesdayActivity.isToday)
        XCTAssertFalse(tuesdayActivity.isRead)
        XCTAssertEqual(tuesdayActivity.name, "T")
        
        // Offset -3 is Monday, June 8
        let mondayActivity = activities[3]
        XCTAssertFalse(mondayActivity.isToday)
        XCTAssertTrue(mondayActivity.isRead)
        XCTAssertEqual(mondayActivity.name, "M")
        
        // Offset -4 is Sunday, June 7
        let sundayActivity = activities[2]
        XCTAssertFalse(sundayActivity.isToday)
        XCTAssertFalse(sundayActivity.isRead)
        XCTAssertEqual(sundayActivity.name, "S")
    }
}
