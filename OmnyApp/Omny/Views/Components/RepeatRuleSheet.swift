import SwiftUI
import OmnyCore

// MARK: - 重复规则选择（悬浮菜单 + 自定义 sheet，仿滴答）
// RepeatRuleMenu：锚定在 DueDateSheet「重复」行上方的悬浮圆角菜单（毛玻璃底、右侧勾选）；
// CustomRepeatSheet：「每 N 天/周/月/年」自定义页（频率大滚轮卡片 + 星期宫格）。
// 规则编码沿用 OmnyCore.TodoRepeatRule（d:1 / w:1:4 / m:1:16 / y:1:7-16 / weekday）。

/// 重复规则悬浮菜单：预设按截止日期动态生成（每周（周X）/ 每月（X日）/ 每年（X月X日）），
/// 「自定义」进入 CustomRepeatSheet；当前规则匹配某预设即在该行打勾，否则勾在「自定义」。
/// 由宿主（DueDateSheet）通过锚点定位到「重复」行上方，样式对齐时分浮层的悬浮卡片形态。
struct RepeatRuleMenu: View {
    /// TodoRepeatRule.encoded 原始字符串；nil = 不重复
    @Binding var rule: String?
    /// 当前选中的截止日期：用于生成预设编码与动态文案
    let referenceDate: Date
    /// 选中预设 / 点外部后由宿主收起浮层
    var onDismiss: () -> Void
    /// 进入自定义页（宿主负责收浮层后弹 sheet）
    var onCustom: () -> Void

    /// 浮层估算高度（宿主定位用）：7 行 × 行高 46 + 两条分组线 + 上下留白
    static let estimatedHeight: CGFloat = 46 * 7 + 2 * 9 + 16

