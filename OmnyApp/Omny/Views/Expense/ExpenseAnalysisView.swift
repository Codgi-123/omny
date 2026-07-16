import SwiftUI
import SwiftData
import OmnyCore

/// 收支分析：收支统计宫格 + 环状图（按大类占比）+ 引线式图例 + 大类→细分→单据逐级下钻。
/// 支出/收入可切换。
struct ExpenseAnalysisView: View {
    let summary: ExpenseSummary
    /// 当前所选月份（算日均支出用）
    var month: Date = .now

    @State private var direction: ExpenseDirection = .expense
    @State private var expandedMajor: String?

    /// 当前方向的大类聚合（金额倒序）
    private var majors: [(major: String, amount: Decimal, count: Int)] {
        summary.byMajor(direction: direction)
    }
    private var total: Decimal {
        direction == .expense ? summary.totalExpense : summary.totalIncome
    }
    /// 大类 → 颜色映射：优先用分类签名色（与列表行图标一色，扇区↔行一眼对上），
    /// 撞色时（自定义分类 hash 兜底可能重复）顺延取色板中未用过的一色，保证本图内不重复。
    /// 环状图分段、排行行图标、下钻列表共用。
    private var majorColorMap: [String: Color] {
        let palette = Theme.ExpenseColor.palette
        var map: [String: Color] = [:]
        var used = Set<Color>()
        for m in majors {
            var color = ExpenseCategoryAppearance.shared.appearance(major: m.major).color
            if used.contains(color) {
                color = palette.first { !used.contains($0) } ?? color
            }
            used.insert(color)
            map[m.major] = color
        }
        return map
    }

    /// 日均支出：当月已过天数（本月）或整月天数（历史月）摊平总支出
    private var dailyAverage: Decimal {
        let cal = Calendar.current
        let days: Int
        if cal.isDate(month, equalTo: .now, toGranularity: .month) {
            days = cal.component(.day, from: .now)
        } else {
            days = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        }
        guard days > 0 else { return summary.totalExpense }
        return summary.totalExpense / Decimal(days)
    }

    /// 环状图分段数据（大类名 + 金额 + 色）。颜色取自 majorColorMap（同图不重复）。
    private var segments: [DonutChart.Segment] {
        majors.map { m in
            DonutChart.Segment(
                label: m.major,
                value: NSDecimalNumber(decimal: m.amount).doubleValue,
                color: majorColorMap[m.major] ?? Theme.ExpenseColor.other)
        }
    }

