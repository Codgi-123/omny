import AppIntents
import SwiftUI
import OmnyCore

/// 「确认记账」的 interactive snippet 视图：展示一笔草稿的各字段，点字段触发子编辑 Intent。
/// 点金额/备注 → 子 Intent 的 @Parameter 未预填 → 系统弹输入框（「点字段弹二级弹窗」即此机制）；
/// 点收支 → 直接切换；点分类 → 子 Intent 带动态候选 → 系统弹选择。改完 store 更新、snippet 刷新。
///
/// ⚠️ 真机验证重点：Button(intent:) 在 confirmation snippet 内触发子 Intent、子 Intent 改 store 后
/// snippet 是否自动 reload。若不自动刷新，可能需子 Intent 返回 .result(view:) 或 SnippetIntent 协议。
struct ExpenseConfirmSnippet: View {
    let draftID: UUID

    private var draft: ExpenseDraft? { ExpenseDraftStore.shared.get(draftID) }

    var body: some View {
        if let draft {
            VStack(spacing: 0) {
                amountHeader(draft)
                Divider()
                fieldRow("收支", value: draft.direction == .income ? "收入" : "支出",
                         intent: EditExpenseDirectionIntent(draftID: draftID.uuidString))
                fieldRow("分类", value: categoryText(draft),
                         intent: EditExpenseCategoryIntent(draftID: draftID.uuidString))
                fieldRow("金额", value: amountText(draft),
                         intent: EditExpenseAmountIntent(draftID: draftID.uuidString))
                fieldRow("时间", value: timeText(draft.occurredAt), intent: nil)
                fieldRow("备注", value: draft.note ?? "无",
                         intent: EditExpenseNoteIntent(draftID: draftID.uuidString))
                if let merchant = draft.merchant, !merchant.isEmpty {
                    fieldRow("商户", value: merchant, intent: nil)
                }
            }
            .padding(4)
        } else {
            Text("草稿已失效").foregroundStyle(.secondary)
        }
    }

    private func amountHeader(_ draft: ExpenseDraft) -> some View {
        HStack {
            Text(draft.direction == .income ? "收入" : "支出")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(amountText(draft))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(draft.direction == .income ? .green : .primary)
        }
        .padding(.vertical, 6).padding(.horizontal, 4)
    }

    /// 一行字段：有 intent 的可点（触发子编辑），无 intent 的只读
    @ViewBuilder
    private func fieldRow<I: AppIntent>(_ key: String, value: String, intent: I?) -> some View {
        if let intent {
            Button(intent: intent) {
                HStack {
                    Text(key).foregroundStyle(.secondary)
                    Spacer()
                    Text(value).foregroundStyle(.primary)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8).padding(.horizontal, 4)
        } else {
            HStack {
                Text(key).foregroundStyle(.secondary)
                Spacer()
                Text(value).foregroundStyle(.primary)
            }
            .padding(.vertical, 8).padding(.horizontal, 4)
        }
    }

    private func amountText(_ d: ExpenseDraft) -> String {
        guard let a = d.amount else { return "未填" }
        return "¥\(a)"
    }
    private func categoryText(_ d: ExpenseDraft) -> String {
        [d.categoryMajor, d.categorySub].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " / ").ifEmpty("未分类")
    }
    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
