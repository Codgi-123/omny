import Foundation

/// 待办重复规则。持久化为短字符串（InboxItem.todoRepeatRule）：
/// d:1 每天 / d:3 每 3 天 / w:1:4 每周的周四 / w:2:1,4 每 2 周的周一和周四 /
/// m:1:16 每月 16 日 / m:1:1,15 每月 1、15 日 / y:1:7-16 每年 7 月 16 日 / weekday 工作日（周一~周五）
public enum TodoRepeatRule: Equatable, Sendable {
    case daily(interval: Int)
    case weekly(interval: Int, weekdays: Set<Int>)   // weekdays: 1=周一 … 7=周日，非空
    case monthly(interval: Int, days: Set<Int>)      // days: 1...31，非空（与 weekly 对称的多选）
    case yearly(interval: Int, month: Int, day: Int)
    case weekdays                                    // 工作日：周一~周五

    // MARK: - 解析

    /// 解析持久化字符串，非法返回 nil（interval<1、星期集合为空/越界、月日越界等都算非法）
    public static func parse(_ raw: String) -> TodoRepeatRule? {
        if raw == "weekday" { return .weekdays }

        // components(separatedBy:) 保留空段，"d:"、"w:1:" 这类残缺输入会自然解析失败
        let parts = raw.components(separatedBy: ":")
        switch parts.first {
        case "d":
            guard parts.count == 2,
                  let interval = positiveInt(parts[1]) else { return nil }
            return .daily(interval: interval)
        case "w":
            guard parts.count == 3,
                  let interval = positiveInt(parts[1]) else { return nil }
            let fields = parts[2].components(separatedBy: ",")
            var weekdays = Set<Int>()
            for field in fields {
                guard let wd = positiveInt(field), (1...7).contains(wd) else { return nil }
                weekdays.insert(wd)
            }
            guard !weekdays.isEmpty else { return nil }
            return .weekly(interval: interval, weekdays: weekdays)
        case "m":
            guard parts.count == 3,
                  let interval = positiveInt(parts[1]) else { return nil }
            let fields = parts[2].components(separatedBy: ",")
            var days = Set<Int>()
            for field in fields {
                guard let d = positiveInt(field), (1...31).contains(d) else { return nil }
                days.insert(d)
            }
            guard !days.isEmpty else { return nil }
            return .monthly(interval: interval, days: days)
        case "y":
            guard parts.count == 3,
                  let interval = positiveInt(parts[1]) else { return nil }
            let md = parts[2].components(separatedBy: "-")
            guard md.count == 2,
                  let month = positiveInt(md[0]), (1...12).contains(month),
                  let day = positiveInt(md[1]),
                  day <= Self.maxDayOfMonth[month - 1] else { return nil }
            return .yearly(interval: interval, month: month, day: day)
        default:
            return nil
        }
    }

