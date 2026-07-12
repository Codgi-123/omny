import SwiftUI
import OmnyCore

// MARK: - 金额格式化

enum ExpenseFormat {
    /// 金额显示：¥ 前缀 + 千分位 + 两位小数。方向决定正负号。
    static func amount(_ value: Decimal?, direction: ExpenseDirection = .expense,
                       signed: Bool = true) -> String {
        guard let value else { return "—" }
        let n = NSDecimalNumber(decimal: value)
        let s = numberFormatter.string(from: n) ?? "\(value)"
        guard signed else { return "¥\(s)" }
        let sign = direction == .income ? "+" : "-"
        return "\(sign)¥\(s)"
    }

    /// 纯数值（无符号、无货币），给分析/统计的金额显示
    static func plain(_ value: Decimal) -> String {
        numberFormatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.groupingSeparator = ","
        return f
    }()
}

// MARK: - 月份聚合

/// 一组记账条目按月/天/分类的聚合结果。视图层拉全部 .expense 后本地算，不改模型。
struct ExpenseSummary {
    let items: [InboxItem]

    /// 支出合计（正数）
    var totalExpense: Decimal {
        items.filter { $0.expenseDirection == .expense }
            .reduce(0) { $0 + ($1.amount ?? 0) }
    }
    /// 收入合计（正数）
    var totalIncome: Decimal {
        items.filter { $0.expenseDirection == .income }
            .reduce(0) { $0 + ($1.amount ?? 0) }
    }
    /// 结余 = 收入 − 支出
    var balance: Decimal { totalIncome - totalExpense }

    /// 按天分组（用 occurredAt，缺失回退 createdAt），返回按日期倒序的 (day, items)
    func byDay() -> [(day: Date, items: [InboxItem])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: items) { item in
            cal.startOfDay(for: item.occurredAt ?? item.createdAt)
        }
        return groups.map { (day: $0.key, items: $0.value.sorted { effectiveDate($0) > effectiveDate($1) }) }
            .sorted { $0.day > $1.day }
    }

    /// 按大类聚合（只算支出或只算收入），返回按金额倒序的 (major, amount, count)
    func byMajor(direction: ExpenseDirection) -> [(major: String, amount: Decimal, count: Int)] {
        let filtered = items.filter { $0.expenseDirection == direction }
        let groups = Dictionary(grouping: filtered) { $0.categoryMajor ?? "未分类" }
        return groups.map { (major: $0.key,
                             amount: $0.value.reduce(0) { $0 + ($1.amount ?? 0) },
                             count: $0.value.count) }
            .sorted { $0.amount > $1.amount }
    }

    /// 某大类下按细分聚合
    func bySub(major: String, direction: ExpenseDirection) -> [(sub: String, amount: Decimal, items: [InboxItem])] {
        let filtered = items.filter {
            $0.expenseDirection == direction && ($0.categoryMajor ?? "未分类") == major
        }
        let groups = Dictionary(grouping: filtered) { $0.categorySub ?? "其他" }
        return groups.map { (sub: $0.key,
                             amount: $0.value.reduce(0) { $0 + ($1.amount ?? 0) },
                             items: $0.value.sorted { effectiveDate($0) > effectiveDate($1) }) }
            .sorted { $0.amount > $1.amount }
    }

    private func effectiveDate(_ item: InboxItem) -> Date { item.occurredAt ?? item.createdAt }
}

// MARK: - 月份工具

enum MonthTool {
    /// 某笔记账是否落在指定月份（用 occurredAt，缺失回退 createdAt）
    static func inMonth(_ item: InboxItem, month: Date) -> Bool {
        let cal = Calendar.current
        let d = item.occurredAt ?? item.createdAt
        return cal.isDate(d, equalTo: month, toGranularity: .month)
    }

    /// 月份标题 "2026年7月"
    static func title(_ month: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月"
        return f.string(from: month)
    }

    static func adding(_ months: Int, to month: Date) -> Date {
        Calendar.current.date(byAdding: .month, value: months, to: month) ?? month
    }
}

// MARK: - 记账行（明细/日历共用）

/// 一条记账列表行：分类图标 + 大类/细分 + 金额。
/// 商户名不在行内显示（可能很长），进详情看——符合原型定的信息层级。
struct ExpenseRow: View {
    let item: InboxItem

    private var appearance: CategoryAppearance {
        ExpenseCategoryAppearance.shared.appearance(major: item.categoryMajor, sub: item.categorySub)
    }
    private var isIncome: Bool { item.expenseDirection == .income }

    var body: some View {
        HStack(spacing: 12) {
            IconChip(symbol: appearance.symbol, color: appearance.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.categoryMajor ?? "未分类")
                    .font(.body)
                    .foregroundStyle(Theme.text)
                if let sub = item.categorySub, !sub.isEmpty {
                    Text(sub).font(.caption).foregroundStyle(Theme.sub)
                }
            }
            Spacer(minLength: 8)
            Text(ExpenseFormat.amount(item.amount, direction: item.expenseDirection))
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isIncome ? Theme.green : Theme.text)
            if item.needsReview {
                StatusTag(text: "待确认", color: Theme.red)
            }
        }
        .contentShape(Rectangle())
    }
}
