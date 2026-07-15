import AppIntents
import SwiftUI
import OmnyCore

// 「确认记账」的 interactive snippet 视图（iOS 26+）。
//
// 渲染规则（同 widget）：视图是进程外渲染的快照，不能持状态、不能现场取数据——草稿与分类池
// 都由 ExpenseSnippetIntent.perform 读好传入；一切交互都是 Button(intent:)，且子 Intent 的
// 参数必须在构造时给全（真机实测：快捷指令后台 banner 上下文里，运行中再弹参数请求会被系统
// 吞掉直接结束运行，issue #15 的根因），所以金额用内嵌数字键盘、分类用两级 chips，
// 不走「未预填参数让系统弹输入框」。

@available(iOS 26, *)
struct ExpenseConfirmSnippet: View {
    let draftID: String
    let draft: ExpenseDraft?
    /// 分类池（大类顺序 + 各自细分），perform 读设置后传入
    let categoryPool: [CategoryGroup]

    struct CategoryGroup: Hashable {
        let major: String
        let subs: [String]
    }

    var body: some View {
        if let draft {
            switch draft.panel {
            case .main: mainPanel(draft)
            case .amount: amountPanel(draft)
            case .category: categoryPanel(draft)
            case .time: timePanel(draft)
            }
        } else {
            Text("草稿已失效，请重新运行快捷指令")
                .foregroundStyle(.secondary)
                .padding()
        }
    }

    // MARK: - 主面板（字段总览）

    private func mainPanel(_ draft: ExpenseDraft) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(draft.direction == .income ? "收入" : "支出")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(ExpenseConfirmFormat.amountText(draft.amount))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(draft.direction == .income ? .green : .primary)
            }
            .padding(.vertical, 6).padding(.horizontal, 4)
            Divider()
            fieldRow("收支", draft.direction == .income ? "收入" : "支出",
                     intent: FlipExpenseDirectionIntent(draftID: draftID))
            fieldRow("金额", ExpenseConfirmFormat.amountText(draft.amount),
                     intent: ShowExpensePanelIntent(draftID: draftID, panel: .amount))
            fieldRow("分类", ExpenseConfirmFormat.categoryText(draft),
                     intent: ShowExpensePanelIntent(draftID: draftID, panel: .category))
            fieldRow("时间", ExpenseConfirmFormat.timeText(draft.occurredAt),
                     intent: ShowExpensePanelIntent(draftID: draftID, panel: .time))
            if let merchant = draft.merchant, !merchant.isEmpty {
                readonlyRow("商户", merchant)
            }
            Text("点字段修改 · 底部按钮确认或取消")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
        .padding(8)
    }

    // MARK: - 金额面板（数字键盘）

    private func amountPanel(_ draft: ExpenseDraft) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("输入金额").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(draft.amountDraft.isEmpty ? "0" : draft.amountDraft)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 4)
            let rows: [[String]] = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], [".", "0", "⌫"]]
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { key in
                        padButton(key, intent: ExpenseAmountKeyIntent(draftID: draftID, key: key))
                    }
                }
            }
            HStack(spacing: 6) {
                actionButton("取消", tint: .secondary,
                             intent: ExpenseAmountKeyIntent(draftID: draftID, key: "cancel"))
                actionButton("确定", tint: .blue,
                             intent: ExpenseAmountKeyIntent(draftID: draftID, key: "done"))
            }
        }
        .padding(8)
    }

    // MARK: - 分类面板（大类 → 细分两级）

    @ViewBuilder
    private func categoryPanel(_ draft: ExpenseDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let major = draft.pendingMajor {
                Text("「\(major)」的细分").font(.caption).foregroundStyle(.secondary)
                chipsGrid(items: categoryPool.first { $0.major == major }?.subs ?? []) { sub in
                    PickExpenseCategoryIntent(draftID: draftID, major: major, sub: sub)
                }
                HStack(spacing: 6) {
                    actionButton("← 返回大类", tint: .secondary,
                                 intent: ShowExpensePanelIntent(draftID: draftID, panel: .category))
                    actionButton("只记「\(major)」", tint: .blue,
                                 intent: PickExpenseCategoryIntent(draftID: draftID, major: major, sub: ""))
                }
            } else {
                Text("选择大类").font(.caption).foregroundStyle(.secondary)
                if categoryPool.isEmpty {
                    Text("未配置分类池（App 设置 → 记账分类）")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    chipsGrid(items: categoryPool.map(\.major)) { major in
                        PickExpenseCategoryMajorIntent(draftID: draftID, major: major)
                    }
                }
                actionButton("取消", tint: .secondary,
                             intent: ShowExpensePanelIntent(draftID: draftID, panel: .main))
            }
        }
        .padding(8)
    }

    // MARK: - 时间面板（快捷项）

    private func timePanel(_ draft: ExpenseDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当前：\(ExpenseConfirmFormat.timeText(draft.occurredAt))（改日期保留时分）")
                .font(.caption).foregroundStyle(.secondary)
            chipsGrid(items: ["今天", "昨天", "前天", "此刻", "保持不变"]) { option in
                PickExpenseTimeIntent(draftID: draftID, option: option)
            }
        }
        .padding(8)
    }

    // MARK: - 通用小件

    /// 一行可点字段（点击进入对应编辑面板/直接切换）
    private func fieldRow(_ key: String, _ value: String, intent: some AppIntent) -> some View {
        Button(intent: intent) {
            HStack {
                Text(key).foregroundStyle(.secondary)
                Spacer()
                Text(value).foregroundStyle(.primary)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 8).padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }

    private func readonlyRow(_ key: String, _ value: String) -> some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(.primary)
        }
        .padding(.vertical, 8).padding(.horizontal, 4)
    }

    /// chips 网格（分类/时间快捷项共用）
    private func chipsGrid(items: [String], intent: @escaping (String) -> some AppIntent) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 6)], spacing: 6) {
            ForEach(items, id: \.self) { item in
                Button(intent: intent(item)) {
                    Text(item)
                        .font(.footnote)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func padButton(_ key: String, intent: some AppIntent) -> some View {
        Button(intent: intent) {
            Text(key)
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func actionButton(_ label: String, tint: Color, intent: some AppIntent) -> some View {
        Button(intent: intent) {
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(tint == .secondary ? Color.primary : Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(tint == .secondary ? Color.secondary.opacity(0.15) : tint,
                            in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

}
