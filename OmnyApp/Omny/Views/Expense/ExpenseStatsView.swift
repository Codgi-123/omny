import SwiftUI
import SwiftData
import Charts
import OmnyCore

/// 数据统计详情页（issue #28 三）：顶部选周期，中间可平移窗口，
/// 下含「收支统计宫格 / 支出分类环形图 / 收支趋势折线」三张卡。push 进入，非 tab 根页。
struct ExpenseStatsView: View {
    @Query private var allItems: [InboxItem]

    @State private var period: StatsPeriod = .month
    @State private var anchor: Date = .now
    @State private var customStart: Date = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
    @State private var customEnd: Date = .now
    /// 环形图方向（支出/收入切换）
    @State private var donutDirection: ExpenseDirection = .expense
    /// 环形图维度：false=大类，true=子类
    @State private var donutBySub = false
    /// 折线图指标
    @State private var trendMetric: TrendMetric = .expense

    /// 折线图指标（支出/收入/结余），本页局部
    private enum TrendMetric: String, CaseIterable, Identifiable {
        case expense = "支出", income = "收入", balance = "结余"
        var id: String { rawValue }
        /// 指标线颜色
        var color: Color {
            switch self {
            case .expense: Theme.red
            case .income:  Theme.green
            case .balance: Theme.accent
            }
        }
        /// 从数据点取该指标数值
        func value(_ p: ExpenseStats.Point) -> Decimal {
            switch self {
            case .expense: p.expense
            case .income:  p.income
            case .balance: p.balance
            }
        }
    }

    // MARK: 派生数据

    private var items: [InboxItem] { allItems.active(.expense) }

    private var window: StatsWindow {
        ExpenseStats.window(period: period, anchor: anchor,
                            customStart: customStart, customEnd: customEnd,
                            allItems: items)
    }

    private var filtered: [InboxItem] { ExpenseStats.filter(items, in: window) }

    private var summary: ExpenseSummary { ExpenseSummary(items: filtered) }