    var body: some View {
        List {
            // 收支统计宫格：月度关键指标一屏总览
            Section {
                statsGrid
                    .listRowInsets(EdgeInsets(top: 4, leading: Theme.Space.page,
                                              bottom: 0, trailing: Theme.Space.page))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                VStack(spacing: 16) {
                    directionToggle
                    if segments.isEmpty {
                        Text("本月无\(direction == .expense ? "支出" : "收入")记录")
                            .font(.subheadline).foregroundStyle(Theme.sub)
                            .frame(height: 120)
                    } else {
                        DonutChart(segments: segments,
                                   centerTitle: direction == .expense ? "总支出" : "总收入",
                                   centerValue: ExpenseFormat.compact(total))
                            .frame(height: 230)
                    }
                }
                .cardStyle()
                .listRowInsets(EdgeInsets(top: 12, leading: Theme.Space.page,
                                          bottom: 12, trailing: Theme.Space.page))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            // 大类下钻列表
            Section {
                ForEach(majors, id: \.major) { m in
                    majorRow(m)
                    if expandedMajor == m.major {
                        subRows(major: m.major)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.screen)
    }

    // MARK: 收支统计宫格

    private var statsGrid: some View {
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: cols, spacing: 10) {
            statTile("支出", ExpenseFormat.amount(summary.totalExpense, signed: false), Theme.red)
            statTile("收入", ExpenseFormat.amount(summary.totalIncome, signed: false), Theme.green)
            statTile("结余", ExpenseFormat.balance(summary.balance), Theme.text)
            statTile("日均支出", ExpenseFormat.amount(dailyAverage, signed: false), Theme.text)
        }
    }

    private func statTile(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Theme.sub)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.card, in: .rect(cornerRadius: 12))
    }

    private var directionToggle: some View {
        Picker("", selection: $direction) {
            Text("支出").tag(ExpenseDirection.expense)
            Text("收入").tag(ExpenseDirection.income)
        }
        .pickerStyle(.segmented)
        .onChange(of: direction) { _, _ in expandedMajor = nil }
    }

    // MARK: 大类行

    /// 大类排行行：分类图标 + 名称/占比进度条 + 金额。图标底色与扇区同色，行↔图一眼对应。
    private func majorRow(_ m: (major: String, amount: Decimal, count: Int)) -> some View {
        let pct = total > 0 ? NSDecimalNumber(decimal: m.amount / total).doubleValue : 0
        let color = majorColorMap[m.major] ?? Theme.ExpenseColor.other
        let icon = ExpenseCategoryAppearance.shared.currentIcon(major: m.major)
        return Button {
            withAnimation(.snappy) {
                expandedMajor = (expandedMajor == m.major) ? nil : m.major
            }
        } label: {
            HStack(spacing: 12) {
                ExpenseCategoryChip(appearance: CategoryAppearance(icon: icon, color: color),
                                    size: 34)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(m.major).font(.subheadline).foregroundStyle(Theme.text)
                        Text(percentText(pct))
                            .font(.caption).foregroundStyle(Theme.sub).monospacedDigit()
                    }
                    // 占比进度条：淡底 + 分类色填充
                    GeometryReader { geo in
                        Capsule().fill(Theme.fill)
                        Capsule().fill(color.gradient)
                            .frame(width: max(4, geo.size.width * pct))
                    }
                    .frame(height: 5)
                }
                Spacer(minLength: 8)
                Text(ExpenseFormat.amount(m.amount, signed: false))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit().foregroundStyle(Theme.text)
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(Theme.sub)
                    .rotationEffect(.degrees(expandedMajor == m.major ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardCell()
    }

    /// 「76.9%」——一位小数，个位数占比更有区分度；100% 特判不带小数
    private func percentText(_ pct: Double) -> String {
        pct >= 0.9995 ? "100%" : String(format: "%.1f%%", pct * 100)
    }

    // MARK: 细分 + 单据

    @ViewBuilder
    private func subRows(major: String) -> some View {
        ForEach(summary.bySub(major: major, direction: direction), id: \.sub) { s in
            VStack(spacing: 0) {
                HStack {
                    Text(s.sub).font(.subheadline).foregroundStyle(Theme.text)
                    Text("\(s.items.count) 笔").font(.caption).foregroundStyle(Theme.sub)
                    Spacer()
                    Text(ExpenseFormat.amount(s.amount, signed: false))
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                        .monospacedDigit().foregroundStyle(Theme.text)
                }
                .padding(.vertical, 4)
                // 单据（商户 + 日期 + 金额）
                ForEach(s.items) { item in
                    NavigationLink { ExpenseDetailView(item: item) } label: {
                        HStack {
                            Text(item.merchant ?? item.channel ?? "未备注")
                                .font(.caption).foregroundStyle(Theme.sub).lineLimit(1)
                            Spacer()
                            Text(docDate(item) + " · " + ExpenseFormat.amount(item.amount, signed: false))
                                .font(.caption).foregroundStyle(Theme.sub).monospacedDigit()
                        }
                        .padding(.leading, 12).padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 22)
            .cardCell()
        }
    }

    private func docDate(_ item: InboxItem) -> String {
        OmnyDateFormat.shortMonthDay(item.occurredAt ?? item.createdAt)
    }
}

// MARK: - 环状图（原生绘制 + 引线图例）

/// 环状图：按占比画各扇区，中心显总额，每扇区从中点引折线到外侧标"分类 占比"。
/// 引线端点按扇区中点角度动态算，左半引到左、右半引到右。
struct DonutChart: View {
    struct Segment: Identifiable {
        let id = UUID()
        let label: String
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    let centerTitle: String
    let centerValue: String

    private var total: Double { segments.reduce(0) { $0 + $1.value } }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let radius = side * 0.30
            let lineWidth = side * 0.11

            ZStack {
                // 各扇区
                ForEach(Array(cumulative().enumerated()), id: \.offset) { _, arc in
                    Circle()
                        .trim(from: arc.start, to: arc.end)
                        .stroke(arc.segment.color,
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                        .rotationEffect(.degrees(-90))       // 从 12 点方向起画
                        .frame(width: radius * 2, height: radius * 2)
                        .position(center)
                }
                // 中心总额
                VStack(spacing: 2) {
                    Text(centerTitle).font(.caption).foregroundStyle(Theme.sub)
                    Text(centerValue)
                        .font(.system(.title3, design: .rounded).weight(.bold))
                        .monospacedDigit().foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(width: radius * 1.5)          // 限宽在内圆内，配合缩放防溢出
                .position(center)

                // 引线标注：只标占比 ≥ 5% 的扇区，太小的不引线（避免密集引线打架）
                ForEach(Array(cumulative().enumerated()), id: \.offset) { _, arc in
                    if arc.end - arc.start >= 0.05 {
                        leaderLine(arc: arc, center: center, radius: radius, lineWidth: lineWidth)
                    }
                }
            }
        }
    }

    /// 累计角度：每段的 start/end（0~1，占整圆比例）
    private func cumulative() -> [(segment: Segment, start: CGFloat, end: CGFloat)] {
        guard total > 0 else { return [] }
        var acc: CGFloat = 0
        return segments.map { seg in
            let frac = CGFloat(seg.value / total)
            let r = (segment: seg, start: acc, end: acc + frac)
            acc += frac
            return r
        }
    }

    /// 单条引线 + 文字：从扇区中点向外引一小段，再水平折到侧边标注
    @ViewBuilder
    private func leaderLine(arc: (segment: Segment, start: CGFloat, end: CGFloat),
                            center: CGPoint, radius: CGFloat, lineWidth: CGFloat) -> some View {
        let midFrac = (arc.start + arc.end) / 2
        let angle = Double(midFrac) * 2 * .pi - .pi / 2      // 转成弧度，-90° 对齐 12 点起点
        let outer = radius + lineWidth / 2
        // 引线起点（环外缘中点）
        let p1 = CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer)
        // 折点（再往外一点）
        let p2 = CGPoint(x: center.x + cos(angle) * (outer + 14), y: center.y + sin(angle) * (outer + 14))
        let isRight = cos(angle) >= 0
        // 水平引到侧边
        let p3 = CGPoint(x: p2.x + (isRight ? 12 : -12), y: p2.y)

        let pct = arc.end - arc.start

        ZStack {
            Path { p in p.move(to: p1); p.addLine(to: p2); p.addLine(to: p3) }
                .stroke(Theme.sub.opacity(0.4), lineWidth: 0.8)
            // 文字限宽 + 单行缩放，防长分类名冲出卡片；按左右侧对齐向外排
            Text("\(arc.segment.label) \(Int((pct * 100).rounded()))%")
                .font(.system(size: 10)).foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 58, alignment: isRight ? .leading : .trailing)
                .position(x: p3.x + (isRight ? 29 : -29), y: p3.y)
        }
    }
}
