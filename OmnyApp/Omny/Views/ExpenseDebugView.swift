import SwiftUI
import SwiftData
import OmnyCore

/// 记账临时调试入口（放设置里，功能测试用）。
/// 粘贴一段动账短信 → 走完整解析管线入库 → 下方列表展示 expense 条目。
/// 正式的 tab 结构调整待链路验证通过后再做。
struct ExpenseDebugView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \InboxItem.createdAt, order: .reverse) private var items: [InboxItem]

    @State private var input = ""
    @State private var parsing = false
    @State private var lastResult: String?
    @State private var resultOK = false
    /// 手动记账表单：新建时 .some(nil)，编辑已有条目时 .some(item)
    @State private var editingSheet: EditingSheet?

    /// sheet(item:) 需要 Identifiable；用包装区分「新建」与「编辑某条」
    private struct EditingSheet: Identifiable {
        let id: UUID
        let item: InboxItem?
    }

    private var expenses: [InboxItem] { items.filter { $0.kind == .expense } }

    var body: some View {
        Form {
            Section {
                Button {
                    editingSheet = EditingSheet(id: UUID(), item: nil)
                } label: {
                    Label("手动记账", systemImage: "plus.circle")
                }
            } footer: {
                Text("直接填金额、商户、分类入库，不经文本解析。现金、AA、无短信的消费用这个补。")
            }

            Section {
                TextField("粘贴一条动账短信，如「【招商银行】您尾号1234的储蓄卡消费128.50元」", text: $input, axis: .vertical)
                    .lineLimit(3...8)
                Button {
                    parse()
                } label: {
                    HStack {
                        Label("解析并入库", systemImage: "arrow.down.doc")
                        if parsing { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(parsing || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("测试输入")
            } footer: {
                if let lastResult {
                    Text(lastResult).foregroundStyle(resultOK ? Theme.green : Theme.red)
                } else {
                    Text("走与短信快捷指令相同的解析管线。配了 LLM 走结构化抽取 + 异步补分类；未配则纯正则降级。")
                }
            }

            Section("已记账 \(expenses.count) 条") {
                if expenses.isEmpty {
                    Text("暂无记账条目").foregroundStyle(Theme.sub)
                } else {
                    ForEach(expenses) { item in
                        Button {
                            editingSheet = EditingSheet(id: item.id, item: item)
                        } label: {
                            ExpenseDebugRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for i in offsets { context.delete(expenses[i]) }
                        try? context.save()
                    }
                }
            }
        }
        .navigationTitle("记账（调试）")
        .sheet(item: $editingSheet) { sheet in
            NavigationStack {
                ManualExpenseView(editing: sheet.item)
            }
        }
    }

    private func parse() {
        parsing = true
        lastResult = nil
        let text = input
        Task {
            let result = await Ingestor.ingest(text: text, source: .manual,
                                               allowedTypes: [.expense], context: context)
            resultOK = !result.isEmpty
            lastResult = result.isEmpty
                ? "未识别为记账（检查是否含金额 + 交易动词）"
                : "已入库 \(result.count) 条"
            if resultOK { input = "" }
            parsing = false
        }
    }
}

private struct ExpenseDebugRow: View {
    let item: InboxItem

    private var amountText: String {
        guard let amount = item.amount else { return "—" }
        let sign = item.expenseDirection == .income ? "+" : "-"
        return "\(sign)\(amount)"
    }

    private var category: String {
        [item.categoryMajor, item.categorySub].compactMap { $0 }.joined(separator: " / ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.merchant ?? item.channel ?? "未知")
                    .font(.body)
                Spacer()
                Text(amountText)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(item.expenseDirection == .income ? Theme.green : Theme.text)
            }
            HStack(spacing: 8) {
                if !category.isEmpty {
                    Text(category).font(.caption).foregroundStyle(Theme.accent)
                }
                if let tail = item.cardTail {
                    Text("尾号\(tail)").font(.caption).foregroundStyle(Theme.sub)
                }
                if let at = item.occurredAt {
                    Text(at.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(Theme.sub)
                }
                if item.needsReview {
                    Text("待确认").font(.caption).foregroundStyle(Theme.red)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
