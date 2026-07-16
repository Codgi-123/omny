import SwiftUI
import SwiftData
import OmnyCore

/// 记账详情（issue #28 四「账单详情调整」）：
/// 顶部大图标 + 金额；中部可编辑卡片组（账单类型 / 时间 / 金额，逐行点开对应编辑器）；
/// 底部只读字段（空则隐藏）与删除。改动直接写 @Bindable item 后 save()。
struct ExpenseDetailView: View {
    @Bindable var item: InboxItem
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var showCategoryPicker = false
    @State private var showRepickAfterToggle = false
    @State private var showTimeEdit = false
    @State private var showAmountEdit = false
    @State private var showDeleteConfirm = false

    private var appearance: CategoryAppearance {
        ExpenseCategoryAppearance.shared.appearance(major: item.categoryMajor, sub: item.categorySub)
    }
    private var isIncome: Bool { item.expenseDirection == .income }

    var body: some View {
        List {
            // MARK: 第一部分 —— 大图标 + 分类名（整块可点改分类）+ 金额大字
            Section {
                Button { showCategoryPicker = true } label: {
                    HStack(spacing: 14) {
                        ExpenseCategoryChip(appearance: appearance, size: 60)
                        Text(categoryText)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.text)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.sub)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                Text(ExpenseFormat.amount(item.amount, direction: item.expenseDirection))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isIncome ? Theme.green : Theme.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            // MARK: 第二部分 —— 可编辑卡片组
            Section {
                // 1. 账单类型：点击切换方向，切后立刻重选类别
                Button { toggleDirection() } label: {
                    editRow("账单类型", value: isIncome ? "收入" : "支出",
                            valueColor: isIncome ? Theme.green : Theme.red)
                }
                .buttonStyle(.plain)

                // 2. 时间：点击弹出日期 + 时分编辑器
                Button { showTimeEdit = true } label: {
                    editRow("时间", value: OmnyDateFormat.fullDateTime(item.occurredAt ?? .now))
                }
                .buttonStyle(.plain)

                // 3. 金额：点击弹出计算器改金额
                Button { showAmountEdit = true } label: {
                    editRow("金额", value: ExpenseFormat.amount(item.amount, direction: item.expenseDirection),
                            valueColor: isIncome ? Theme.green : Theme.red)
                }
                .buttonStyle(.plain)
            }

            // MARK: 第三部分 —— 只读字段（空字段隐藏）
            Section {
                if let note = item.expenseNote, !note.isEmpty {
                    field("备注", note)
                }
                if let merchant = item.merchant, !merchant.isEmpty {
                    field("商户", merchant)
                }
                if let channel = item.channel, !channel.isEmpty {
                    field("支付方式", channel)
                }
                if let tail = item.cardTail, !tail.isEmpty {
                    field("卡尾号", tail)
                }
                LabeledContent("来源") { StatusTag(text: item.source.rawValue) }
                if let txn = item.txnID, !txn.isEmpty {
                    field("交易单号", txn, mono: true)
                }
            }

            // MARK: 删除
            Section {
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Text("删除这条记账").frame(maxWidth: .infinity)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("记账详情")
        .navigationBarTitleDisplayMode(.inline)
        // 改分类
        .sheet(isPresented: $showCategoryPicker) {
            CategoryPickerSheet(direction: item.expenseDirection,
                                initialMajor: item.categoryMajor ?? "",
                                initialSub: item.categorySub ?? "") { major, sub in
                item.categoryMajor = major.isEmpty ? nil : major
                item.categorySub = sub.isEmpty ? nil : sub
                save()
            }
        }
        // 切换收支后重选类别（收支分类池不同）
        .sheet(isPresented: $showRepickAfterToggle) {
            CategoryPickerSheet(direction: item.expenseDirection,
                                initialMajor: "", initialSub: "") { major, sub in
                item.categoryMajor = major.isEmpty ? nil : major
                item.categorySub = sub.isEmpty ? nil : sub
                save()
            }
        }
        // 改时间
        .sheet(isPresented: $showTimeEdit) {
            TimeEditSheet(initial: item.occurredAt ?? .now) { newDate in
                item.occurredAt = newDate
                save()
            }
        }
        // 改金额
        .sheet(isPresented: $showAmountEdit) {
            AmountEditorSheet(initialAmount: item.amount ?? 0, direction: item.expenseDirection) { amt in
                item.amount = amt
                save()
            }
        }
        .confirmationDialog("确认删除这条记账？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                context.delete(item)
                try? context.save()
                dismiss()
            }
        }
    }

    // MARK: - 行为

    /// 切换收支方向：取反并落库，随后弹分类选择让用户按新方向重选类别
    private func toggleDirection() {
        item.expenseDirection = isIncome ? .expense : .income
        item.categoryMajor = nil
        item.categorySub = nil
        save()
        showRepickAfterToggle = true
    }

    private func save() {
        try? context.save()
    }

    // MARK: - 子视图

    private var categoryText: String {
        let parts = [item.categoryMajor, item.categorySub].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? "未分类" : parts.joined(separator: " · ")
    }

    /// 可编辑行：左标题 + 右值 + 灰箭头
    private func editRow(_ key: String, value: String, valueColor: Color = Theme.text) -> some View {
        HStack {
            Text(key).foregroundStyle(Theme.text)
            Spacer(minLength: 8)
            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.sub)
        }
        .contentShape(Rectangle())
    }

    /// 只读行
    private func field(_ key: String, _ value: String, mono: Bool = false) -> some View {
        LabeledContent(key) {
            Text(value)
                .font(mono ? .caption.monospaced() : .body)
                .foregroundStyle(mono ? Theme.sub : Theme.text)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - 时间编辑弹窗（账单详情「时间」行点击弹出）

/// 改日期 + 时分：月历选日期（保留时分），下方一行点开滚轮改时分。完成回传合成后的 Date。
private struct TimeEditSheet: View {
    let initial: Date
    var onDone: (Date) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var working: Date
    /// 时分滚轮是否展开
    @State private var showTimeWheel = false

    init(initial: Date, onDone: @escaping (Date) -> Void) {
        self.initial = initial
        self.onDone = onDone
        _working = State(initialValue: initial)
    }

    /// 月历选中日：读取 working，写入时把新日期的年月日与 working 的时分合并
    private var dayBinding: Binding<Date?> {
        Binding(
            get: { working },
            set: { newDay in
                if let newDay { working = Self.merge(day: newDay, time: working) }
            }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    MonthCalendarView(selection: dayBinding, allowMonthPicker: true)
                        .padding(Theme.Space.cardPad)
                        .cardStyle()

                    // 时分行：点右侧时分展开滚轮
                    VStack(spacing: 0) {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { showTimeWheel.toggle() }
                        } label: {
                            HStack {
                                Text("时间").foregroundStyle(Theme.text)
                                Spacer()
                                Text(Self.hm.string(from: working))
                                    .foregroundStyle(showTimeWheel ? Theme.accent : Theme.sub)
                                    .monospacedDigit()
                            }
                            .padding(Theme.Space.cardPad)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if showTimeWheel {
                            DatePicker("", selection: $working, displayedComponents: .hourAndMinute)
                                .datePickerStyle(.wheel)
                                .labelsHidden()
                                .frame(maxWidth: .infinity)
                                .padding(.bottom, 4)
                        }
                    }
                    .cardStyle()
                }
                .padding(Theme.Space.page)
            }
            .background(Theme.screen)
            .navigationTitle("修改时间")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { onDone(working); dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
    }

    /// 取 day 的年月日 + time 的时分秒，合成新 Date
    private static func merge(day: Date, time: Date) -> Date {
        let cal = Calendar.current
        let d = cal.dateComponents([.year, .month, .day], from: day)
        let t = cal.dateComponents([.hour, .minute, .second], from: time)
        var c = DateComponents()
        c.year = d.year; c.month = d.month; c.day = d.day
        c.hour = t.hour; c.minute = t.minute; c.second = t.second
        return cal.date(from: c) ?? time
    }

    private static let hm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f
    }()
}
