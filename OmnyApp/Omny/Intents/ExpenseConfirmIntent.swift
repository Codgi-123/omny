import AppIntents
import Foundation
import OmnyCore
import os

// MARK: - 确认记账指令
//
// 「确认记账」快捷指令：接收上游「解析文本 / 屏幕识别」（直接入库=关）输出的 [InboxItemEntity]，
// 逐笔记账用 requestDisambiguation/requestValue 参数循环在快捷指令弹窗层核对（钱迹式，不进 App、
// iOS 16+ 通用、离线可用）；非记账条目（快递/行程/待办）静默入库（复用 Ingestor 去重/合并）。
//
// 交互机制（非 SnippetIntent，那是 iOS 26）：perform() 里 while 循环，每轮对工作参数调
// $choice.requestDisambiguation(among:) 弹出「金额/收支/分类/时间/备注 + 确认/取消」列表；
// 用户点字段 → 再 requestValue/requestDisambiguation 改该字段 → 回循环顶重弹（值已更新）；
// 点「确认」→ addManualExpense 入库该笔并退出循环；点「取消」→ 跳过该笔。

struct ConfirmExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "确认记账"
    static let description = IntentDescription(
        "逐笔弹出可编辑列表核对记账（收支/分类/金额/备注），确认后入库；非记账条目自动入库。")
    static let openAppWhenRun = false

    @Parameter(title: "条目")
    var items: [InboxItemEntity]

    // 以下为循环内承接每轮选择/输入的工作参数（非用户在快捷指令里填的输入）
    @Parameter(title: "选择") var choice: String?
    @Parameter(title: "金额") var amountInput: Double?
    @Parameter(title: "商户") var merchantInput: String?

    /// 只把 items 暴露为输入：工作参数不进快捷指令编辑器，也避免系统运行前尝试逐个 resolve
    /// 它们（交接文档假设 C）。
    static var parameterSummary: some ParameterSummary {
        Summary("核对并确认 \(\.$items)")
    }

    /// 真机调试日志：Console.app 按 subsystem xin.codgi.omny / category ConfirmExpense 过滤
    static let log = Logger(subsystem: "xin.codgi.omny", category: "ConfirmExpense")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        Self.log.info("perform 进入：items.count=\(items.count, privacy: .public)")
        for (i, e) in items.enumerated() {
            Self.log.info("items[\(i)]: \(e.intentSummary, privacy: .public)")
        }
        let context = OmnyApp.sharedModelContainer.mainContext

        // 1. 分流：记账逐笔确认；非记账静默入库（复用去重/合并）
        let expenseEntities = items.filter { $0.isExpense }
        let others = items.filter { !$0.isExpense }
        Self.log.info("分流：expense=\(expenseEntities.count, privacy: .public) others=\(others.count, privacy: .public)")

        var otherCount = 0
        if !others.isEmpty {
            let payloads = others.compactMap { $0.toPayload() }
            let ingested = await Ingestor.ingestParsed(payloads, text: "", source: .screenshot,
                                                       awaitEnrichment: true, context: context)
            otherCount = ingested.count
        }

        guard !expenseEntities.isEmpty else {
            if otherCount > 0 {
                return .result(dialog: IntentDialog(stringLiteral: "已入库 \(otherCount) 条（快递/行程/待办）"))
            }
            return .result(dialog: "没有记账信息")
        }

        // 2. 逐笔确认记账
        var savedCount = 0
        for entity in expenseEntities {
            let p = entity.payload
            var draft = p.expenseInfo
            var occurredAt = p.occurredAt ?? .now
            // 有 LLM 且无分类 → 预补两级分类，供列表预填（用原文喂 LLM，对齐直接入库路径）
            if draft.categoryMajor == nil {
                await Self.precategorize(&draft, rawText: p.rawText ?? "")
            }

            let confirmed = try await confirmOne(&draft, occurredAt: &occurredAt)
            if confirmed {
                Ingestor.addManualExpense(draft, occurredAt: occurredAt, context: context)
                savedCount += 1
            }
        }

        // 3. 汇总
        var parts: [String] = []
        if savedCount > 0 { parts.append("已记账 \(savedCount) 笔") }
        if otherCount > 0 { parts.append("另入库 \(otherCount) 条快递/待办") }
        let msg = parts.isEmpty ? "没有记账" : parts.joined(separator: "，")
        return .result(dialog: IntentDialog(stringLiteral: msg))
    }

    /// 单笔确认循环：弹字段列表，点字段编辑后回列表重弹，直到确认/取消。
    /// 返回 true=确认入库，false=取消跳过。
    @MainActor
    private func confirmOne(_ draft: inout ExpenseInfo, occurredAt: inout Date) async throws -> Bool {
        // 列表项标签（固定标签 + 动态值），用标签前缀区分点了哪项
        let doneLabel = "✅ 确认记账"
        let cancelLabel = "❌ 取消这笔"

        while true {
            let dirLabel = "收支：" + (draft.direction == .income ? "收入" : "支出")
            let amtLabel = "金额：" + (draft.amount.map { ExpenseFormat.plain($0) } ?? "未填")
            let catLabel = "分类：" + categoryText(draft)
            let timeLabel = "时间：" + Self.timeText(occurredAt)
            let merchantLabel = "商户：" + (draft.merchant ?? "无")

            let options = [dirLabel, amtLabel, catLabel, timeLabel, merchantLabel, doneLabel, cancelLabel]
            Self.log.info("confirmOne：requestDisambiguation 前，options=\(options.count, privacy: .public)")
            let picked: String
            do {
                picked = try await $choice.requestDisambiguation(
                    among: options,
                    dialog: IntentDialog(stringLiteral: "确认记账（点项目可修改）"))
            } catch {
                Self.log.error("requestDisambiguation 抛错：\(String(describing: error), privacy: .public)")
                throw error
            }
            Self.log.info("confirmOne：用户选了「\(picked, privacy: .public)」")

            switch picked {
            case doneLabel:
                return true
            case cancelLabel:
                return false
            case dirLabel:
                // 收支直接翻转
                draft.direction = (draft.direction == .expense) ? .income : .expense
            case amtLabel:
                let v = try await $amountInput.requestValue(
                    IntentDialog(stringLiteral: "输入金额"))
                if v > 0 { draft.amount = Decimal(v) }
            case catLabel:
                let pool = LLMExpenseCategorizer.flatten(AppSettings.shared.expenseCategoryPool)
                if !pool.isEmpty {
                    let sel = try await $choice.requestDisambiguation(
                        among: pool, dialog: IntentDialog(stringLiteral: "选择分类"))
                    let parts = sel.components(separatedBy: "/")
                    draft.categoryMajor = parts.first
                    draft.categorySub = parts.count > 1 ? parts[1] : nil
                }
            case timeLabel:
                // 时间修改：App Intents 无原生日期滚轮，给常用相对日期快捷项
                // （保留原时分，只挪日期），外加「此刻」和「保持不变」
                occurredAt = try await Self.pickTime(current: occurredAt, choice: $choice)
            case merchantLabel:
                let v = try await $merchantInput.requestValue(
                    IntentDialog(stringLiteral: "输入商户"))
                let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.merchant = t.isEmpty ? nil : t
            default:
                return true   // 兜底
            }
        }
    }

    /// 时间选择：今天/昨天/前天（保留当前时分，只改日期）+ 此刻 + 保持不变。
    @MainActor
    private static func pickTime(current: Date, choice: IntentParameter<String?>) async throws -> Date {
        let cal = Calendar.current
        let today = "今天"; let yesterday = "昨天"; let dayBefore = "前天"
        let now = "此刻"; let keep = "保持不变"
        let sel = try await choice.requestDisambiguation(
            among: [today, yesterday, dayBefore, now, keep],
            dialog: IntentDialog(stringLiteral: "修改时间"))
        // 保留 current 的时分，只把日期挪到目标那天
        func withDate(daysAgo: Int) -> Date {
            let base = cal.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
            let t = cal.dateComponents([.hour, .minute], from: current)
            var d = cal.dateComponents([.year, .month, .day], from: base)
            d.hour = t.hour; d.minute = t.minute
            return cal.date(from: d) ?? current
        }
        switch sel {
        case today: return withDate(daysAgo: 0)
        case yesterday: return withDate(daysAgo: 1)
        case dayBefore: return withDate(daysAgo: 2)
        case now: return .now
        default: return current   // 保持不变
        }
    }

    private func categoryText(_ d: ExpenseInfo) -> String {
        let s = [d.categoryMajor, d.categorySub].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " / ")
        return s.isEmpty ? "未分类" : s
    }

    /// LLM 预补两级分类（有 Key 时），供列表预填
    @MainActor
    private static func precategorize(_ info: inout ExpenseInfo, rawText: String) async {
        guard let cfg = AppSettings.shared.llmConfig else { return }
        let pool = AppSettings.shared.expenseCategoryPool
        let content = [info.merchant, info.amount.map { "\($0)元" }, rawText]
            .compactMap { $0 }.joined(separator: "\n")
        if let picked = try? await LLMExpenseCategorizer(config: cfg).classify(content, pool: pool) {
            info.categoryMajor = picked.major
            info.categorySub = picked.sub
        }
    }

    private static func timeText(_ date: Date) -> String {
        OmnyDateFormat.monthDayTime(date)
    }
}
