import SwiftUI
import SwiftData
import OmnyCore

/// 收支日历页（issue #28 第二部分）：月历卡里每天直接显示当日支出/收入，
/// 点某天在下方看当天汇总与明细。有收支的天用收支行替代农历副标题。
struct ExpenseCalendarPage: View {
    @Query(sort: \InboxItem.createdAt, order: .reverse) private var allItems: [InboxItem]

    /// 默认选中今天
    @State private var selectedDay: Date? = Calendar.current.startOfDay(for: .now)

    private var items: [InboxItem] { allItems.active(.expense) }

    /// 每天的支出/收入合计（key = 当天 0 点）。一次遍历算好，日历回调直接查表。
    private var dailyTotals: [Date: (expense: Decimal, income: Decimal)] {
        let cal = Calendar.current
        var map: [Date: (expense: Decimal, income: Decimal)] = [:]
        for item in items {
            let day = cal.startOfDay(for: ExpenseStats.effectiveDate(item))
            var cur = map[day] ?? (0, 0)
            let amount = item.amount ?? 0
            if item.expenseDirection == .income {
                cur.income += amount
            } else {
                cur.expense += amount
            }
            map[day] = cur
        }
        return map
    }

    /// 当天明细（时间倒序）
    private var dayItems: [InboxItem] {
        guard let day = selectedDay else { return [] }
        let cal = Calendar.current
        return items
            .filter { cal.isDate(ExpenseStats.effectiveDate($0), inSameDayAs: day) }
            .sorted { ExpenseStats.effectiveDate($0) > ExpenseStats.effectiveDate($1) }
    }

    /// 当天支出/收入合计
    private var daySummary: (expense: Decimal, income: Decimal) {
        guard let day = selectedDay else { return (0, 0) }
        return dailyTotals[Calendar.current.startOfDay(for: day)] ?? (0, 0)
    }

    var body: some View {
        let totals = dailyTotals
        List {
            // ① 日历卡：每天显示当日收支，替代农历副标题
            MonthCalendarView(
                selection: $selectedDay,
                allowMonthPicker: true,
                dayLines: { day in
                    guard let t = totals[Calendar.current.startOfDay(for: day)] else { return nil }
                    var lines: [CalendarDayLine] = []
                    if t.expense > 0 {
                        lines.append(CalendarDayLine(text: "-\(ExpenseFormat.compactBare(t.expense))", color: Theme.red))
                    }
                    if t.income > 0 {
                        lines.append(CalendarDayLine(text: "+\(ExpenseFormat.compactBare(t.income))", color: Theme.green))
                    }
                    return lines.isEmpty ? nil : lines
                }
            )
            .cardStyle()
            .listRowInsets(EdgeInsets(top: 5, leading: Theme.Space.page, bottom: 5, trailing: Theme.Space.page))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            // ② 当天汇总行
            if let day = selectedDay {
                HStack {
                    Text(Self.dayFormatter.string(from: day))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    HStack(spacing: 14) {
                        Text("支出 \(ExpenseFormat.amount(daySummary.expense, direction: .expense, signed: false))")
                            .foregroundStyle(Theme.text)
                        Text("收入 \(ExpenseFormat.amount(daySummary.income, direction: .income, signed: false))")
                            .foregroundStyle(Theme.green)
                    }
                    .font(.subheadline)
                    .monospacedDigit()
                }
                .cardCell()
            }

            // ③ 当天明细
            if dayItems.isEmpty {
                Text("当天无记账")
                    .font(.subheadline)
                    .foregroundStyle(Theme.sub)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .cardCell()
            } else {
                ForEach(dayItems) { item in
                    NavigationLink {
                        ExpenseDetailView(item: item)
                    } label: {
                        ExpenseRow(item: item)
                    }
                    .cardCell()
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.screen)
        .navigationTitle("收支日历")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 当天汇总行左侧日期：「7/16 星期四」
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M/d EEEE"
        return f
    }()
}
