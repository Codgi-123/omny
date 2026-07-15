import Foundation
import OmnyCore

/// 一笔待确认记账的可变草稿（确认 snippet 编辑的对象）。
/// 字段对齐 ExpenseInfo 但都可变；另带 snippet 的界面态（panel 等）——snippet 渲染是无状态的
/// （每次交互后系统重调 SnippetIntent.perform 重渲染），当前停在哪个编辑面板也必须随草稿持久化。
struct ExpenseDraft: Identifiable, Equatable, Codable {
    /// snippet 当前显示的面板
    enum Panel: String, Codable {
        case main       // 字段总览（确认页）
        case amount     // 金额数字键盘
        case category   // 分类选择（大类→细分两级）
        case time       // 时间快捷项
    }

    let id: UUID
    let createdAt: Date
    var direction: ExpenseDirection
    var amount: Decimal?
    var merchant: String?
    var categoryMajor: String?
    var categorySub: String?
    var occurredAt: Date
    var channel: String?
    var cardTail: String?
    var txnID: String?
    /// 解析来源原文（预补分类喂 LLM 用）
    var rawText: String

    // —— snippet 界面态 ——
    var panel: Panel = .main
    /// 金额键盘的暂存串（点「确定」才写回 amount）
    var amountDraft: String = ""
    /// 分类面板：已点的大类（nil=在选大类；非 nil=在选该大类的细分）
    var pendingMajor: String?

    init(info: ExpenseInfo, occurredAt: Date, rawText: String) {
        self.id = UUID()
        self.createdAt = .now
        self.direction = info.direction
        self.amount = info.amount
        self.merchant = info.merchant
        self.categoryMajor = info.categoryMajor
        self.categorySub = info.categorySub
        self.occurredAt = occurredAt
        self.channel = info.channel
        self.cardTail = info.cardTail
        self.txnID = info.txnID
        self.rawText = rawText
    }

    /// 转回 ExpenseInfo 供入库（时间由调用方以 occurredAt Date 单独传给 addManualExpense）
    var info: ExpenseInfo {
        ExpenseInfo(direction: direction, amount: amount, merchant: merchant,
                    categoryMajor: categoryMajor, categorySub: categorySub,
                    occurredAt: Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute], from: occurredAt),
                    channel: channel, cardTail: cardTail, txnID: txnID)
    }
}

/// 跨 Intent 共享的草稿状态：主确认 Intent 建草稿，snippet 子编辑 Intent 改草稿，
/// ExpenseSnippetIntent 每次重渲染时读草稿。这些 Intent 都跑在主 App 进程里，但系统可能在
/// 两次交互的间隙回收进程，故写透到 App Group UserDefaults（同实体注册表的做法），重启可还原。
/// 草稿只需在一次确认会话内存活，登记超过 1 天即清理。
@MainActor
final class ExpenseDraftStore {
    static let shared = ExpenseDraftStore()
    private init() {}

    private static let key = "expenseDraftStore"
    private var defaults: UserDefaults? { UserDefaults(suiteName: SharedInbox.appGroupID) }
    private var cache: [UUID: ExpenseDraft]?

    private var drafts: [UUID: ExpenseDraft] {
        get {
            if let cache { return cache }
            var loaded: [UUID: ExpenseDraft] = [:]
            if let data = defaults?.data(forKey: Self.key),
               let dict = try? JSONDecoder().decode([UUID: ExpenseDraft].self, from: data) {
                let cutoff = Date.now.addingTimeInterval(-24 * 3600)
                loaded = dict.filter { $0.value.createdAt > cutoff }
            }
            cache = loaded
            return loaded
        }
        set {
            cache = newValue
            if let data = try? JSONEncoder().encode(newValue) {
                defaults?.set(data, forKey: Self.key)
            }
        }
    }

    func put(_ draft: ExpenseDraft) { drafts[draft.id] = draft }
    func get(_ id: UUID) -> ExpenseDraft? { drafts[id] }
    func remove(_ id: UUID) { drafts.removeValue(forKey: id) }

    /// 局部更新某草稿的字段
    func update(_ id: UUID, _ mutate: (inout ExpenseDraft) -> Void) {
        guard var d = drafts[id] else { return }
        mutate(&d)
        drafts[id] = d
    }
}
