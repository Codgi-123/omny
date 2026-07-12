import SwiftUI
import SwiftData
import OmnyCore

/// 收支日历：通用月历网格，每天显示当日收支；点某天在下方展开当天记账列表。
/// 网格用 Calendar 算当月首日星期偏移 + 天数，前后补位其他月日期占格。
struct ExpenseCalendarView: View {
    let month: Date
    let items: [InboxItem]

    @State private var selectedDay: Date?

    private let cal = Calendar.current
    private let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

    /// 当月每天的收支合计：day(startOfDay) -> (expense, income)
    private var dailyTotals: [Date: (expense: Decimal, income: Decimal)] {
        var map: [Date: (Decimal, Decimal)] = [:]
        for item in items {
            let day = cal.startOfDay(for: item.occurredAt ?? item.createdAt)
            var t = map[day] ?? (0, 0)
            if item.expenseDirection == .income { t.1 += item.amount ?? 0 }
            else { t.0 += item.amount ?? 0 }
            map[day] = t
        }
        return map
    }

    /// 选中日的记账列表
    private var selectedItems: [InboxItem] {
        guard let selectedDay else { return [] }
        return items.filter { cal.isDate($0.occurredAt ?? $0.createdAt, inSameDayAs: selectedDay) }
            .sorted { ($0.occurredAt ?? $0.createdAt) > ($1.occurredAt ?? $1.createdAt) }
    }

    var body: some View {
        List {
            calendarCard
                .listRowInsets(EdgeInsets(top: 4, leading: Theme.Space.page,
                                          bottom: 12, trailing: Theme.Space.page))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            if let selectedDay {
                Section {
                    if selectedItems.isEmpty {
                        Text("当天无记账").font(.subheadline).foregroundStyle(Theme.sub)
                            .cardCell()
                    } else {
                        ForEach(selectedItems) { item in
                            NavigationLink { ExpenseDetailView(item: item) } label: {
                                ExpenseRow(item: item)
                            }
                            .cardCell()
                        }
                    }
                } header: {
                    Text(daySectionLabel(selectedDay))
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundStyle(Theme.sub).textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.screen)
    }

    // MARK: 网格

    private var calendarCard: some View {
        VStack(spacing: 8) {
            HStack {
                ForEach(weekdays, id: \.self) { d in
                    Text(d).font(.caption2).foregroundStyle(Theme.sub)
                        .frame(maxWidth: .infinity)
                }
            }
            let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
            LazyVGrid(columns: cols, spacing: 2) {
                ForEach(Array(gridDays.enumerated()), id: \.offset) { _, day in
                    cell(day)
                }
            }
        }
        .cardStyle()
    }

    @ViewBuilder
    private func cell(_ day: Date?) -> some View {
        if let day {
            let totals = dailyTotals[cal.startOfDay(for: day)]
            let isSelected = selectedDay.map { cal.isDate($0, inSameDayAs: day) } ?? false
            let isToday = cal.isDateInToday(day)
            Button {
                selectedDay = cal.startOfDay(for: day)
            } label: {
                VStack(spacing: 1) {
                    Text("\(cal.component(.day, from: day))")
                        .font(.footnote)
                        .fontWeight(isToday ? .bold : .medium)
                        .foregroundStyle(isSelected ? .white : (isToday ? Theme.accent : Theme.text))
                    if let totals {
                        if totals.expense > 0 {
                            Text("-\(compact(totals.expense))")
                                .font(.system(size: 9)).monospacedDigit()
                                .foregroundStyle(isSelected ? .white : Theme.red)
                                .lineLimit(1)
                        }
                        if totals.income > 0 {
                            Text("+\(compact(totals.income))")
                                .font(.system(size: 9)).monospacedDigit()
                                .foregroundStyle(isSelected ? .white : Theme.green)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(isSelected ? Theme.accent : Color.clear,
                            in: .rect(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        } else {
            // 补位空格（上月/下月占位）
            Color.clear.frame(height: 44)
        }
    }

    /// 网格天数组：前置补位(首日星期偏移个 nil) + 当月各天
    private var gridDays: [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: month) else { return [] }
        let firstDay = interval.start
        let daysInMonth = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        // weekday: 1=周日…7=周六；网格首列是周日，前置偏移 = weekday-1
        let leading = cal.component(.weekday, from: firstDay) - 1
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for offset in 0..<daysInMonth {
            cells.append(cal.date(byAdding: .day, value: offset, to: firstDay))
        }
        return cells
    }

    // MARK: 辅助

    /// 日历格金额紧凑显示：大数取整、上万加"万"，避免撑破小格
    private func compact(_ value: Decimal) -> String {
        let d = NSDecimalNumber(decimal: value).doubleValue
        if d >= 10000 { return String(format: "%.0f万", d / 10000) }
        return String(format: "%.0f", d)
    }

    private func daySectionLabel(_ day: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 EEEE"
        return f.string(from: day)
    }
}