    /// 折线图是否展示：周/月/年可展示；自定义仅当区间 ≤30 天（按天铺不至于太密）
    private var showTrend: Bool {
        if period.isSteppable { return true }
        if period == .custom && window.dayCount <= 30 { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.gap) {
                periodPicker           // A
                windowStepper          // B
                statsCard              // C
                categoryCard           // D
                if showTrend {
                    trendCard          // E
                }
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.vertical, Theme.Space.gap)
        }
        .navigationTitle("数据统计")
        .navigationBarTitleDisplayMode(.inline)
        .background(Theme.screen)
    }

    // MARK: A. 周期选择

    private var periodPicker: some View {
        Picker("", selection: $period) {
            ForEach(StatsPeriod.allCases) { p in
                Text(p.rawValue).tag(p)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: B. 窗口平移行

    @ViewBuilder
    private var windowStepper: some View {
        HStack(spacing: 12) {
            switch period {
            case .week, .month, .year:
                stepButton(systemName: "chevron.left") {
                    anchor = ExpenseStats.shiftAnchor(period, anchor: anchor, by: -1)
                }
                Spacer(minLength: 0)
                Text(window.label)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                stepButton(systemName: "chevron.right") {
                    anchor = ExpenseStats.shiftAnchor(period, anchor: anchor, by: 1)
                }
            case .all:
                Spacer(minLength: 0)
                Text(window.label)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
            case .custom:
                customRange
            }
        }
        .cardStyle()
    }

    private func stepButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.fill, in: Circle())
        }
        .buttonStyle(PressableStyle())
    }

    /// 自定义区间：左右两个可点日期按钮，中间「-」，点开日历弹窗改起止日
    @State private var editingStart = false
    @State private var editingEnd = false

    private var customRange: some View {
        HStack(spacing: 8) {
            dateButton(customStart) { editingStart = true }
            Text("-").font(.headline).foregroundStyle(Theme.sub)
            dateButton(customEnd) { editingEnd = true }
        }
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $editingStart) {
            DatePickSheet(initial: customStart) { customStart = $0 }
        }
        .sheet(isPresented: $editingEnd) {
            DatePickSheet(initial: customEnd) { customEnd = $0 }
        }
    }

    private func dateButton(_ date: Date, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(OmnyDateFormat.fullDay(date))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.accent)
                .lineLimit(1).minimumScaleFactor(0.7)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Theme.fill, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(PressableStyle())
        .frame(maxWidth: .infinity)
    }

    // MARK: C. 收支统计宫格

    private var statsCard: some View {
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return VStack(alignment: .leading, spacing: 12) {
            Text("收支统计").font(.headline).foregroundStyle(Theme.text)
            LazyVGrid(columns: cols, spacing: 10) {
                // 支出：可点进清单
                NavigationLink {
                    ExpenseItemListView(title: "支出明细",
                                        items: summary.items(direction: .expense))
                } label: {
                    statTile("支出", ExpenseFormat.amount(summary.totalExpense, signed: false),
                             Theme.red, tappable: true)
                }
                .buttonStyle(PressableStyle())
                // 收入：可点进清单
                NavigationLink {
                    ExpenseItemListView(title: "收入明细",
                                        items: summary.items(direction: .income))
                } label: {
                    statTile("收入", ExpenseFormat.amount(summary.totalIncome, signed: false),
                             Theme.green, tappable: true)
                }
                .buttonStyle(PressableStyle())
                // 日均支出 / 结余：不可点
                statTile("日均支出",
                         ExpenseFormat.amount(summary.dailyAverageExpense(dayCount: window.dayCount),
                                              signed: false),
                         Theme.text, tappable: false)
                statTile("结余", ExpenseFormat.balance(summary.balance), Theme.text, tappable: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func statTile(_ label: String, _ value: String, _ color: Color, tappable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text(label).font(.caption).foregroundStyle(Theme.sub)
                if tappable {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold)).foregroundStyle(Theme.sub)
                }
            }
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.fill, in: .rect(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    // MARK: D. 支出分类详情

    /// 分类行（名称 + 归属大类 + 金额 + 笔数），已按金额倒序
    private var categoryRows: [(name: String, major: String, amount: Decimal, count: Int)] {
        if donutBySub {
            return summary.bySubAll(direction: donutDirection)
                .map { (name: $0.sub, major: $0.major, amount: $0.amount, count: $0.count) }
        } else {
            return summary.byMajor(direction: donutDirection)
                .map { (name: $0.major, major: $0.major, amount: $0.amount, count: $0.count) }
        }
    }

    /// 名称 → 颜色：按金额倒序稳定地从色板取色（超出色板长度则循环复用）
    private var categoryColorMap: [String: Color] {
        let palette = Theme.ExpenseColor.palette
        var map: [String: Color] = [:]
        for (i, row) in categoryRows.enumerated() where map[row.name] == nil {
            map[row.name] = palette[i % palette.count]
        }
        return map
    }

    /// 当前方向总额（占比 / 圆心数值用）
    private var donutTotal: Decimal {
        donutDirection == .expense ? summary.totalExpense : summary.totalIncome
    }

    private var donutSegments: [DonutChart.Segment] {
        categoryRows.map { row in
            DonutChart.Segment(label: row.name,
                               value: dbl(row.amount),
                               color: categoryColorMap[row.name] ?? Theme.ExpenseColor.other)
        }
    }

    private var categoryCard: some View {
        VStack(spacing: 14) {
            HStack {
                Text("\(donutDirection == .expense ? "支出" : "收入")分类详情")
                    .font(.headline).foregroundStyle(Theme.text)
                Spacer()
                Picker("", selection: $donutBySub) {
                    Text("大类").tag(false)
                    Text("子类").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
            }

            if categoryRows.isEmpty {
                Text("本周期无\(donutDirection == .expense ? "支出" : "收入")记录")
                    .font(.subheadline).foregroundStyle(Theme.sub)
                    .frame(height: 120)
            } else {
                DonutChart(segments: donutSegments,
                           centerTitle: donutDirection == .expense ? "总支出" : "总收入",
                           centerValue: ExpenseFormat.compact(donutTotal))
                    .frame(height: 230)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.snappy) {
                            donutDirection = donutDirection == .expense ? .income : .expense
                        }
                    }
            }

            Picker("", selection: $donutDirection) {
                Text("支出").tag(ExpenseDirection.expense)
                Text("收入").tag(ExpenseDirection.income)
            }
            .pickerStyle(.segmented)

            if !categoryRows.isEmpty {
                VStack(spacing: 10) {
                    ForEach(categoryRows, id: \.name) { row in
                        categoryRow(row)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private func categoryRow(_ row: (name: String, major: String, amount: Decimal, count: Int)) -> some View {
        let color = categoryColorMap[row.name] ?? Theme.ExpenseColor.other
        let pct = donutTotal > 0 ? dbl(row.amount / donutTotal) : 0
        let icon = ExpenseCategoryAppearance.shared.currentIcon(major: row.major)
        return HStack(spacing: 12) {
            ExpenseCategoryChip(appearance: CategoryAppearance(icon: icon, color: color), size: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(row.name).font(.subheadline).foregroundStyle(Theme.text).lineLimit(1)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.fill)
                        Capsule().fill(color.gradient)
                            .frame(width: max(4, geo.size.width * pct))
                    }
                }
                .frame(height: 5)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(ExpenseFormat.amount(row.amount, signed: false))
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .monospacedDigit().foregroundStyle(Theme.text)
                Text("\(row.count)笔").font(.caption).foregroundStyle(Theme.sub)
            }
        }
    }

    // MARK: E. 收支趋势折线

    private var trendCard: some View {
        VStack(spacing: 12) {
            HStack {
                Text("\(trendMetric.rawValue)统计图").font(.headline).foregroundStyle(Theme.text)
                Spacer()
            }
            Chart(ExpenseStats.series(items, period: period, window: window)) { p in
                LineMark(x: .value("时间", p.label),
                         y: .value(trendMetric.rawValue, dbl(trendMetric.value(p))))
                    .foregroundStyle(trendMetric.color)
                    .interpolationMethod(.catmullRom)
            }
            .frame(height: 200)

            Picker("", selection: $trendMetric) {
                ForEach(TrendMetric.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
        }
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    // MARK: 工具

    private func dbl(_ d: Decimal) -> Double { NSDecimalNumber(decimal: d).doubleValue }
}

// MARK: - 自定义区间日期选择弹窗

/// 日历式选日：起/止各弹一次，选完回写。带年月滚轮切月。
private struct DatePickSheet: View {
    let initial: Date
    let onDone: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var temp: Date?

    init(initial: Date, onDone: @escaping (Date) -> Void) {
        self.initial = initial
        self.onDone = onDone
        _temp = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                MonthCalendarView(selection: $temp, allowMonthPicker: true)
                    .cardStyle()
                    .padding(Theme.Space.page)
            }
            .background(Theme.screen)
            .navigationTitle("选择日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        if let temp { onDone(temp) }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
