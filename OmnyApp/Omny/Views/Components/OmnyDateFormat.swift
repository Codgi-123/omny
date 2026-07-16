import Foundation

// MARK: - 中文日期显示格式化（共享 DateFormatter 实例）

/// 全局中文日期显示格式化。DateFormatter 创建开销大，原先记账明细/日历/详情/分析、
/// 待办日期选择器、确认记账弹窗各自「每次调用 new 一个」，收敛到这里的静态实例复用
/// （NSDateFormatter 自 iOS 7 起线程安全，静态共享无虞）。
/// 注：只收敛 DateFormatter 型的固定格式。基于 FormatStyle 的相对时间/截止时间辅助
/// （今天/明天、带不带星期等变体）语义各异且开销小，仍留在各调用点。
enum OmnyDateFormat {
    /// 「2026年7月」——记账月份切换标题、待办日期选择器的月历标题
    static func monthTitle(_ date: Date) -> String { monthTitleFormatter.string(from: date) }

    /// 「7月14日 星期二」——记账明细/日历的日分组头
    static func dayWithWeekday(_ date: Date) -> String { dayWithWeekdayFormatter.string(from: date) }

    /// 「2026年7月14日 08:30」——记账详情的完整时间
    static func fullDateTime(_ date: Date) -> String { fullDateTimeFormatter.string(from: date) }

    /// 「7月14日 08:30」——「确认记账」弹窗的时间行
    static func monthDayTime(_ date: Date) -> String { monthDayTimeFormatter.string(from: date) }

    /// 「7-14」——分析页凭据行的紧凑日期
    static func shortMonthDay(_ date: Date) -> String { shortMonthDayFormatter.string(from: date) }

    /// 「17:24」——记账明细行的时刻
    static func timeHM(_ date: Date) -> String { timeHMFormatter.string(from: date) }

    /// 「2026年」——数据统计「年」周期标题
    static func yearTitle(_ date: Date) -> String { yearTitleFormatter.string(from: date) }

    /// 「2026年7月13日」——数据统计周期区间端点、自定义区间日期按钮
    static func fullDay(_ date: Date) -> String { fullDayFormatter.string(from: date) }

    /// 「7月13日」——周区间标签
    static func monthDay(_ date: Date) -> String { monthDayFormatter.string(from: date) }

    // MARK: 静态实例（zh_CN 锁死，避免跟随系统语言变脸）

    private static let monthTitleFormatter = make("yyyy年M月")
    private static let dayWithWeekdayFormatter = make("M月d日 EEEE")
    private static let fullDateTimeFormatter = make("yyyy年M月d日 HH:mm")
    private static let monthDayTimeFormatter = make("M月d日 HH:mm")
    private static let shortMonthDayFormatter = make("M-d")
    private static let timeHMFormatter = make("HH:mm")
    private static let yearTitleFormatter = make("yyyy年")
    private static let fullDayFormatter = make("yyyy年M月d日")
    private static let monthDayFormatter = make("M月d日")

    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = format
        return f
    }
}
