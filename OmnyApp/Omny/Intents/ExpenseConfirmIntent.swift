import AppIntents
import Foundation
import SwiftUI
import OmnyCore
import os

// MARK: - 确认记账指令
//
// 「确认记账」快捷指令：接收上游「解析文本 / 屏幕识别」（直接入库=关）输出的 [InboxItemEntity]，
// 逐笔记账弹确认卡核对后入库；非记账条目（快递/行程/待办）静默入库（复用 Ingestor 去重/合并）。
//
// 交互机制（issue #15 重写）：真机日志证实，快捷指令后台 banner 上下文里同一次 perform()
// 只有第一次交互式参数请求能弹出，第二次（requestValue / 再次 requestDisambiguation）会被系统
// 静默吞掉直接结束运行——旧版「requestDisambiguation 参数循环」方案（bdc86de）不可行。现改为：
// - iOS 26+：requestConfirmation(snippetIntent:) 弹 interactive snippet（可交互确认卡），
//   字段编辑全部是 snippet 内 Button(intent:) 触发的子编辑 Intent（widget 交互机制，
//   不占用参数请求），系统在子编辑完成后自动重调 ExpenseSnippetIntent.perform 原地重渲染。
// - iOS <26 降级：单次 requestDisambiguation 只保留「确认/取消」（一次请求是稳的），不可编辑。

struct ConfirmExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "确认记账"
    static let description = IntentDescription(
        "逐笔弹出确认卡核对记账（可改收支/金额/分类/时间），确认后入库；非记账条目自动入库。")
    static let openAppWhenRun = false

    @Parameter(title: "条目")
    var items: [InboxItemEntity]

    /// iOS <26 降级路径承接「确认/取消」选择的工作参数（不进快捷指令编辑器）
    @Parameter(title: "选择") var choice: String?

    /// 只把 items 暴露为输入：工作参数不进快捷指令编辑器，也避免系统运行前尝试 resolve 它
    static var parameterSummary: some ParameterSummary {
        Summary("核对并确认 \(\.$items)")
    }

    /// 真机调试日志：Console.app 按 subsystem xin.codgi.omny / category ConfirmExpense 过滤
    static let log = Logger(subsystem: "xin.codgi.omny", category: "ConfirmExpense")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        Self.log.info("perform 进入：items.count=\(items.count, privacy: .public)")
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

        // 2. 逐笔确认记账（多笔逐个弹卡；注意后台 banner 上下文里第 2 笔起的确认请求
        //    可能受系统同次运行交互限制影响，常见场景是单笔）
        var savedCount = 0
        for entity in expenseEntities {
            let p = entity.payload
            var info = p.expenseInfo
            // 有 LLM 且无分类 → 预补两级分类，供确认卡预填（用原文喂 LLM，对齐直接入库路径）
            if info.categoryMajor == nil {
                await Self.precategorize(&info, rawText: p.rawText ?? "")
            }
            let draft = ExpenseDraft(info: info, occurredAt: p.occurredAt ?? .now,
                                     rawText: p.rawText ?? "")
            ExpenseDraftStore.shared.put(draft)
            defer { ExpenseDraftStore.shared.remove(draft.id) }

            if await confirmOne(draft) {
                // 确认后读回最终草稿（子编辑 Intent 可能已改过）入库；
                // addManualExpense 尊重用户输入：不解析、不去重、不异步覆盖分类
                let final = ExpenseDraftStore.shared.get(draft.id) ?? draft
                _ = Ingestor.addManualExpense(final.info, occurredAt: final.occurredAt,
                                              context: context)
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

    /// 单笔确认：iOS 26+ 弹可编辑 snippet 确认卡；低版本弹一次「确认/取消」列表。
    /// 返回 true=确认入库，false=取消跳过。
    @MainActor
    private func confirmOne(_ draft: ExpenseDraft) async -> Bool {
        if #available(iOS 26, *) {
            do {
                Self.log.info("confirmOne：requestConfirmation(snippetIntent:) 前")
                try await requestConfirmation(
                    actionName: .add,
                    dialog: IntentDialog(stringLiteral: "核对这笔记账"),
                    snippetIntent: ExpenseSnippetIntent(draftID: draft.id.uuidString))
                Self.log.info("confirmOne：用户确认")
                return true
            } catch {
                // 用户点取消（或系统撤下确认卡）→ 跳过该笔
                Self.log.info("confirmOne：取消/中断：\(String(describing: error), privacy: .public)")
                return false
            }
        }

        // iOS <26 降级：单次选择列表（仅确认/取消，同次运行第二次参数请求系统不支持，故不可编辑）
        let summary = "\(draft.direction == .income ? "收入" : "支出") "
            + ExpenseConfirmFormat.amountText(draft.amount)
            + (draft.merchant.map { "（\($0)）" } ?? "")
            + " · " + ExpenseConfirmFormat.categoryText(draft)
            + " · " + ExpenseConfirmFormat.timeText(draft.occurredAt)
        let done = "✅ 确认记账"
        let picked = try? await $choice.requestDisambiguation(
            among: [done, "❌ 取消这笔"],
            dialog: IntentDialog(stringLiteral: summary))
        return picked == done
    }

    /// LLM 预补两级分类（有 Key 时），供确认卡预填
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
}

