import XCTest
@testable import OmnyCore

final class TodoRepeatRuleTests: XCTestCase {

    /// 固定日历：公历 + 北京时区，保证用例确定性（不依赖运行机器的时区）
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0, _ s: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = mi; c.second = s
        return cal.date(from: c)!
    }

    // MARK: - parse / encoded 互逆

    func testParseEncodedRoundtrip() {
        // 规范字符串：parse 后 encoded 应原样回来
        let canonical = ["d:1", "d:3", "w:1:4", "w:2:1,4", "w:1:1,3,5,6,7", "m:1:16", "m:2:31", "m:1:1,15,31", "y:1:7-16", "y:4:2-29", "weekday"]
        for raw in canonical {
            let rule = TodoRepeatRule.parse(raw)
            XCTAssertNotNil(rule, "应能解析：\(raw)")
            XCTAssertEqual(rule?.encoded, raw, "编码应互逆：\(raw)")
        }
    }

    func testParsedCases() {
        XCTAssertEqual(TodoRepeatRule.parse("d:3"), .daily(interval: 3))
        XCTAssertEqual(TodoRepeatRule.parse("w:2:1,4"), .weekly(interval: 2, weekdays: [1, 4]))
        XCTAssertEqual(TodoRepeatRule.parse("m:1:16"), .monthly(interval: 1, days: [16]))
        XCTAssertEqual(TodoRepeatRule.parse("m:1:15,1"), .monthly(interval: 1, days: [1, 15]))
        XCTAssertEqual(TodoRepeatRule.parse("y:1:7-16"), .yearly(interval: 1, month: 7, day: 16))
        XCTAssertEqual(TodoRepeatRule.parse("weekday"), .weekdays)
    }

    func testEncodedSortsWeekdays() {
        // 集合乱序输入，编码升序输出保证稳定
        XCTAssertEqual(TodoRepeatRule.parse("w:1:4,1")?.encoded, "w:1:1,4")
        XCTAssertEqual(TodoRepeatRule.weekly(interval: 1, weekdays: [7, 3, 1]).encoded, "w:1:1,3,7")
    }

    func testParseInvalid() {
        let invalid = [
            "",             // 空串
            "d:0",          // interval < 1
            "d:-1",
            "d:abc",
            "d:+3",         // 拒绝非纯数字
            "d: 1",
            "d:1:2",        // 多余字段
            "d:",
            "w:1:",         // 星期集合为空
            "w:1:8",        // 星期越界
            "w:1:0",
            "w:0:1",        // interval < 1
            "w:1:1,",       // 残缺列表
            "w:1:1,,4",
            "m:1:32",       // 月日越界
            "m:1:0",
            "m:0:5",
            "m:1",
            "m:1:",         // 日集合为空
            "m:1:1,",       // 残缺列表
            "m:1:1,,15",
            "y:1:13-1",     // 月份越界
            "y:1:2-30",     // 2 月永远没有 30 日
            "y:1:7",        // 缺日
            "y:1:7-16-1",
            "x:1",          // 未知前缀
            "weekday2",
            "乱码",
        ]
        for raw in invalid {
            XCTAssertNil(TodoRepeatRule.parse(raw), "应拒绝非法输入：\(raw)")
        }
    }

    // MARK: - label

    func testLabel() {
        XCTAssertEqual(TodoRepeatRule.daily(interval: 1).label, "每天")
        XCTAssertEqual(TodoRepeatRule.daily(interval: 3).label, "每 3 天")
        XCTAssertEqual(TodoRepeatRule.weekly(interval: 1, weekdays: [4]).label, "每周的周四")
        XCTAssertEqual(TodoRepeatRule.weekly(interval: 2, weekdays: [4, 1]).label, "每 2 周的周一、周四")
        XCTAssertEqual(TodoRepeatRule.monthly(interval: 1, days: [16]).label, "每月 16 日")
        XCTAssertEqual(TodoRepeatRule.monthly(interval: 1, days: [15, 1]).label, "每月 1、15 日")
        XCTAssertEqual(TodoRepeatRule.yearly(interval: 1, month: 7, day: 16).label, "每年 7 月 16 日")
        XCTAssertEqual(TodoRepeatRule.weekdays.label, "工作日")
    }

    // MARK: - daily

    func testDailyKeepsTime() {
        // 21:00 → 明天 21:00
        let rule = TodoRepeatRule.daily(interval: 1)
        XCTAssertEqual(rule.next(after: date(2026, 7, 15, 21, 0), calendar: cal), date(2026, 7, 16, 21, 0))
    }

    func testDailyInterval3() {
        let rule = TodoRepeatRule.daily(interval: 3)
        XCTAssertEqual(rule.next(after: date(2026, 7, 15, 9, 30), calendar: cal), date(2026, 7, 18, 9, 30))
    }

    // MARK: - weekly（2026-07-13 是周一，2026-07-16 是周四）

    func testWeeklySingleWeekday() {
        // w:1:4，周四 → 下周四
        let rule = TodoRepeatRule.weekly(interval: 1, weekdays: [4])
        XCTAssertEqual(rule.next(after: date(2026, 7, 16, 10, 0), calendar: cal), date(2026, 7, 23, 10, 0))
    }

    func testWeeklyMultiSameWeek() {
        // w:2:1,4，due=周一 → 下一次是同周周四
        let rule = TodoRepeatRule.weekly(interval: 2, weekdays: [1, 4])
        XCTAssertEqual(rule.next(after: date(2026, 7, 13, 8, 0), calendar: cal), date(2026, 7, 16, 8, 0))
    }

    func testWeeklyMultiJumpsInterval() {
        // w:2:1,4，due=周四 → 下一次是 2 周后的周一
        let rule = TodoRepeatRule.weekly(interval: 2, weekdays: [1, 4])
        XCTAssertEqual(rule.next(after: date(2026, 7, 16, 8, 0), calendar: cal), date(2026, 7, 27, 8, 0))
    }

    func testWeeklySundayBackToMonday() {
        // w:1:1，周日（2026-07-19）→ 下周一（2026-07-20）
        // 规则的"周"固定周一起点，与 calendar.firstWeekday（gregorian 默认周日起）无关
        let rule = TodoRepeatRule.weekly(interval: 1, weekdays: [1])
        XCTAssertEqual(rule.next(after: date(2026, 7, 19, 18, 0), calendar: cal), date(2026, 7, 20, 18, 0))
    }

    // MARK: - monthly

    func testMonthly31ClampsAndRecovers() {
        // 目标日固定 31：1/31 → 2/28（2026 平年）→ 3/31（clamp 不污染规则）
        let rule = TodoRepeatRule.monthly(interval: 1, days: [31])
        let feb = rule.next(after: date(2026, 1, 31, 20, 0), calendar: cal)
        XCTAssertEqual(feb, date(2026, 2, 28, 20, 0))
        XCTAssertEqual(rule.next(after: feb, calendar: cal), date(2026, 3, 31, 20, 0))
    }

    func testMonthlyLeapFebruary() {
        // 2028 闰年 2 月有 29 天
        let rule = TodoRepeatRule.monthly(interval: 1, days: [31])
        XCTAssertEqual(rule.next(after: date(2028, 1, 31, 9, 0), calendar: cal), date(2028, 2, 29, 9, 0))
    }

    func testMonthlyInterval2() {
        let rule = TodoRepeatRule.monthly(interval: 2, days: [16])
        XCTAssertEqual(rule.next(after: date(2026, 1, 16, 7, 15), calendar: cal), date(2026, 3, 16, 7, 15))
    }

    func testMonthlyKeepsTimeAcrossMonth() {
        // 跨月不丢时分秒
        let rule = TodoRepeatRule.monthly(interval: 1, days: [31])
        XCTAssertEqual(rule.next(after: date(2026, 1, 31, 23, 59, 59), calendar: cal), date(2026, 2, 28, 23, 59, 59))
    }

    func testMonthlyLaterSameMonth() {
        // due 不在规则日上、当月目标日未过 → 先取当月（与 weekly 同构）
        let rule = TodoRepeatRule.monthly(interval: 1, days: [16])
        XCTAssertEqual(rule.next(after: date(2026, 1, 10, 9, 0), calendar: cal), date(2026, 1, 16, 9, 0))
    }

    func testMonthlyMultiDays() {
        // m:1:1,15,31：月内逐个推进，月末跳到下月最早选中日
        let rule = TodoRepeatRule.monthly(interval: 1, days: [1, 15, 31])
        XCTAssertEqual(rule.next(after: date(2026, 1, 15, 8, 0), calendar: cal), date(2026, 1, 31, 8, 0))
        XCTAssertEqual(rule.next(after: date(2026, 1, 31, 8, 0), calendar: cal), date(2026, 2, 1, 8, 0))
    }

    func testMonthlyMultiDaysClampCollision() {
        // 2 月里 29/31 都 clamp 到 28：候选去重后不会卡死，且下月各自恢复
        let rule = TodoRepeatRule.monthly(interval: 1, days: [29, 31])
        let feb = rule.next(after: date(2026, 1, 31, 10, 0), calendar: cal)
        XCTAssertEqual(feb, date(2026, 2, 28, 10, 0))
        XCTAssertEqual(rule.next(after: feb, calendar: cal), date(2026, 3, 29, 10, 0))
    }

    // MARK: - yearly

    func testYearlyLeapDay() {
        // 2/29 闰年 → 次年 2/28 → …… → 下个闰年回到 2/29
        let rule = TodoRepeatRule.yearly(interval: 1, month: 2, day: 29)
        let y2025 = rule.next(after: date(2024, 2, 29, 10, 0), calendar: cal)
        XCTAssertEqual(y2025, date(2025, 2, 28, 10, 0))
        let y2026 = rule.next(after: y2025, calendar: cal)
        XCTAssertEqual(y2026, date(2026, 2, 28, 10, 0))
        let y2027 = rule.next(after: y2026, calendar: cal)
        XCTAssertEqual(y2027, date(2027, 2, 28, 10, 0))
        // 闰年恢复 29 日（clamp 不污染规则）
        XCTAssertEqual(rule.next(after: y2027, calendar: cal), date(2028, 2, 29, 10, 0))
    }

    func testYearlyNormal() {
        let rule = TodoRepeatRule.yearly(interval: 1, month: 7, day: 16)
        XCTAssertEqual(rule.next(after: date(2026, 7, 16, 9, 0), calendar: cal), date(2027, 7, 16, 9, 0))
    }

    func testYearlyLaterThisYear() {
        // due 早于今年目标日 → 先取今年（与 weekly/monthly 同构）
        let rule = TodoRepeatRule.yearly(interval: 1, month: 7, day: 16)
        XCTAssertEqual(rule.next(after: date(2026, 3, 1, 9, 0), calendar: cal), date(2026, 7, 16, 9, 0))
    }

    // MARK: - weekdays（工作日）

    func testWeekdaysFridayToMonday() {
        // 2026-07-17 是周五 → 2026-07-20 周一
        XCTAssertEqual(TodoRepeatRule.weekdays.next(after: date(2026, 7, 17, 9, 0), calendar: cal), date(2026, 7, 20, 9, 0))
    }

    func testWeekdaysWednesdayToThursday() {
        // 2026-07-15 是周三 → 2026-07-16 周四
        XCTAssertEqual(TodoRepeatRule.weekdays.next(after: date(2026, 7, 15, 9, 0), calendar: cal), date(2026, 7, 16, 9, 0))
    }

    func testWeekdaysWeekendToMonday() {
        // 周六/周日 → 下周一
        XCTAssertEqual(TodoRepeatRule.weekdays.next(after: date(2026, 7, 18, 9, 0), calendar: cal), date(2026, 7, 20, 9, 0))
        XCTAssertEqual(TodoRepeatRule.weekdays.next(after: date(2026, 7, 19, 9, 0), calendar: cal), date(2026, 7, 20, 9, 0))
    }

    // MARK: - nextOccurrence（补勾跳过欠账期次）

    func testNextOccurrenceSkipsMissed() {
        // 每天规则 due=7/1 21:00，now=7/16 12:00 → 只滚到 7/16 21:00
        let rule = TodoRepeatRule.daily(interval: 1)
        XCTAssertEqual(
            rule.nextOccurrence(from: date(2026, 7, 1, 21, 0), now: date(2026, 7, 16, 12, 0), calendar: cal),
            date(2026, 7, 16, 21, 0)
        )
        // now=7/16 22:00（已过当天 21:00）→ 7/17 21:00
        XCTAssertEqual(
            rule.nextOccurrence(from: date(2026, 7, 1, 21, 0), now: date(2026, 7, 16, 22, 0), calendar: cal),
            date(2026, 7, 17, 21, 0)
        )
    }

    func testNextOccurrenceBoundaryStrictlyAfterNow() {
        // now 恰好等于某期次 → 必须严格晚于 now，推到下一期
        let rule = TodoRepeatRule.daily(interval: 1)
        XCTAssertEqual(
            rule.nextOccurrence(from: date(2026, 7, 1, 21, 0), now: date(2026, 7, 16, 21, 0), calendar: cal),
            date(2026, 7, 17, 21, 0)
        )
    }

    func testNextOccurrenceNowBeforeDue() {
        // now 早于 due 时等价 next(after: due)
        let rule = TodoRepeatRule.daily(interval: 1)
        XCTAssertEqual(
            rule.nextOccurrence(from: date(2026, 7, 20, 21, 0), now: date(2026, 7, 16, 12, 0), calendar: cal),
            rule.next(after: date(2026, 7, 20, 21, 0), calendar: cal)
        )
    }

    func testNextOccurrenceMonthlyClampNotPolluted() {
        // m:1:31 欠账跨过 2 月：due=1/31，now=3/15 → 3/31（中途 clamp 到 2/28 不影响后续回到 31 日）
        let rule = TodoRepeatRule.monthly(interval: 1, days: [31])
        XCTAssertEqual(
            rule.nextOccurrence(from: date(2026, 1, 31, 20, 0), now: date(2026, 3, 15, 12, 0), calendar: cal),
            date(2026, 3, 31, 20, 0)
        )
    }

    func testNextOccurrenceWeekly() {
        // w:1:4 due=周四 7/2，now=7/16（周四）12:00，due 时间 10:00（当天 10:00 已过）→ 7/23 10:00
        let rule = TodoRepeatRule.weekly(interval: 1, weekdays: [4])
        XCTAssertEqual(
            rule.nextOccurrence(from: date(2026, 7, 2, 10, 0), now: date(2026, 7, 16, 12, 0), calendar: cal),
            date(2026, 7, 23, 10, 0)
        )
    }
}
