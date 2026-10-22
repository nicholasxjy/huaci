import Foundation
import Testing
@testable import HuaciCore

struct DayGroupingTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    @Test func groupsConsecutiveItemsByCalendarDay() {
        let items = [date(2026, 10, 22, 14), date(2026, 10, 22, 9), date(2026, 10, 21, 23), date(2026, 10, 18)]
        let groups = DayGrouping.group(items, calendar: calendar) { $0 }

        #expect(groups.map(\.items.count) == [2, 1, 1])
        #expect(groups.map(\.day) == [date(2026, 10, 22, 0), date(2026, 10, 21, 0), date(2026, 10, 18, 0)])
    }

    @Test func labelsRecentDaysByName() {
        let now = date(2026, 10, 22, 8)
        #expect(DayGrouping.label(for: date(2026, 10, 22, 0), now: now, calendar: calendar) == "今天")
        #expect(DayGrouping.label(for: date(2026, 10, 21, 0), now: now, calendar: calendar) == "昨天")
        #expect(DayGrouping.label(for: date(2026, 10, 18, 0), now: now, calendar: calendar) == "10月18日")
        #expect(DayGrouping.label(for: date(2025, 12, 31, 0), now: now, calendar: calendar) == "2025年12月31日")
    }
}
