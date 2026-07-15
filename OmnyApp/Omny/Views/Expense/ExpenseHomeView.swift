import SwiftUI
import SwiftData
import OmnyCore

/// 记账 tab 根视图（issue #10 从设置页入口升格）：明细 / 日历 / 分析 三视图分段切换，
/// 共享月份。右下悬浮添加。
/// 骨架沿用 OmnyApp 现有页面模式（ScreenHeader + List + Theme.screen + toolbar 隐藏）。
struct ExpenseHomeView: View {
    enum Mode: String, CaseIterable { case detail = "明细", calendar = "日历", analysis = "分析" }

    @Query(sort: \InboxItem.createdAt, order: .reverse) private var allItems: [InboxItem]
    @State private var mode: Mode = .detail
    @State private var month: Date = Calendar.current.startOfDay(for: .now)
    @State private var showAdd = false
    @State private var showMonthPicker = false

    /// 当月记账（用 occurredAt/createdAt 判月）；active 已排除回收站条目
    private var monthItems: [InboxItem] {
        allItems.active(.expense).filter { MonthTool.inMonth($0, month: month) }
    }
    private var summary: ExpenseSummary { ExpenseSummary(items: monthItems) }

    var body: some View {
        VStack(spacing: 0) {
            // 标题行右侧与其他 tab 根一致挂 NavActions（需处理/设置入口）；
            // 三段分段控件下移独占一排——与需处理角标同行时小屏会挤不下
            ScreenHeader("记账") { NavActions() }

            Picker("视图", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Space.page)

            monthSwitcher

            content
        }
        .background(Theme.screen)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottomTrailing) {
            // 分析视图无需记账入口时也保留 FAB，任何视图都能随手记一笔。
            // 56pt 是记账页的既有尺寸（比待办/收藏的 64pt 小一号），保留
            FloatingAddButton(size: 56) { showAdd = true }
        }
        .sheet(isPresented: $showAdd) {
            ExpenseEditView(editing: nil, defaultDate: month)
        }
        .sheet(isPresented: $showMonthPicker) {
            MonthPickerSheet(month: $month)
        }
    }

    private var monthSwitcher: some View {
        HStack(spacing: 24) {
            Button { month = MonthTool.adding(-1, to: month) } label: {
                Image(systemName: "chevron.left")
            }
            // 点月份标题唤起年+月滚轮选择弹窗
            Button { showMonthPicker = true } label: {
                Text(OmnyDateFormat.monthTitle(month))
                    .font(.subheadline).fontWeight(.semibold)
                    .frame(minWidth: 100)
            }
            Button { month = MonthTool.adding(1, to: month) } label: {
                Image(systemName: "chevron.right")
            }
        }
        .foregroundStyle(Theme.accent)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .detail:
            ExpenseDetailList(summary: summary)
        case .calendar:
            ExpenseCalendarView(month: $month, items: monthItems)
        case .analysis:
            ExpenseAnalysisView(summary: summary)
        }
    }
}

// MARK: - 明细子视图

/// 明细：顶部结余/支出/收入大卡片 + 按天分组的记账列表。
struct ExpenseDetailList: View {
    let summary: ExpenseSummary

    var body: some View {
        List {
            summaryCard
                .listRowInsets(EdgeInsets(top: 4, leading: Theme.Space.page,
                                          bottom: 12, trailing: Theme.Space.page))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            ForEach(summary.byDay(), id: \.day) { group in
                Section {
                    ForEach(group.items) { item in
                        NavigationLink { ExpenseDetailView(item: item) } label: {
                            ExpenseRow(item: item)
                        }
                        .cardCell()
                    }
                } header: {
                    dayHeader(group)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.screen)
        .overlay {
            if summary.items.isEmpty {
                ContentUnavailableView("本月暂无记账", systemImage: "yensign.circle",
                                       description: Text("点右下按钮记一笔，或让银行短信/截图自动记账"))
            }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("本月结余").font(.subheadline).foregroundStyle(Theme.sub)
            Text(ExpenseFormat.amount(summary.balance, signed: false))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .padding(.top, 4)
            Divider().padding(.vertical, 14)
            HStack {
                metric("支出", summary.totalExpense, color: Theme.text)
                Spacer()
                metric("收入", summary.totalIncome, color: Theme.green)
                Spacer()
            }
        }
        .cardStyle()
    }

    private func metric(_ label: String, _ value: Decimal, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(Theme.sub)
            Text(ExpenseFormat.amount(value, signed: false))
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }

    private func dayHeader(_ group: (day: Date, items: [InboxItem])) -> some View {
        let s = ExpenseSummary(items: group.items)
        return HStack {
            Text(OmnyDateFormat.dayWithWeekday(group.day))
                .font(.subheadline).fontWeight(.semibold).foregroundStyle(Theme.sub)
            Spacer()
            HStack(spacing: 10) {
                if s.totalExpense > 0 {
                    Text("支出 \(ExpenseFormat.amount(s.totalExpense, signed: false))")
                }
                if s.totalIncome > 0 {
                    Text("收入 \(ExpenseFormat.amount(s.totalIncome, signed: false))")
                        .foregroundStyle(Theme.green)
                }
            }
            .font(.caption).foregroundStyle(Theme.sub).monospacedDigit()
        }
        .textCase(nil)
    }
}
