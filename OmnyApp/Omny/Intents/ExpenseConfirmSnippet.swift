import AppIntents
import SwiftUI
import OmnyCore

/// 「确认记账」的 interactive snippet 视图：展示一笔草稿的各字段，点字段触发子编辑 Intent。
/// 作为 requestConfirmation(content:) 的内联视图（iOS 18）。从共享 store 读草稿——子编辑 Intent
/// 的 perform 返回后系统重绘本视图（同 widget 交互刷新机制），故每次 body 求值读到最新草稿。
/// 点金额/备注 → 子 Intent 的 @Parameter 未预填 → 系统弹输入框（「点字段弹二级弹窗」即此机制）；
/// 点收支 → 直接切换；点分类 → 子 Intent 带动态候选 → 系统弹选择。
/// Button/Toggle 必须用 AppIntent 驱动（同 widget/Live Activity 交互规则）。
@available(iOS 18, *)
struct ExpenseConfirmSnippet: View {
    let draftID: String

    @MainActor
    var body: some View {
        // body 是 @MainActor：直接从共享 store 读最新草稿（子编辑后系统重绘会重新求值）
        let draft = UUID(uuidString: draftID).flatMap { ExpenseDraftStore.shared.get($0) }
        if let draft {
            VStack(spacing: 0) {
                amountHeader(draft)
                Divider()
                editRow("收支", value: draft.direction == .income ? "收入" : "支出",
                        intent: EditExpenseDirectionIntent(draftID: draftID))
                editRow("分类", value: categoryText(draft),
                        intent: EditExpenseCategoryIntent(draftID: draftID))
                editRow("金额", value: amountText(draft),
                        intent: EditExpenseAmountIntent(draftID: draftID))
                readRow("时间", value: timeText(draft.occurredAt))
                editRow("备注", value: draft.note ?? "无",
                        intent: EditExpenseNoteIntent(draftID: draftID))
                if let merchant = draft.merchant, !merchant.isEmpty {
                    readRow("商户", value: merchant)
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

    /// 可点字段：点击触发子编辑 Intent（系统随后自动重调 SnippetIntent.perform 刷新）
    private func editRow<I: AppIntent>(_ key: String, value: String, intent: I) -> some View {
        Button(intent: intent) {
            rowContent(key, value, tappable: true)
        }
        .buttonStyle(.plain)
    }

    /// 只读字段
    private func readRow(_ key: String, value: String) -> some View {
        rowContent(key, value, tappable: false)
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
