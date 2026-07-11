import SwiftUI
import SwiftData
import OmnyCore

/// 手动记账表单：用户直接填结构化字段入库，不经文本解析。
/// 与自动解析（银行短信/截图）互补——现金、AA、无短信的消费靠手动补。
/// `editing` 非空时为编辑已有记账（字段回填、保存回写同一条），空则新建。
struct ManualExpenseView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    /// 编辑目标；nil 为新建
    var editing: InboxItem?

    @State private var direction: ExpenseDirection = .expense
    @State private var amountText = ""
    @State private var merchant = ""
    @State private var channel = ""
    @State private var cardTail = ""
    @State private var occurredAt = Date()
    // 分类：空串表示「未分类」（用户可不选）
    @State private var categoryMajor = ""
    @State private var categorySub = ""

    /// 大类有序列表（分类池是字典，排序保证选择器稳定）
    private var majors: [String] { settings.expenseCategoryPool.keys.sorted() }
    /// 当前大类下的细分列表
    private var subs: [String] { settings.expenseCategoryPool[categoryMajor] ?? [] }

    /// 金额校验：正数 Decimal 才算有效（钱的精度用 Decimal，不碰 Double）
    private var amount: Decimal? {
        let trimmed = amountText.trimmingCharacters(in: .whitespaces)
        guard let value = Decimal(string: trimmed), value > 0 else { return nil }
        return value
    }

    private var canSave: Bool { amount != nil }

    var body: some View {
        Form {
            Section {
                Picker("方向", selection: $direction) {
                    Text("支出").tag(ExpenseDirection.expense)
                    Text("收入").tag(ExpenseDirection.income)
                }
                .pickerStyle(.segmented)

                HStack {
                    Text(direction == .income ? "+" : "-")
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(direction == .income ? Theme.green : Theme.text)
                    TextField("金额", text: $amountText)
                        .keyboardType(.decimalPad)
                        .font(.title3.monospacedDigit())
                }
            } header: {
                Text("金额")
            }

            Section("分类") {
                Picker("大类", selection: $categoryMajor) {
                    Text("未分类").tag("")
                    ForEach(majors, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: categoryMajor) { _, _ in
                    // 换大类后细分若不再合法则清空
                    if !subs.contains(categorySub) { categorySub = "" }
                }
                if !categoryMajor.isEmpty {
                    Picker("细分", selection: $categorySub) {
                        Text("不细分").tag("")
                        ForEach(subs, id: \.self) { Text($0).tag($0) }
                    }
                }
            }

            Section("详情") {
                LabeledContent("商户") {
                    TextField("如 美团、星巴克", text: $merchant)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("渠道") {
                    TextField("如 招商银行、支付宝", text: $channel)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("卡尾号") {
                    TextField("如 6789", text: $cardTail)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                DatePicker("时间", selection: $occurredAt)
            }
        }
        .navigationTitle(editing == nil ? "手动记账" : "编辑记账")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save).disabled(!canSave)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }
            }
        }
        .onAppear(perform: loadIfEditing)
    }

    /// 编辑模式：把已有条目字段回填到表单
    private func loadIfEditing() {
        guard let item = editing else { return }
        direction = item.expenseDirection
        amountText = item.amount.map { "\($0)" } ?? ""
        merchant = item.merchant ?? ""
        channel = item.channel ?? ""
        cardTail = item.cardTail ?? ""
        occurredAt = item.occurredAt ?? Date()
        categoryMajor = item.categoryMajor ?? ""
        categorySub = item.categorySub ?? ""
    }

    private func save() {
        guard let amount else { return }
        func clean(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        let info = ExpenseInfo(
            direction: direction,
            amount: amount,
            merchant: clean(merchant),
            categoryMajor: clean(categoryMajor),
            categorySub: clean(categorySub),
            channel: clean(channel),
            cardTail: clean(cardTail)
        )
        Ingestor.addManualExpense(info, occurredAt: occurredAt,
                                  editing: editing, context: context)
        dismiss()
    }
}