/// 确认卡/降级列表共用的展示文案（snippet 视图限 iOS 26，这里的纯函数不限）
enum ExpenseConfirmFormat {
    static func amountText(_ amount: Decimal?) -> String {
        amount.map { "¥\(ExpenseFormat.plain($0))" } ?? "未填"
    }

    static func categoryText(_ draft: ExpenseDraft) -> String {
        let s = [draft.categoryMajor, draft.categorySub].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " / ")
        return s.isEmpty ? "未分类" : s
    }

    static func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }
}

// MARK: - 确认卡 snippet 指令（iOS 26）
//
// 渲染可交互确认卡。系统在其内按钮的子编辑 Intent 完成后自动重调 perform() 重渲染，
// 故 perform 必须无副作用、每次从共享 store 读最新草稿。draftID 是传入的最小不可变数据。

@available(iOS 26, *)
struct ExpenseSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "记账确认卡"
    static let isDiscoverable = false

    @Parameter(title: "草稿ID") var draftID: String

    init() {}
    init(draftID: String) { self.draftID = draftID }

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        let draft = UUID(uuidString: draftID).flatMap { ExpenseDraftStore.shared.get($0) }
        // 分类池随视图打包（snippet 进程外渲染，视图内不能现取设置）
        let pool = AppSettings.shared.expenseCategoryPool
        let groups = pool.keys.sorted().map {
            ExpenseConfirmSnippet.CategoryGroup(major: $0, subs: pool[$0] ?? [])
        }
        return .result(view: ExpenseConfirmSnippet(draftID: draftID, draft: draft,
                                                   categoryPool: groups))
    }
}

// MARK: - 子编辑指令（点确认卡内控件触发；改草稿后系统自动重调 ExpenseSnippetIntent 重渲染）
//
// 所有参数在按钮构造时给全（不能依赖运行中弹参数请求，见文件头）；不在快捷指令 App 里可见。

/// 切换面板（主页 ⇄ 金额键盘/分类/时间；进入面板时初始化对应界面态）
@available(iOS 26, *)
struct ShowExpensePanelIntent: AppIntent {
    static let title: LocalizedStringResource = "切换记账面板"
    static let isDiscoverable = false
    static let openAppWhenRun = false

    @Parameter(title: "草稿ID") var draftID: String
    @Parameter(title: "面板") var panelRaw: String

    init() {}
    init(draftID: String, panel: ExpenseDraft.Panel) {
        self.draftID = draftID
        self.panelRaw = panel.rawValue
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: draftID),
              let panel = ExpenseDraft.Panel(rawValue: panelRaw) else { return .result() }
        ExpenseDraftStore.shared.update(id) {
            $0.panel = panel
            switch panel {
            case .amount:
                $0.amountDraft = $0.amount.map { ExpenseFormat.plain($0) } ?? ""
            case .category:
                $0.pendingMajor = nil
            case .main, .time:
                break
            }
        }
        return .result()
    }
}

/// 收支翻转（主面板「收支」行）
@available(iOS 26, *)
struct FlipExpenseDirectionIntent: AppIntent {
    static let title: LocalizedStringResource = "切换收支"
    static let isDiscoverable = false
    static let openAppWhenRun = false

    @Parameter(title: "草稿ID") var draftID: String

    init() {}
    init(draftID: String) { self.draftID = draftID }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: draftID) {
            ExpenseDraftStore.shared.update(id) {
                $0.direction = ($0.direction == .expense) ? .income : .expense
            }
        }
        return .result()
    }
}