    /// 各月最大天数（2 月按闰年 29 计，只用于 parse 时排除"永远不存在"的日期如 2-30）
    private static let maxDayOfMonth = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    /// 严格的正整数解析：只接受纯 ASCII 数字（拒绝 "+3"、" 3"、空串），且 >= 1
    private static func positiveInt(_ s: String) -> Int? {
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }),
              let n = Int(s), n >= 1 else { return nil }
        return n
    }

    // MARK: - 编码

    /// 编码回持久化字符串（与 parse 严格互逆；weekdays 集合升序输出保证稳定）
    public var encoded: String {
        switch self {
        case .daily(let interval):
            return "d:\(interval)"
        case .weekly(let interval, let weekdays):
            return "w:\(interval):" + weekdays.sorted().map(String.init).joined(separator: ",")
        case .monthly(let interval, let days):
            return "m:\(interval):" + days.sorted().map(String.init).joined(separator: ",")
        case .yearly(let interval, let month, let day):
            return "y:\(interval):\(month)-\(day)"
        case .weekdays:
            return "weekday"
        }
    }

    // MARK: - 展示文案

    private static let weekdayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    /// 展示文案："每天"/"每 3 天"/"每周的周四"/"每 2 周的周一、周四"/"每月 16 日"/"每年 7 月 16 日"/"工作日"
    /// interval == 1 时省略数字（"每周的周四"而非"每 1 周的周四"）
    public var label: String {
        switch self {
        case .daily(let interval):
            return interval == 1 ? "每天" : "每 \(interval) 天"
        case .weekly(let interval, let weekdays):
            let names = weekdays.sorted().map { Self.weekdayNames[$0 - 1] }.joined(separator: "、")
            return (interval == 1 ? "每周的" : "每 \(interval) 周的") + names
        case .monthly(let interval, let days):
            let names = days.sorted().map(String.init).joined(separator: "、")
            return (interval == 1 ? "每月" : "每 \(interval) 个月") + " \(names) 日"
        case .yearly(let interval, let month, let day):
            return (interval == 1 ? "每年" : "每 \(interval) 年") + " \(month) 月 \(day) 日"
        case .weekdays:
            return "工作日"
        }
    }

    // MARK: - 推算下一次到期

    /// 从当前截止时间推下一次到期（严格晚于 due），保留 due 的时分秒。
    public func next(after due: Date, calendar: Calendar) -> Date {
        switch self {
        case .daily(let interval):
            return calendar.date(byAdding: .day, value: interval, to: due)!

        case .weekly(let interval, let weekdays):
            // 本规则的"周"固定以周一为起点，与 calendar.firstWeekday 无关
            let dueWd = Self.mondayBasedWeekday(of: due, calendar: calendar)
            if let sameWeek = weekdays.filter({ $0 > dueWd }).min() {
                // 本周内还有晚于 due 的已选星期
                return calendar.date(byAdding: .day, value: sameWeek - dueWd, to: due)!
            }
            // 跳到 interval 周后的那一周，取最早的已选星期
            let firstWd = weekdays.min()!
            let days = interval * 7 - dueWd + firstWd
            return calendar.date(byAdding: .day, value: days, to: due)!

        case .monthly(let interval, let days):
            let time = calendar.dateComponents([.hour, .minute, .second], from: due)
            // 当月内还有严格晚于 due 的已选日（clamp 到当月天数）就先取当月（与 weekly 同构）
            if let sameMonth = Self.earliestDay(days, inMonthOf: due, strictlyAfter: due,
                                                timeOf: time, calendar: calendar) {
                return sameMonth
            }
            // 跳到 interval 个月后的那个月，取最早的已选日；
            // 先锚到当月 1 日再加月，避免 31 日加月被系统 clamp 污染规则本身
            var comps = calendar.dateComponents([.year, .month], from: due)
            comps.day = 1
            let anchor = calendar.date(from: comps)!
            let shifted = calendar.date(byAdding: .month, value: interval, to: anchor)!
            return Self.earliestDay(days, inMonthOf: shifted, strictlyAfter: nil,
                                    timeOf: time, calendar: calendar)!

        case .yearly(let interval, let month, let day):
            let time = calendar.dateComponents([.hour, .minute, .second], from: due)
            var comps = calendar.dateComponents([.year], from: due)
            comps.month = month
            comps.day = 1
            // 今年的目标日还没过就先取今年（与 weekly/monthly 同构）
            let thisYear = calendar.date(from: comps)!
            let candidate = Self.compose(yearMonth: thisYear, day: day, timeOf: time, calendar: calendar)
            if candidate > due { return candidate }
            comps.year! += interval
            let anchor = calendar.date(from: comps)!
            return Self.compose(yearMonth: anchor, day: day, timeOf: time, calendar: calendar)

        case .weekdays:
            let dueWd = Self.mondayBasedWeekday(of: due, calendar: calendar)
            // 周五(5)/周六(6)/周日(7) → 下周一；周一~周四 → 明天
            let days = dueWd >= 5 ? 8 - dueWd : 1
            return calendar.date(byAdding: .day, value: days, to: due)!
        }
    }

    /// 完成/补勾场景：从 due 反复推进直到严格晚于 now（跳过错过的期次）。now <= due 时等价 next(after: due)。
    public func nextOccurrence(from due: Date, now: Date, calendar: Calendar) -> Date {
        var date = next(after: due, calendar: calendar)
        while date <= now {
            date = next(after: date, calendar: calendar)
        }
        return date
    }

    // MARK: - 私有工具

    /// 周一为 1、周日为 7 的星期序号（Calendar 原生 weekday 是周日为 1）
    private static func mondayBasedWeekday(of date: Date, calendar: Calendar) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }

    /// monthRef 所在月里，把各选中日 clamp 到当月天数后的候选日期中，
    /// 严格晚于 after 的最早一个（after == nil 则直接取最早）。days 非空时 after == nil 必有解。
    private static func earliestDay(_ days: Set<Int>, inMonthOf monthRef: Date, strictlyAfter after: Date?,
                                    timeOf: DateComponents, calendar: Calendar) -> Date? {
        let daysInMonth = calendar.range(of: .day, in: .month, for: monthRef)!.count
        var comps = calendar.dateComponents([.year, .month], from: monthRef)
        comps.hour = timeOf.hour
        comps.minute = timeOf.minute
        comps.second = timeOf.second
        var best: Date?
        for day in days {
            comps.day = min(day, daysInMonth)
            guard let candidate = calendar.date(from: comps) else { continue }
            if let after, candidate <= after { continue }
            if best == nil || candidate < best! { best = candidate }
        }
        return best
    }

    /// 在 yearMonth 所在的年月里落到 day 日（当月没有则 clamp 为最后一天），时分秒取 timeOf。
    private static func compose(yearMonth: Date, day: Int, timeOf: DateComponents, calendar: Calendar) -> Date {
        let daysInMonth = calendar.range(of: .day, in: .month, for: yearMonth)!.count
        var comps = calendar.dateComponents([.year, .month], from: yearMonth)
        comps.day = min(day, daysInMonth)
        comps.hour = timeOf.hour
        comps.minute = timeOf.minute
        comps.second = timeOf.second
        return calendar.date(from: comps)!
    }
}
