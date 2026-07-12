import AppIntents
import SwiftUI
import OmnyCore

/// 「确认记账」的 interactive snippet 视图：展示一笔草稿的各字段，点字段触发子编辑 Intent。
/// 纯渲染——草稿由 ExpenseSnippetIntent.perform 从共享 store 读好后传入（子编辑完成系统会重调 perform）。
/// 点金额/备注 → 子 Intent 的 @Parameter 未预填 → 系统弹输入框（「点字段弹二级弹窗」即此机制）；
/// 点收支 → 直接切换；点分类 → 子 Intent 带动态候选 → 系统弹选择。
///
/// Button/Toggle 必须用 AppIntent 驱动（同 widget/Live Activity 交互规则）。
@available(iOS 26, *)
struct ExpenseConfirmSnippet: View {
    let draftID: String
    let draft: ExpenseDraft?

    var body: some View {
        if let draft {
            VStack(spacing: 0) {
                amountHeader(draft)
                Divider()
                fieldRow("收支", value: draft.direction == .income ? "收入" : "支出",
                         intent: EditExpenseDirectionIntent(draftID: draftID))
                fieldRow("分类", value: categoryText(draft),
                         intent: EditExpenseCategoryIntent(draftID: draftID))
                fieldRow("金额", value: amountText(draft),
                         intent: EditExpenseAmountIntent(draftID: draftID))
                fieldRow("时间", value: timeText(draft.occurredAt), intent: Optional<EditExpenseNoteIntent>.none)
                fieldRow("备注", value: draft.note ?? "无",
                         intent: EditExpenseNoteIntent(draftID: draftID))
                if let merchant = draft.merchant, !merchant.isEmpty {
                    fieldRow("商户", value: merchant, intent: Optional<EditExpenseNoteIntent>.none)
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
                rowContent(key, value, tappable: true)
            }
            .buttonStyle(.plain)
        } else {
            rowContent(key, value, tappable: false)
        }
    }

    private func rowContent(_ key: String, _ value: String, tappable: Bool) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(.primary)
            if tappable {
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 8).padding(.horizontal, 4)
    }

    private func amountText(_ d: ExpenseDraft) -> String {
        guard let a = d.amount else { return "未填" }
        return "¥\(a)"
    }
    private func categoryText(_ d: ExpenseDraft) -> String {
        let s = [d.categoryMajor, d.categorySub].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " / ")
        return s.isEmpty ? "未分类" : s
    }
    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }
}
