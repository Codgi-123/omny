import Foundation
import OmnyCore

/// 一笔待确认记账的可变草稿（interactive snippet 编辑的对象）。
/// 字段对齐 ExpenseInfo，但都可变——用户在 snippet 弹窗里逐字段改。
struct ExpenseDraft: Identifiable, Equatable {
    let id: UUID
    var direction: ExpenseDirection
    var amount: Decimal?
    var merchant: String?
    var categoryMajor: String?
    var categorySub: String?
    var occurredAt: Date
    var channel: String?
    var cardTail: String?
    var note: String?
    /// 原始文本（兜底/核对）
    var rawText: String

    init(id: UUID = UUID(), info: ExpenseInfo, occurredAt: Date, rawText: String) {
        self.id = id
        self.direction = info.direction
        self.amount = info.amount
        self.merchant = info.merchant
        self.categoryMajor = info.categoryMajor
        self.categorySub = info.categorySub
        self.occurredAt = occurredAt
        self.channel = info.channel
        self.cardTail = info.cardTail
        self.note = nil
        self.rawText = rawText
    }

    /// 转回 ExpenseInfo 供入库
    var info: ExpenseInfo {
        ExpenseInfo(direction: direction, amount: amount, merchant: merchant,
                    categoryMajor: categoryMajor, categorySub: categorySub,
                    channel: channel, cardTail: cardTail)
    }
}

/// 跨 Intent 共享的草稿状态：主确认 Intent 建草稿，子编辑 Intent 改草稿，主 snippet 读草稿。
/// interactive snippet 的各字段编辑通过独立子 Intent 触发，需要一个共享处存放会话内的草稿。
/// 进程级单例即可（一次确认会话在同一进程内完成）。
@MainActor
final class ExpenseDraftStore {
    static let shared = ExpenseDraftStore()
    private init() {}

    private var drafts: [UUID: ExpenseDraft] = [:]

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
