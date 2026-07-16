import SwiftUI
import SwiftData
import OmnyCore

/// 记账 tab 根视图（issue #28 调整）：只承载「明细」内容，日历/统计降为控制条上的入口。
/// 头部两行：ScreenHeader + NavActions，控制条切月 + 收支日历/数据统计入口。
/// 右下悬浮添加。骨架沿用 OmnyApp 现有页面模式（ScreenHeader + List + Theme.screen + toolbar 隐藏）。
struct ExpenseHomeView: View {
    @Query(sort: \InboxItem.createdAt, order: .reverse) private var allItems: [InboxItem]
    @State private var month: Date = Calendar.current.startOfDay(for: .now)
    @State private var showAdd = false
    @State private var showMonthPicker = false

    /// 当月记账（用 occurredAt/createdAt 判月）；active 已排除回收站条目
    private var monthItems: [InboxItem] {
        allItems.active(.expense).filter { MonthTool.inMonth($0, month: month) }
    }
    private var summary: ExpenseSummary { ExpenseSummary(items: monthItems) }

    /// 当前选中月是否不是本月（用于「本月」快速回跳按钮的显隐）
    private var notCurrentMonth: Bool {
        !Calendar.current.isDate(month, equalTo: .now, toGranularity: .month)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 第一行：大标题 + 尾部「本月」快速回跳（仅非本月时出现）+ NavActions
            ScreenHeader("记账") {
                HStack(spacing: 12) {
                    if notCurrentMonth {
                        Button {
                            month = Calendar.current.startOfDay(for: .now)
                        } label: {
                            Text("本月")
                                .font(.footnote).fontWeight(.semibold)
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Theme.accent.opacity(0.14), in: Capsule())
                        }
                    }
                    NavActions()
                }
            }

            controlBar

            ExpenseDetailList(summary: summary)
        }
        .background(Theme.screen)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottomTrailing) {
            // 56pt 是记账页的既有尺寸（比待办/收藏的 64pt 小一号），保留
            FloatingAddButton { showAdd = true }
        }
        .sheet(isPresented: $showAdd) {
            ExpenseEditView(editing: nil, defaultDate: month)
        }
        .sheet(isPresented: $showMonthPicker) {
            MonthPickerSheet(month: $month)
        }
    }

    /// 第二行控制条：左边圆钮切月 + 月份标题；右边并排「收支日历」「数据统计」入口
    private var controlBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                circleButton("chevron.left") { month = MonthTool.adding(-1, to: month) }
                Button { showMonthPicker = true } label: {
                    Text(OmnyDateFormat.monthTitle(month))
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundStyle(Theme.text)
                }
                circleButton("chevron.right") { month = MonthTool.adding(1, to: month) }
            }

            Spacer()

            HStack(spacing: 8) {
                NavigationLink { ExpenseCalendarPage() } label: {
                    entryPill("收支日历")
                }
                NavigationLink { ExpenseStatsView() } label: {
                    entryPill("数据统计")
                }
            }
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 8)
    }

    /// 30x30 圆形切月钮：Theme.fill 底、Theme.accent 前景
    private func circleButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(Theme.fill, in: Circle())
        }
    }

    /// 入口胶囊：文字 + chevron.right，Theme.fill 底、Theme.accent 前景
    private func entryPill(_ title: String) -> some View {
        HStack(spacing: 2) {
            Text(title).font(.footnote).fontWeight(.medium)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.fill, in: Capsule())
    }
}

// MARK: - 明细子视图

/// 明细：顶部结余/支出/收入大卡片 + 按天分组的记账列表。
struct ExpenseDetailList: View {
    let summary: ExpenseSummary
    @Environment(\.modelContext) private var context

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
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                withAnimation(.snappy) {
                                    Trash.softDelete(item, context: context)
                                }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
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
                ContentUnavailableView {
                    Label {
                        Text("本月暂无记账")
                    } icon: {
                        // 自绘钱袋线稿替代 SF yensign.circle，与分类图标同一套风格
                        CategoryIconGlyph(icon: .asset("ExpIconMoneyBag"), pointSize: 46)
                            .foregroundStyle(Theme.sub)
                    }
                } description: {
                    Text("点右下按钮记一笔，或让银行短信/截图自动记账")
                }
            }
        }
    }

    /// 汇总卡：总支出为主角（记账 App 最高频关注项），收入/结余降为次级指标。
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("本月支出").font(.subheadline).foregroundStyle(Theme.sub)
            Text(ExpenseFormat.amount(summary.totalExpense, signed: false))
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .padding(.top, 4)
            Divider().padding(.vertical, 14)
            HStack {
                metric("本月收入", ExpenseFormat.amount(summary.totalIncome, signed: false),
                       color: Theme.green)
                Spacer()
                metric("月结余", ExpenseFormat.balance(summary.balance), color: Theme.text)
                Spacer()
            }
        }
        .cardStyle()
    }

    private func metric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(Theme.sub)
            Text(value)
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
