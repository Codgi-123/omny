import SwiftUI
import SwiftData
import OmnyCore

/// 收支分析：环状图（按大类占比）+ 引线式图例 + 大类→细分→单据逐级下钻。
/// 支出/收入可切换。
struct ExpenseAnalysisView: View {
    let summary: ExpenseSummary

    @State private var direction: ExpenseDirection = .expense
    @State private var expandedMajor: String?

    /// 当前方向的大类聚合（金额倒序）
    private var majors: [(major: String, amount: Decimal, count: Int)] {
        summary.byMajor(direction: direction)
    }
    private var total: Decimal {
        direction == .expense ? summary.totalExpense : summary.totalIncome
    }
    /// 大类 → 颜色映射（本图内不重复，按金额倒序的分段顺序分配）。
    /// 环状图分段、图例、下钻列表色点共用，保证三处颜色一致。
    private var majorColorMap: [String: Color] {
        let palette = Theme.ExpenseColor.palette
        var map: [String: Color] = [:]
        for (index, m) in majors.enumerated() {
            map[m.major] = palette[index % palette.count]
        }
        return map
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
                            .frame(height: 230)
                    }
                }
                .cardStyle()
                .listRowInsets(EdgeInsets(top: 4, leading: Theme.Space.page,
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

    private var directionToggle: some View {
        Picker("", selection: $direction) {
            Text("支出").tag(ExpenseDirection.expense)
            Text("收入").tag(ExpenseDirection.income)
        }
        .pickerStyle(.segmented)
        .onChange(of: direction) { _, _ in expandedMajor = nil }
    }

    // MARK: 大类行

    private func majorRow(_ m: (major: String, amount: Decimal, count: Int)) -> some View {
        let pct = total > 0 ? NSDecimalNumber(decimal: m.amount / total).doubleValue : 0
        let color = majorColorMap[m.major] ?? Theme.ExpenseColor.other
        return Button {
            withAnimation(.snappy) {
                expandedMajor = (expandedMajor == m.major) ? nil : m.major
            }
        } label: {
            HStack(spacing: 12) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(m.major).font(.body).foregroundStyle(Theme.text)
                Text("\(Int((pct * 100).rounded()))%")
                    .font(.caption).foregroundStyle(Theme.sub).monospacedDigit()
                Spacer()
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
