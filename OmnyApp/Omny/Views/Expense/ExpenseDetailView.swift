import SwiftUI
import SwiftData
import OmnyCore

/// 记账详情：大图标 + 金额 + 大类·细分；字段列表（空字段隐藏）；编辑 / 删除。
struct ExpenseDetailView: View {
    @Bindable var item: InboxItem
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var showEdit = false
    @State private var showDeleteConfirm = false

    private var appearance: CategoryAppearance {
        ExpenseCategoryAppearance.shared.appearance(major: item.categoryMajor, sub: item.categorySub)
    }
    private var isIncome: Bool { item.expenseDirection == .income }

    var body: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    ExpenseCategoryChip(appearance: appearance, size: 60)
                    Text(ExpenseFormat.amount(item.amount, direction: item.expenseDirection))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(isIncome ? Theme.green : Theme.red)
                    Text(categoryText).font(.subheadline).foregroundStyle(Theme.sub)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                if let note = item.expenseNote, !note.isEmpty {
                    field("备注", note)
                }
                if let merchant = item.merchant, !merchant.isEmpty {
                    field("商户", merchant)
                }
                field("时间", timeText)
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

            Section {
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Text("删除这条记账").frame(maxWidth: .infinity)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("记账详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") { showEdit = true }
            }
        }
        .sheet(isPresented: $showEdit) {
            ExpenseEditView(editing: item, defaultDate: item.occurredAt ?? .now)
        }
        .confirmationDialog("确认删除？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                context.delete(item)
                try? context.save()
                dismiss()
            }
        }
    }

    private var categoryText: String {
        [item.categoryMajor, item.categorySub].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var timeText: String {
        OmnyDateFormat.fullDateTime(item.occurredAt ?? item.createdAt)
    }

    private func field(_ key: String, _ value: String, mono: Bool = false) -> some View {
        LabeledContent(key) {
            Text(value)
                .font(mono ? .caption.monospaced() : .body)
                .foregroundStyle(mono ? Theme.sub : Theme.text)
                .multilineTextAlignment(.trailing)
        }
    }
}