/// 金额键盘按键（数字/./⌫/done/cancel）
@available(iOS 26, *)
struct ExpenseAmountKeyIntent: AppIntent {
    static let title: LocalizedStringResource = "记账金额键"
    static let isDiscoverable = false
    static let openAppWhenRun = false

    @Parameter(title: "草稿ID") var draftID: String
    @Parameter(title: "键") var key: String

    init() {}
    init(draftID: String, key: String) {
        self.draftID = draftID
        self.key = key
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: draftID) else { return .result() }
        ExpenseDraftStore.shared.update(id) { draft in
            switch key {
            case "done":
                if let v = Decimal(string: draft.amountDraft), v > 0 { draft.amount = v }
                draft.panel = .main
            case "cancel":
                draft.panel = .main
            case "⌫":
                if !draft.amountDraft.isEmpty { draft.amountDraft.removeLast() }
            case ".":
                if !draft.amountDraft.contains(".") {
                    draft.amountDraft += draft.amountDraft.isEmpty ? "0." : "."
                }
            default:  // 数字：防溢出限长；小数至多两位
                let parts = draft.amountDraft.split(separator: ".", omittingEmptySubsequences: false)
                let decimals = parts.count > 1 ? parts[1].count : 0
                if draft.amountDraft.count < 10, decimals < 2 {
                    draft.amountDraft += key
                }
            }
        }
        return .result()
    }
}

/// 选大类：无细分直接落定回主页；有细分进入细分层
@available(iOS 26, *)
struct PickExpenseCategoryMajorIntent: AppIntent {
    static let title: LocalizedStringResource = "选记账大类"
    static let isDiscoverable = false
    static let openAppWhenRun = false

    @Parameter(title: "草稿ID") var draftID: String
    @Parameter(title: "大类") var major: String

    init() {}
    init(draftID: String, major: String) {
        self.draftID = draftID
        self.major = major
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: draftID) else { return .result() }
        let subs = AppSettings.shared.expenseCategoryPool[major] ?? []
        ExpenseDraftStore.shared.update(id) {
            if subs.isEmpty {
                $0.categoryMajor = major
                $0.categorySub = nil
                $0.panel = .main
            } else {
                $0.pendingMajor = major
            }
        }
        return .result()
    }
}

/// 落定分类（sub 传空串 = 只记大类），回主页
@available(iOS 26, *)
struct PickExpenseCategoryIntent: AppIntent {
    static let title: LocalizedStringResource = "选记账分类"
    static let isDiscoverable = false
    static let openAppWhenRun = false

    @Parameter(title: "草稿ID") var draftID: String
    @Parameter(title: "大类") var major: String
    @Parameter(title: "细分") var sub: String

    init() {}
    init(draftID: String, major: String, sub: String) {
        self.draftID = draftID
        self.major = major
        self.sub = sub
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: draftID) {
            ExpenseDraftStore.shared.update(id) {
                $0.categoryMajor = major
                $0.categorySub = sub.isEmpty ? nil : sub
                $0.panel = .main
            }
        }
        return .result()
    }
}

/// 时间快捷项：今天/昨天/前天（保留时分只挪日期）、此刻、保持不变，回主页
@available(iOS 26, *)
struct PickExpenseTimeIntent: AppIntent {
    static let title: LocalizedStringResource = "选记账时间"
    static let isDiscoverable = false
    static let openAppWhenRun = false

    @Parameter(title: "草稿ID") var draftID: String
    @Parameter(title: "选项") var option: String

    init() {}
    init(draftID: String, option: String) {
        self.draftID = draftID
        self.option = option
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: draftID) else { return .result() }
        ExpenseDraftStore.shared.update(id) { draft in
            let cal = Calendar.current
            // 保留原时分，只把日期挪到目标那天
            func withDate(daysAgo: Int) -> Date {
                let base = cal.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
                let t = cal.dateComponents([.hour, .minute], from: draft.occurredAt)
                var d = cal.dateComponents([.year, .month, .day], from: base)
                d.hour = t.hour
                d.minute = t.minute
                return cal.date(from: d) ?? draft.occurredAt
            }
            switch option {
            case "今天": draft.occurredAt = withDate(daysAgo: 0)
            case "昨天": draft.occurredAt = withDate(daysAgo: 1)
            case "前天": draft.occurredAt = withDate(daysAgo: 2)
            case "此刻": draft.occurredAt = .now
            default: break   // 保持不变
            }
            draft.panel = .main
        }
        return .result()
    }
}
