import Foundation

public struct DayGroup<Item> {
    /// Start of the day.
    public let day: Date
    public let items: [Item]
}

/// Splits newest-first lists (history) into per-day sections.
public enum DayGrouping {
    /// Groups consecutive items that fall on the same calendar day, keeping order.
    public static func group<Item>(_ items: [Item], calendar: Calendar = .current, date: (Item) -> Date) -> [DayGroup<Item>] {
        var groups: [DayGroup<Item>] = []
        var day: Date?
        var current: [Item] = []
        for item in items {
            let start = calendar.startOfDay(for: date(item))
            if start != day {
                if let day { groups.append(DayGroup(day: day, items: current)) }
                day = start
                current = []
            }
            current.append(item)
        }
        if let day { groups.append(DayGroup(day: day, items: current)) }
        return groups
    }

    /// "今天", "昨天", "10月18日", or with the year when it is not this year.
    public static func label(for day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "今天" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "昨天"
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let monthDay = "\(parts.month ?? 0)月\(parts.day ?? 0)日"
        if parts.year == calendar.component(.year, from: now) { return monthDay }
        return "\(parts.year ?? 0)年\(monthDay)"
    }
}
