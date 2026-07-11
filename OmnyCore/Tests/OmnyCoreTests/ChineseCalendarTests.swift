import XCTest
@testable import OmnyCore

final class ChineseCalendarTests: XCTestCase {
    private let cal = ChineseCalendar()

    /// 构造北京时区的某一天正午，避开农历/节气按日切换的边界。
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = 12
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")
        var g = Calendar(identifier: .gregorian)
        g.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return g.date(from: c)!
    }

    // MARK: 农历日名映射

    func testLunarDayNames() {
        XCTAssertEqual(ChineseCalendar.lunarDayName(1), "初一")
        XCTAssertEqual(ChineseCalendar.lunarDayName(10), "初十")
        XCTAssertEqual(ChineseCalendar.lunarDayName(11), "十一")
        XCTAssertEqual(ChineseCalendar.lunarDayName(20), "二十")
        XCTAssertEqual(ChineseCalendar.lunarDayName(21), "廿一")
        XCTAssertEqual(ChineseCalendar.lunarDayName(27), "廿七")
        XCTAssertEqual(ChineseCalendar.lunarDayName(29), "廿九")
        XCTAssertEqual(ChineseCalendar.lunarDayName(30), "三十")
    }

    // MARK: 节气（寿星公式）

    func testSolarTermDayFormula() {
        XCTAssertEqual(ChineseCalendar.solarTermDay(year: 2026, month: 7, which: 0), 7)   // 小暑
        XCTAssertEqual(ChineseCalendar.solarTermDay(year: 2026, month: 7, which: 1), 23)  // 大暑
        XCTAssertEqual(ChineseCalendar.solarTermDay(year: 2026, month: 8, which: 0), 7)   // 立秋
        XCTAssertEqual(ChineseCalendar.solarTermDay(year: 2026, month: 12, which: 1), 22) // 冬至
    }

    func testSolarTermLookup() {
        XCTAssertEqual(cal.solarTerm(for: date(2026, 7, 7)), "小暑")
        XCTAssertEqual(cal.solarTerm(for: date(2026, 7, 23)), "大暑")
        XCTAssertNil(cal.solarTerm(for: date(2026, 7, 8)))
    }

    // MARK: 节日

    func testSolarFestival() {
        XCTAssertEqual(cal.festival(for: date(2026, 7, 1)), "建党节")
        XCTAssertEqual(cal.festival(for: date(2026, 10, 1)), "国庆节")
        XCTAssertEqual(cal.festival(for: date(2026, 1, 1)), "元旦")
    }

    func testLunarFestivalSpringFestival() {
        // 2026 春节 = 2 月 17 日；除夕 = 2 月 16 日
        XCTAssertEqual(cal.festival(for: date(2026, 2, 17)), "春节")
        XCTAssertEqual(cal.festival(for: date(2026, 2, 16)), "除夕")
    }

    // MARK: 整合副标题（对齐截图 2026 年 7 月）

    func testAnnotationMatchesScreenshot() {
        // 7/1 建党节
        XCTAssertEqual(cal.annotation(for: date(2026, 7, 1)),
                       DayAnnotation(text: "建党节", kind: .festival))
        // 7/7 小暑
        XCTAssertEqual(cal.annotation(for: date(2026, 7, 7)),
                       DayAnnotation(text: "小暑", kind: .solarTerm))
        // 7/11 廿七（农历五月）
        XCTAssertEqual(cal.annotation(for: date(2026, 7, 11)),
                       DayAnnotation(text: "廿七", kind: .lunarDay))
        // 7/14 六月初一 → 显示月名
        XCTAssertEqual(cal.annotation(for: date(2026, 7, 14)),
                       DayAnnotation(text: "六月", kind: .lunarMonth))
        // 7/23 大暑
        XCTAssertEqual(cal.annotation(for: date(2026, 7, 23)),
                       DayAnnotation(text: "大暑", kind: .solarTerm))
    }
}
