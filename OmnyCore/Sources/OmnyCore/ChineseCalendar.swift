import Foundation

/// 中国日历辅助：农历日名、24 节气、公历/农历节日。给自绘月历提供每一格的副标题。
///
/// - 农历：走 Foundation 的 `Calendar(identifier: .chinese)`，可靠且随系统更新。
/// - 节气：用「寿星通用公式」按年计算当月两个节气的日号（1900–2100 适用，个别年份可能 ±1 天）。
/// - 节日：公历固定日 + 农历固定日查表（含除夕＝正月初一前一天）。
public struct ChineseCalendar {
    private let gregorian: Calendar
    private let chinese: Calendar

    public init() {
        var g = Calendar(identifier: .gregorian)
        g.locale = Locale(identifier: "zh_CN")
        self.gregorian = g
        self.chinese = Calendar(identifier: .chinese)
    }

    // MARK: 对外：整合每格显示

    /// 一格日历的副标题：优先级 节日 > 节气 > 农历月首(初一显示月名) > 农历日名。
    public func annotation(for date: Date) -> DayAnnotation {
        if let f = festival(for: date) { return DayAnnotation(text: f, kind: .festival) }
        if let t = solarTerm(for: date) { return DayAnnotation(text: t, kind: .solarTerm) }
        let (_, day, _) = lunarComponents(of: date)
        if day == 1 { return DayAnnotation(text: lunarMonthName(of: date), kind: .lunarMonth) }
        return DayAnnotation(text: Self.lunarDayName(day), kind: .lunarDay)
    }

    // MARK: 农历

    /// 农历短名：初一那天返回月名（如「六月」/「闰四月」），其余返回日名（如「廿七」）。
    public func lunarShort(for date: Date) -> String {
        let (_, day, _) = lunarComponents(of: date)
        return day == 1 ? lunarMonthName(of: date) : Self.lunarDayName(day)
    }

    private func lunarComponents(of date: Date) -> (month: Int, day: Int, leap: Bool) {
        let c = chinese.dateComponents([.month, .day], from: date)
        return (c.month ?? 1, c.day ?? 1, c.isLeapMonth ?? false)
    }

    private func lunarMonthName(of date: Date) -> String {
        let (month, _, leap) = lunarComponents(of: date)
        let names = ["正月","二月","三月","四月","五月","六月",
                     "七月","八月","九月","十月","冬月","腊月"]
        let base = names[(month - 1 + 12) % 12]
        return leap ? "闰" + base : base
    }

    /// 农历日名：初一…初十 / 十一…十九 / 二十 / 廿一…廿九 / 三十。
    static func lunarDayName(_ day: Int) -> String {
        let digits = ["日","一","二","三","四","五","六","七","八","九","十"]
        switch day {
        case 1...10:  return "初" + digits[day]
        case 11...19: return "十" + digits[day - 10]
        case 20:      return "二十"
        case 21...29: return "廿" + digits[day - 20]
        case 30:      return "三十"
        default:      return ""
        }
    }

    // MARK: 节气（寿星通用公式）

    /// 24 节气按月序（每月两个）的 21 世纪常数 C。
    private static let termC: [Double] = [
        5.4055, 20.12,   // 1 月：小寒、大寒
        3.87,   18.73,   // 2 月：立春、雨水
        5.63,   20.646,  // 3 月：惊蛰、春分
        4.81,   20.1,    // 4 月：清明、谷雨
        5.52,   21.04,   // 5 月：立夏、小满
        5.678,  21.37,   // 6 月：芒种、夏至
        7.108,  22.83,   // 7 月：小暑、大暑
        7.5,    23.13,   // 8 月：立秋、处暑
        7.646,  23.042,  // 9 月：白露、秋分
        8.318,  23.438,  // 10 月：寒露、霜降
        7.438,  22.36,   // 11 月：立冬、小雪
        7.18,   22.60,   // 12 月：大雪、冬至
    ]

    private static let termName: [String] = [
        "小寒","大寒","立春","雨水","惊蛰","春分","清明","谷雨","立夏","小满","芒种","夏至",
        "小暑","大暑","立秋","处暑","白露","秋分","寒露","霜降","立冬","小雪","大雪","冬至",
    ]

    /// 若该公历日是某节气，返回节气名，否则 nil。
    public func solarTerm(for date: Date) -> String? {
        let c = gregorian.dateComponents([.year, .month, .day], from: date)
        guard let year = c.year, let month = c.month, let day = c.day else { return nil }
        for which in 0..<2 {
            if Self.solarTermDay(year: year, month: month, which: which) == day {
                return Self.termName[(month - 1) * 2 + which]
            }
        }
        return nil
    }

    /// 寿星公式：`[Y·D + C] − [(Y−1)/4]`，Y 为年份后两位，D=0.2422。
    static func solarTermDay(year: Int, month: Int, which: Int) -> Int {
        let y = Double(year % 100)
        let c = termC[(month - 1) * 2 + which]
        return Int(y * 0.2422 + c) - (year % 100 - 1) / 4
    }

    // MARK: 节日

    /// 公历固定节日
    private static let solarFestivals: [Int: String] = [
        101: "元旦", 214: "情人节", 308: "妇女节", 312: "植树节",
        401: "愚人节", 501: "劳动节", 504: "青年节", 601: "儿童节",
        701: "建党节", 801: "建军节", 910: "教师节", 1001: "国庆节",
        1224: "平安夜", 1225: "圣诞节",
    ]

    /// 农历固定节日（key = 月*100 + 日）
    private static let lunarFestivals: [Int: String] = [
        101: "春节", 115: "元宵", 202: "龙抬头", 505: "端午",
        707: "七夕", 715: "中元节", 815: "中秋", 909: "重阳",
        1208: "腊八", 1223: "小年",
    ]

    /// 该日的节日名（公历优先，其次农历，最后判除夕），无则 nil。
    public func festival(for date: Date) -> String? {
        let g = gregorian.dateComponents([.month, .day], from: date)
        if let m = g.month, let d = g.day, let name = Self.solarFestivals[m * 100 + d] {
            return name
        }
        let (lm, ld, leap) = lunarComponents(of: date)
        if !leap, let name = Self.lunarFestivals[lm * 100 + ld] {
            return name
        }
        // 除夕：次日为正月初一
        if let next = gregorian.date(byAdding: .day, value: 1, to: date) {
            let (nm, nd, _) = lunarComponents(of: next)
            if nm == 1 && nd == 1 { return "除夕" }
        }
        return nil
    }
}

/// 日历格子副标题：文字 + 类别（供上层配色）。
public struct DayAnnotation: Equatable, Sendable {
    public enum Kind: Sendable { case festival, solarTerm, lunarMonth, lunarDay }
    public let text: String
    public let kind: Kind

    public init(text: String, kind: Kind) {
        self.text = text
        self.kind = kind
    }
}
