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
        let dates = ["2026-06-11", "2026-06-10", "2026-06-08", "2026-06-04"] // Thu, Wed, Mon, and the Thursday before (outside the window)
        
        let activities = StreakStore.getLast7DaysActivity(from: dates, relativeTo: reference)
        
        // The rolling seven days ending today: Fri 5 … Thu 11, whatever the
        // calendar's first weekday, with no future days.
        XCTAssertEqual(activities.count, 7)
        XCTAssertEqual(activities.map(\.isRead), [false, false, false, true, false, true, true])
        XCTAssertEqual(activities.map(\.isToday), [false, false, false, false, false, false, true])
        XCTAssertEqual(activities.first?.fullName, "Friday")
        XCTAssertEqual(activities.first?.name, "F")
        XCTAssertEqual(activities.last?.fullName, "Thursday")
        XCTAssertEqual(activities.last?.name, "T")
    }
    
    func test_getLast7DaysActivity_mondayCountsTheWholeWeek() {
        // Issue #200: on a Monday after a week of daily reading, the calendar
        // week read "1 of last 7 days".
        let reference = date(from: "2026-06-15") // Monday
        let dates = ["2026-06-09", "2026-06-10", "2026-06-11", "2026-06-12", "2026-06-13", "2026-06-14", "2026-06-15"]
        let activities = StreakStore.getLast7DaysActivity(from: dates, relativeTo: reference)
        XCTAssertEqual(activities.filter(\.isRead).count, 7)
        XCTAssertTrue(activities.last?.isToday ?? false)
    }
    
    func test_getLast7DaysActivity_lateEveningKeepsToday() {
        let reference = date(from: "2026-06-11").addingTimeInterval(23 * 60 * 60 + 59 * 60)
        let activities = StreakStore.getLast7DaysActivity(from: ["2026-06-11"], relativeTo: reference)
        XCTAssertTrue(activities.last?.isRead ?? false)
        XCTAssertTrue(activities.last?.isToday ?? false)
    }
    
    func test_nextMidnight() {
        let evening = date(from: "2026-06-11").addingTimeInterval(22 * 60 * 60)
        XCTAssertEqual(StreakStore.nextMidnight(after: evening), date(from: "2026-06-12"))
        XCTAssertEqual(StreakStore.nextMidnight(after: date(from: "2026-06-11")), date(from: "2026-06-12"))
    }
    
    func test_streakLapsesAtMidnight() {
        // Read Tuesday and Wednesday, not Thursday: Thursday still shows 2,
        // Friday's midnight entry shows 0.
        let dates = ["2026-06-09", "2026-06-10"]
        XCTAssertEqual(StreakStore.calculateStreak(from: dates, relativeTo: date(from: "2026-06-11")), 2)
        let midnight = StreakStore.nextMidnight(after: date(from: "2026-06-11"))
        XCTAssertEqual(StreakStore.calculateStreak(from: dates, relativeTo: midnight), 0)
    }
}