    /// 预设行：code == nil 表示「无」
    private struct Preset: Identifiable {
        let code: String?
        let title: String
        var id: String { code ?? "none" }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(mainPresets) { presetRow($0) }
            groupDivider
            presetRow(weekdayPreset)
            groupDivider
            customRow
        }
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .rect(cornerRadius: 20))
        .shadow(color: .black.opacity(0.2), radius: 28, y: 10)
    }

    // MARK: 行

    private func presetRow(_ p: Preset) -> some View {
        Button {
            rule = p.code
            onDismiss()
        } label: {
            HStack {
                Text(p.title).font(.body).foregroundStyle(Theme.text)
                Spacer()
                if isChecked(p.code) {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 自定义：命中自定义规则时展示其 label + 勾选，恒带 chevron 提示还有一层
    private var customRow: some View {
        Button { onCustom() } label: {
            HStack(spacing: 6) {
                Text("自定义").font(.body).foregroundStyle(Theme.text)
                Spacer()
                if isCustomSelected, let label = currentLabel {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(Theme.sub)
                        .lineLimit(1)
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.sub)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var groupDivider: some View {
        Divider().padding(.vertical, 4)
    }

    // MARK: 预设与选中态

    /// 按 referenceDate 动态生成的主预设（编码均为 interval == 1）
    private var mainPresets: [Preset] {
        let cal = Calendar.current
        let weekday = Self.isoWeekday(of: referenceDate, calendar: cal)   // 1=周一…7=周日
        let day = cal.component(.day, from: referenceDate)
        let month = cal.component(.month, from: referenceDate)
        return [
            Preset(code: nil, title: "无"),
            Preset(code: "d:1", title: "每天"),
            Preset(code: "w:1:\(weekday)", title: "每周（\(Self.weekdayNames[weekday - 1])）"),
            Preset(code: "m:1:\(day)", title: "每月（\(day)日）"),
            Preset(code: "y:1:\(month)-\(day)", title: "每年（\(month)月\(day)日）"),
        ]
    }

    private var weekdayPreset: Preset { Preset(code: "weekday", title: "工作日") }

    /// 当前规则的规范化编码（parse 后重编码，容错书写差异）
    private var normalizedRule: String? {
        guard let rule else { return nil }
        return TodoRepeatRule.parse(rule)?.encoded ?? rule
    }

    private var currentLabel: String? {
        rule.flatMap { TodoRepeatRule.parse($0)?.label }
    }

    private func isChecked(_ code: String?) -> Bool { normalizedRule == code }

    /// 有规则但不匹配任何预设 → 勾在「自定义」
    private var isCustomSelected: Bool {
        guard let n = normalizedRule else { return false }
        if n == weekdayPreset.code { return false }
        return !mainPresets.contains { $0.code == n }
    }

    // MARK: 工具

    static let weekdayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    /// Calendar.weekday（1=周日…7=周六）→ 本项目约定（1=周一…7=周日）
    static func isoWeekday(of date: Date, calendar: Calendar = .current) -> Int {
        let wd = calendar.component(.weekday, from: date)
        return wd == 1 ? 7 : wd - 1
    }
}

/// 自定义重复：仿滴答清单。「频率」卡片内三列大字滚轮（每 | N | 天/周/月/年），
/// 卡片下方左对齐实时文案预览；单位=周时出现「星期」卡片（4+3 宫格胶囊，至少保留一个）；
/// 月/年按 referenceDate 的几号 / 月-日，不出额外选择器。
struct CustomRepeatSheet: View {
    @Binding var rule: String?
    let referenceDate: Date
    @Environment(\.dismiss) private var dismiss

    private enum RepeatUnit: CaseIterable, Identifiable {
        case day, week, month, year
        var id: Self { self }
        var label: String {
            switch self {
            case .day: "天"
            case .week: "周"
            case .month: "月"
            case .year: "年"
            }
        }
    }

    @State private var interval: Int
    @State private var unit: RepeatUnit
    /// 星期多选（1=周一…7=周日），仅单位=周时生效
    @State private var selectedWeekdays: Set<Int>
    /// 每月几号多选（1...31），仅单位=月时生效
    @State private var selectedMonthDays: Set<Int>
    /// 每年的月-日，仅单位=年时生效
    @State private var yearMonth: Int
    @State private var yearDay: Int

    init(rule: Binding<String?>, referenceDate: Date) {
        _rule = rule
        self.referenceDate = referenceDate

        let cal = Calendar.current
        let refWeekday = RepeatRuleMenu.isoWeekday(of: referenceDate, calendar: cal)
        let refDay = cal.component(.day, from: referenceDate)
        let refMonth = cal.component(.month, from: referenceDate)

        // 默认态：每 1 周期、选中 referenceDate 的星期/几号/月-日
        var interval = 1
        var unit = RepeatUnit.day
        var weekdays: Set<Int> = [refWeekday]
        var monthDays: Set<Int> = [refDay]
        var yMonth = refMonth
        var yDay = refDay

        // 当前已有规则时用它初始化滚轮 / chip 状态
        if let parsed = rule.wrappedValue.flatMap(TodoRepeatRule.parse) {
            switch parsed {
            case .daily(let i):
                interval = i; unit = .day
            case .weekly(let i, let wds):
                interval = i; unit = .week
                if !wds.isEmpty { weekdays = wds }
            case .monthly(let i, let ds):
                interval = i; unit = .month
                if !ds.isEmpty { monthDays = ds }
            case .yearly(let i, let m, let d):
                interval = i; unit = .year; yMonth = m; yDay = d
            case .weekdays:
                // 「工作日」≈ 每 1 周的周一~周五
                interval = 1; unit = .week; weekdays = [1, 2, 3, 4, 5]
            }
        }

        _interval = State(initialValue: min(max(interval, 1), 99))
        _unit = State(initialValue: unit)
        _selectedWeekdays = State(initialValue: weekdays)
        _selectedMonthDays = State(initialValue: monthDays)
        _yearMonth = State(initialValue: yMonth)
        _yearDay = State(initialValue: yDay)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    frequencyCard
                    // 实时文案预览：左对齐挂在频率卡片下方（仿滴答）
                    Text(composedRule.label)
                        .font(.footnote)
                        .foregroundStyle(Theme.sub)
                        .padding(.leading, 6)
                    switch unit {
                    case .day: EmptyView()
                    case .week: weekdayCard.padding(.top, 8)
                    case .month: monthDayCard.padding(.top, 8)
                    case .year: yearDateCard.padding(.top, 8)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 6)
                .padding(.bottom, 20)
            }
        }
        // 与 DueDateSheet 一致：系统分组底色，降低卡片与弹窗底的对比度
        .presentationBackground(Color(.systemGroupedBackground))
        // 高度按屏幕比例动态给：月宫格（5 行）出现时固定 560 会顶到底
        .presentationDetents([.fraction(0.72)])
        .presentationDragIndicator(.hidden)
    }

    // MARK: 头部：圆形 ✕ / ✓（样式同 DueDateSheet）

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 38, height: 38)
                    .background(Theme.fill, in: Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))

            Spacer()
            Text("自定义重复").font(.headline)
            Spacer()

            Button { confirm() } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Theme.accent, in: Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: 「频率」卡片：每 | N | 单位 三列大字滚轮

    private var frequencyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("频率")
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.text)
                .padding(.top, 14)
                .padding(.leading, 16)
            HStack(spacing: 0) {
                Text("每")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity)
                Picker("间隔", selection: $interval) {
                    ForEach(1...99, id: \.self) { n in
                        Text("\(n)").font(.title3.weight(.medium)).tag(n)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .clipped()
                Picker("单位", selection: $unit) {
                    ForEach(RepeatUnit.allCases) { u in
                        Text(u.label).font(.title3.weight(.medium)).tag(u)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .clipped()
            }
            .frame(height: 170)
        }
        .softCard(cornerRadius: 14)
    }

    // MARK: 「星期」卡片：4+3 宫格胶囊多选（单位=周）

    private var weekdayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("星期")
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.text)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                      spacing: 10) {
                ForEach(1...7, id: \.self) { d in
                    let selected = selectedWeekdays.contains(d)
                    Button { toggleWeekday(d) } label: {
                        Text(RepeatRuleMenu.weekdayNames[d - 1])
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .white : Theme.text)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.fill),
                                        in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle(scale: 0.92))
                }
            }
            .animation(.snappy(duration: 0.18), value: selectedWeekdays)
        }
        .padding(16)
        .softCard(cornerRadius: 14)
    }

    /// 至少保留一个选中：最后一个不可取消
    private func toggleWeekday(_ d: Int) {
        if selectedWeekdays.contains(d) {
            guard selectedWeekdays.count > 1 else { return }
            selectedWeekdays.remove(d)
        } else {
            selectedWeekdays.insert(d)
        }
    }

    // MARK: 「日期」卡片：1~31 宫格多选（单位=月）

    private var monthDayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("日期")
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.text)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7),
                      spacing: 6) {
                ForEach(1...31, id: \.self) { d in
                    let selected = selectedMonthDays.contains(d)
                    Button { toggleMonthDay(d) } label: {
                        Text("\(d)")
                            .font(.subheadline.weight(selected ? .semibold : .regular))
                            .foregroundStyle(selected ? .white : Theme.text)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.clear),
                                        in: Circle())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle(scale: 0.92))
                }
            }
            .animation(.snappy(duration: 0.18), value: selectedMonthDays)
            // 选了 29/30/31 时提示小月顺延语义，免得用户以为漏了
            if selectedMonthDays.contains(where: { $0 >= 29 }) {
                Text("当月没有的日期会顺延为当月最后一天")
                    .font(.caption2)
                    .foregroundStyle(Theme.sub)
            }
        }
        .padding(16)
        .softCard(cornerRadius: 14)
    }

    /// 至少保留一个选中：最后一个不可取消
    private func toggleMonthDay(_ d: Int) {
        if selectedMonthDays.contains(d) {
            guard selectedMonthDays.count > 1 else { return }
            selectedMonthDays.remove(d)
        } else {
            selectedMonthDays.insert(d)
        }
    }

    // MARK: 「日期」卡片：月 + 日双滚轮（单位=年）

    /// 各月可选的最大天数（2 月按 29 计，平年由规则运行时顺延为 28）
    private static let maxDayOfMonth = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]

    private var yearDateCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("日期")
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.text)
                .padding(.top, 14)
                .padding(.leading, 16)
            HStack(spacing: 0) {
                Picker("月", selection: $yearMonth) {
                    ForEach(1...12, id: \.self) { m in
                        Text("\(m) 月").font(.title3.weight(.medium)).tag(m)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .clipped()
                Picker("日", selection: $yearDay) {
                    ForEach(1...Self.maxDayOfMonth[yearMonth - 1], id: \.self) { d in
                        Text("\(d) 日").font(.title3.weight(.medium)).tag(d)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxWidth: .infinity)
                .clipped()
            }
            .frame(height: 170)   // 与「频率」卡片滚轮同高，切单位时卡片高度不跳
            // 换月后把日 clamp 进该月可选范围（如 3/31 → 2 月时落到 29）
            .onChange(of: yearMonth) { _, m in
                yearDay = min(yearDay, Self.maxDayOfMonth[m - 1])
            }
        }
        .softCard(cornerRadius: 14)
    }

    // MARK: 组装 / 确认

    /// 当前滚轮 + chip 状态对应的规则（供预览与写回）
    private var composedRule: TodoRepeatRule {
        switch unit {
        case .day: .daily(interval: interval)
        case .week: .weekly(interval: interval, weekdays: selectedWeekdays)
        case .month: .monthly(interval: interval, days: selectedMonthDays)
        case .year: .yearly(interval: interval, month: yearMonth, day: yearDay)
        }
    }

    private func confirm() {
        rule = composedRule.encoded
        dismiss()
    }
}
