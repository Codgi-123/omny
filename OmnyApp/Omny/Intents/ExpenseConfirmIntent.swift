import AppIntents
import SwiftUI
import SwiftData
import OmnyCore

// MARK: - 主确认指令
//
// 「确认记账」快捷指令：输入文本/OCR → 内部解析出记账笔 → 逐笔用 interactive snippet 弹窗
// 展示可编辑表单（金额/类型/分类/时间/备注，点字段弹二级选择）→ 用户确认后入库。
// 不打开 App（snippet 内联在快捷指令弹窗）。参考钱迹式交互。
//
// ⚠️ 真机验证重点：interactive snippet（iOS 18）的 requestConfirmation + Button(intent:) 子编辑 +
// reloadSnippet 的精确配合，本机无法验证，真机若行为异常据此调整（结构已隔离）。

struct ConfirmExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "确认记账"
    static let description = IntentDescription(
        "解析短信/截图里的消费，逐笔弹出可编辑表单，确认后记账。适合对自动记账结果做人工核对。")
    static let openAppWhenRun = false

    @Parameter(title: "文本")
    var text: String

    @Parameter(title: "来自截图", default: false)
    var isScreenshot: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .result(dialog: "没有可解析的文本") }

        // 1. 解析出记账笔（只取 expense，不入库）
        let drafts = await Self.parseExpenses(trimmed, isScreenshot: isScreenshot)
        guard !drafts.isEmpty else { return .result(dialog: "未识别到记账信息") }

        let store = ExpenseDraftStore.shared
        let context = OmnyApp.sharedModelContainer.mainContext
        var savedCount = 0

        // 2. 逐笔确认（多笔逐个弹）
        for (index, draft) in drafts.enumerated() {
            store.put(draft)
            defer { store.remove(draft.id) }
            do {
                // 展示可编辑 snippet（字段行可点触发子编辑），用户点「记账」确认、点取消跳过
                let title: LocalizedStringResource = drafts.count > 1
                    ? "第 \(index + 1)/\(drafts.count) 笔 · 核对后记账" : "核对后记账"
                try await requestConfirmation(
                    result: .result(dialog: title) {
                        ExpenseConfirmSnippet(draftID: draft.id)
                    },
                    confirmationActionName: .go)
                // 确认后读回（子编辑 Intent 可能已改过）最终草稿入库
                let final = store.get(draft.id) ?? draft
                Ingestor.addManualExpense(final.info, occurredAt: final.occurredAt,
                                          context: context)
                savedCount += 1
            } catch {
                // 取消该笔 → 跳过
                continue
            }
        }

        guard savedCount > 0 else { return .result(dialog: "没有记账") }
        return .result(dialog: "已记账 \(savedCount) 笔")
    }

    /// 解析文本抽出记账笔；有 LLM 时预补两级分类，让确认表单预填分类。
    @MainActor
    static func parseExpenses(_ text: String, isScreenshot: Bool) async -> [ExpenseDraft] {
        let parser: any Parser = isScreenshot
            ? AppSettings.shared.screenParser
            : AppSettings.shared.parserPipeline
        let result = try? await parser.parse(text)
        guard let payload = result?.payload else { return [] }

        // 展平取所有 expense
        let infos: [ExpenseInfo] = payload.flattened.compactMap {
            if case .expense(let info) = $0 { return info }
            return nil
        }

        // 预补分类（有 LLM 才补，让表单预填；用户仍可改）
        var drafts: [ExpenseDraft] = []
        for var info in infos {
            if info.categoryMajor == nil, let cfg = AppSettings.shared.llmConfig {
                let pool = AppSettings.shared.expenseCategoryPool
                let content = [info.merchant, info.amount.map { "\($0)元" }, text]
                    .compactMap { $0 }.joined(separator: "\n")
                if let picked = try? await LLMExpenseCategorizer(config: cfg)
                    .classify(content, pool: pool) {
                    info.categoryMajor = picked.major
                    info.categorySub = picked.sub
                }
            }
            let occurredAt = Ingestor.resolveDate(info.occurredAt) ?? .now
            drafts.append(ExpenseDraft(info: info, occurredAt: occurredAt, rawText: text))
        }
        return drafts
    }
}

// MARK: - 子编辑指令（点 snippet 字段触发，改草稿后刷新 snippet）
//
// 每个字段一个子 Intent：@Parameter 承载新值 + draftID，perform 写 store 并 reloadSnippet。

struct EditExpenseAmountIntent: AppIntent {
    static let title: LocalizedStringResource = "改金额"
    static let openAppWhenRun = false

    @Parameter(title: "草稿ID") var draftID: String
    @Parameter(title: "金额") var amount: Double

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: draftID) {
            ExpenseDraftStore.shared.update(id) { $0.amount = Decimal(amount) }
        }
        return .result()
    }
}

struct EditExpenseDirectionIntent: AppIntent {
    static let title: LocalizedStringResource = "切换收支"
    static let openAppWhenRun = false

    @Parameter(title: "草稿ID") var draftID: String

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

/// 分类候选：从设置页分类池扁平化成「大类/细分」列表，供选分类子 Intent 弹出选择。
struct ExpenseCategoryOptionsProvider: DynamicOptionsProvider {
    @MainActor
    func results() async throws -> [String] {
        LLMExpenseCategorizer.flatten(AppSettings.shared.expenseCategoryPool)
    }
}

struct EditExpenseCategoryIntent: AppIntent {
    static let title: LocalizedStringResource = "选分类"
    static let openAppWhenRun = false

    @Parameter(title: "草稿ID") var draftID: String
    // 扁平「大类/细分」，与 LLMExpenseCategorizer 一致，用户从池里选（动态候选）
    @Parameter(title: "分类", optionsProvider: ExpenseCategoryOptionsProvider())
    var category: String

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: draftID) {
            let parts = category.components(separatedBy: "/")
            ExpenseDraftStore.shared.update(id) {
                $0.categoryMajor = parts.first
                $0.categorySub = parts.count > 1 ? parts[1] : nil
            }
        }
        return .result()
    }
}

struct EditExpenseNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "改备注"
    static let openAppWhenRun = false

    @Parameter(title: "草稿ID") var draftID: String
    @Parameter(title: "备注") var note: String

    @MainActor
    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: draftID) {
            ExpenseDraftStore.shared.update(id) { $0.note = note.isEmpty ? nil : note }
        }
        return .result()
    }
}
