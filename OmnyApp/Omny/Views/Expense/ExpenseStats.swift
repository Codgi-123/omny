import Foundation
import SwiftUI
import OmnyCore

// MARK: - 统计周期（数据统计页顶部 tab）

/// 数据统计的时间区间维度：周 / 月 / 年 / 全部 / 自定义（issue #28 三）。
enum StatsPeriod: String, CaseIterable, Identifiable {
    case week = "周", month = "月", year = "年", all = "全部", custom = "自定义"
    var id: String { rawValue }

    /// 是否支持 < > 整体平移（全部/自定义没有「上一个/下一个」语义）
    var isSteppable: Bool { self == .week || self == .month || self == .year }
}

// MARK: - 解析后的时间窗口

/// 由周期 + 锚点日期解析出的具体统计窗口：区间 + 标签 + 天数（供日均计算）。
struct StatsWindow {
    let interval: DateInterval    // [start, end)
    let label: String            // 中间那行显示的周期文字
    let dayCount: Int            // 区间跨的天数（日均支出用）
}

// MARK: - 统计计算

/// 记账统计计算：把「周期 + 锚点」解析成窗口，再按窗口过滤 + 聚合。
/// 复用 `ExpenseSummary` 做总额/大类/细分聚合，这里只补时间维度与折线序列。
enum ExpenseStats {
    /// 周一起排、zh_CN 锁死，与 MonthCalendarView 一致
    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = Locale(identifier: "zh_CN")
        c.firstWeekday = 2
        return c
    }

    static func effectiveDate(_ item: InboxItem) -> Date { item.occurredAt ?? item.createdAt }

    /// 解析时间窗口。`allItems` 只在 `.all` 时用于取首尾日期。
    static func window(period: StatsPeriod, anchor: Date,
                       customStart: Date, customEnd: Date,
                       allItems: [InboxItem]) -> StatsWindow {
        let cal = calendar
        switch period {
        case .week:
            let interval = cal.dateInterval(of: .weekOfYear, for: anchor)
                ?? DateInterval(start: cal.startOfDay(for: anchor), duration: 7 * 86400)
            let last = cal.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
            return StatsWindow(interval: interval, label: weekLabel(interval.start, last), dayCount: 7)
        case .month:
            let interval = cal.dateInterval(of: .month, for: anchor)
                ?? DateInterval(start: anchor, duration: 30 * 86400)
            let days = cal.range(of: .day, in: .month, for: anchor)?.count ?? 30
            return StatsWindow(interval: interval, label: OmnyDateFormat.monthTitle(anchor), dayCount: days)
        case .year:
            let interval = cal.dateInterval(of: .year, for: anchor)
                ?? DateInterval(start: anchor, duration: 365 * 86400)
            return StatsWindow(interval: interval, label: OmnyDateFormat.yearTitle(anchor), dayCount: dayCount(interval))
        case .all:
            let dates = allItems.map(effectiveDate).sorted()
            let start = dates.first.map { cal.startOfDay(for: $0) } ?? cal.startOfDay(for: anchor)
            let endDay = dates.last.map { cal.startOfDay(for: $0) } ?? cal.startOfDay(for: anchor)
            let end = cal.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            let interval = DateInterval(start: start, end: max(end, start))
            let label = "\(OmnyDateFormat.fullDay(start)) - \(OmnyDateFormat.fullDay(endDay))"
            return StatsWindow(interval: interval, label: label, dayCount: max(1, dayCount(interval)))
        case .custom:
            let s = cal.startOfDay(for: min(customStart, customEnd))
            let eDay = cal.startOfDay(for: max(customStart, customEnd))
            let end = cal.date(byAdding: .day, value: 1, to: eDay) ?? eDay
            let interval = DateInterval(start: s, end: max(end, s))
            let label = "\(OmnyDateFormat.fullDay(s)) - \(OmnyDateFormat.fullDay(eDay))"
            return StatsWindow(interval: interval, label: label, dayCount: max(1, dayCount(interval)))
        }
    }

    /// < > 平移锚点（仅 week/month/year）
    static func shiftAnchor(_ period: StatsPeriod, anchor: Date, by dir: Int) -> Date {
        let cal = calendar
        let comp: Calendar.Component
        switch period {
        case .week: comp = .weekOfYear
        case .month: comp = .month
        case .year: comp = .year
        default: return anchor
        }
        return cal.date(byAdding: comp, value: dir, to: anchor) ?? anchor
    }

    /// 落在窗口内的记账
    static func filter(_ items: [InboxItem], in window: StatsWindow) -> [InboxItem] {
        items.filter { window.interval.contains(effectiveDate($0)) }
    }

    // MARK: 折线序列

    /// 折线图数据点：日期 + 横轴标签 + 当期收支
    struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let label: String
        let expense: Decimal
        let income: Decimal
        var balance: Decimal { income - expense }
    }

    /// 折线序列：周/月/自定义按天铺满整个区间（空档补 0），年按月（12 点）。
    static func series(_ items: [InboxItem], period: StatsPeriod, window: StatsWindow) -> [Point] {
        let cal = calendar
        let inWindow = filter(items, in: window)
        if period == .year {
            var buckets: [Int: (e: Decimal, i: Decimal)] = [:]
            for it in inWindow {
                let m = cal.component(.month, from: effectiveDate(it))
                var b = buckets[m] ?? (0, 0)
                if it.expenseDirection == .income { b.i += it.amount ?? 0 } else { b.e += it.amount ?? 0 }
                buckets[m] = b
            }
            let year = cal.component(.year, from: window.interval.start)
            return (1...12).map { m in
                let b = buckets[m] ?? (0, 0)
                var c = DateComponents(); c.year = year; c.month = m; c.day = 1
                return Point(date: cal.date(from: c) ?? window.interval.start,
                             label: "\(m)月", expense: b.e, income: b.i)
            }
        } else {
            var buckets: [Date: (e: Decimal, i: Decimal)] = [:]
            for it in inWindow {
                let d = cal.startOfDay(for: effectiveDate(it))
                var b = buckets[d] ?? (0, 0)
                if it.expenseDirection == .income { b.i += it.amount ?? 0 } else { b.e += it.amount ?? 0 }
                buckets[d] = b
            }
            var points: [Point] = []
            var day = cal.startOfDay(for: window.interval.start)
            while day < window.interval.end {
                let b = buckets[day] ?? (0, 0)
                points.append(Point(date: day, label: "\(cal.component(.day, from: day))",
                                    expense: b.e, income: b.i))
                guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            return points
        }
    }

    // MARK: 内部

    private static func dayCount(_ interval: DateInterval) -> Int {
        max(1, Int((interval.duration / 86400).rounded()))
    }

    /// 周区间标签：同月「7月13日-19日」，跨月「7月28日-8月3日」
    private static func weekLabel(_ start: Date, _ end: Date) -> String {
        let cal = calendar
        let y = OmnyDateFormat.yearTitle(start)
        let sameMonth = cal.isDate(start, equalTo: end, toGranularity: .month)
        if sameMonth {
            let d = cal.component(.day, from: end)
            return "\(y)\(OmnyDateFormat.monthDay(start))-\(d)日"
        }
        return "\(y)\(OmnyDateFormat.monthDay(start))-\(OmnyDateFormat.monthDay(end))"
    }
}
