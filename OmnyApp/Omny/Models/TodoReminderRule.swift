import Foundation

/// 待办提醒规则：相对截止时间的提前分钟数。
/// rawValue 直接持久化进 InboxItem.todoReminderMinutes 与 AppSettings.todoDefaultReminderMinutes：
/// -1 不提醒 / 0 准时 / 其余为提前 N 分钟。
enum TodoReminderRule: Int, CaseIterable, Identifiable {
    case none = -1        // 不提醒
    case onTime = 0       // 准时
    case before5m = 5
    case before15m = 15   // 全局默认
    case before30m = 30
    case before1h = 60
    case before1d = 1440

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none: return "不提醒"
        case .onTime: return "准时"
        case .before5m: return "提前 5 分钟"
        case .before15m: return "提前 15 分钟"
        case .before30m: return "提前 30 分钟"
        case .before1h: return "提前 1 小时"
        case .before1d: return "提前 1 天"
        }
    }
}
