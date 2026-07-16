import Foundation
import SwiftData
import OmnyCore

enum ItemKind: String {
    case package, trip, todo, bookmark, expense, unclassified
}

enum ItemSource: String {
    case sms = "短信"
    case screenshot = "截图"
    case share = "分享"
    case manual = "手动"
    case dida = "滴答"
}

/// 统一条目模型：所有入口的信息都落成 InboxItem，页面是按 kind 过滤的视图。
/// SwiftData 建议扁平结构，各类型字段可空共存。
@Model
final class InboxItem {
    var id: UUID = UUID()
    var kindRaw: String = ItemKind.unclassified.rawValue
    var sourceRaw: String = ItemSource.manual.rawValue
    var createdAt: Date = Date()
    var rawText: String = ""
    /// 解析置信度不足 / 完全没识别出来，需要人工确认
    var needsReview: Bool = false
    /// 软删除时间：非 nil 表示已进回收站；各列表默认过滤掉；满保留期（默认 7 天）由启动时清理彻底删除。
    var deletedAt: Date?
    /// 手动排序序号：列表页长按拖动时对整个分组重写 0..n。
    /// nil = 从未拖过（新条目），排在已排序条目之前（新信息优先露出），同为 nil 按各列表默认规则。
    var sortOrder: Int?
    /// 截图来源的原图（外部存储）
    @Attribute(.externalStorage) var sourceImage: Data?

    // 快递
    var carrier: String?
    var trackingNumber: String?
    var trackingTail: String?
    var pickupCode: String?
    var station: String?
    var packageStatusRaw: Int = PackageStatus.inTransit.rawValue

    // 行程
    var tripKindRaw: String?
    var tripNumber: String?
    var departAt: Date?
    var departPlace: String?
    var arriveAt: Date?
    var arrivePlace: String?
    /// 座位（火车/航班）；酒店存房型（可含早餐说明）
    var seat: String?
    /// 检票口/登机口，如 "A6"
    var ticketGate: String?
    /// 席别/舱位等级，如 "二等座"
    var seatClass: String?
    /// 酒店地址（tripKind=hotel，卡片导航用）
    var tripAddress: String?
    var calendarEventID: String?

    // 待办（滴答同步字段与 OmnyCore.SyncableTodo 对应）
    var todoTitle: String?
    /// 待办描述 / 补充说明，对应滴答的 content
    var todoNote: String?
    var todoDue: Date?
    var todoCompleted: Bool = false
    /// 优先级，取值对齐滴答（0 无 / 1 低 / 3 中 / 5 高）；本地待办也可用于排序展示
    var todoPriority: Int = 0
    var didaTaskID: String?
    var needsPush: Bool = false
    var deletedLocally: Bool = false
    /// 本地「放弃」状态：纯本地展示标记（给默认值保证轻量迁移）。
    /// 放弃的待办不当成完成推送滴答、也不被远端拉取复活——仅前台过滤展示为「已放弃」分组。
    var todoAbandoned: Bool = false
    /// 条目级提醒规则（TodoReminderRule.rawValue）：nil = 跟随设置页全局默认；
    /// -1 不提醒 / 0 准时 / 其余为提前分钟数。可选属性，SwiftData 轻量迁移自动通过。
    var todoReminderMinutes: Int?
    /// 重复规则（TodoRepeatRule 编码串），nil = 不重复。仅本地待办使用，滴答待办不参与。
    /// 可选属性，SwiftData 轻量迁移自动通过。
    var todoRepeatRule: String?

    // 收藏
    var urlString: String?
    var bookmarkTitle: String?
    /// 收藏标签：LLM 从设置页的 tag 列表里自动挑选，也可手动编辑
    var tags: [String] = []

    // 记账
    var expenseDirectionRaw: String?   // ExpenseDirection.rawValue（expense/income）
    var amount: Decimal?               // 金额（正数），Decimal 保精度
    var merchant: String?
    var categoryMajor: String?         // 消费大类，LLM 打标或手动
    var categorySub: String?           // 消费细分
    var occurredAt: Date?              // 交易时间
    var channel: String?               // 渠道/银行/支付平台
    var cardTail: String?              // 卡尾号，去重主键之一
    var txnID: String?                 // 官方交易单号，CSV 导入去重主键

    init(kind: ItemKind, source: ItemSource, rawText: String) {
        self.kindRaw = kind.rawValue
        self.sourceRaw = source.rawValue
        self.rawText = rawText
    }

    var kind: ItemKind { ItemKind(rawValue: kindRaw) ?? .unclassified }
    var source: ItemSource { ItemSource(rawValue: sourceRaw) ?? .manual }

    /// 是否与滴答清单同步：仅滴答来源的待办参与同步（只读展示 + 完成状态回写）
    var isDidaSynced: Bool { source == .dida }
    /// 是否可在本地完整编辑（增删改）：非滴答来源即本地待办，纯本地、不同步
    var canEditLocally: Bool { !isDidaSynced }

    var packageStatus: PackageStatus {
        get { PackageStatus(rawValue: packageStatusRaw) ?? .inTransit }
        set { packageStatusRaw = newValue.rawValue }
    }

    /// 是否在回收站
    var isDeleted: Bool { deletedAt != nil }
    /// 回收站保留天数（默认 7，设置 → 高级设置可调）。
    /// 直接读 UserDefaults：SwiftData 模型层非 MainActor，拿不到 AppSettings 实例；
    /// 键名与 AppSettings.trashRetentionDays 的存储键（"data.trashRetentionDays"）保持一致。
    static var trashRetentionDays: Int {
        UserDefaults.standard.object(forKey: "data.trashRetentionDays") as? Int ?? 7
    }
    /// 距离彻底清除还剩几天（向上取整，至少 0）
    var trashDaysLeft: Int {
        guard let deletedAt else { return Self.trashRetentionDays }
        let elapsed = Date.now.timeIntervalSince(deletedAt)
        let left = Double(Self.trashRetentionDays) - elapsed / 86400
        return max(0, Int(ceil(left)))
    }

    var expenseDirection: ExpenseDirection {
        get { ExpenseDirection(rawValue: expenseDirectionRaw ?? "") ?? .expense }
        set { expenseDirectionRaw = newValue.rawValue }
    }
}

extension Sequence where Element == InboxItem {
    /// 手动顺序优先的排序：拖过的按 sortOrder 升序，没拖过的（nil 视作 -1）排最前，
    /// 序号相同（比如都没拖过）时按 fallback 的默认规则。列表页与首页轮播共用，保证顺序一致。
    func manuallySorted(fallback: (InboxItem, InboxItem) -> Bool) -> [InboxItem] {
        sorted { a, b in
            let ao = a.sortOrder ?? -1, bo = b.sortOrder ?? -1
            if ao != bo { return ao < bo }
            return fallback(a, b)
        }
    }

    /// 长按拖动落位：把可见分组按新顺序重写 sortOrder（0..n）。
    /// 对整组重写而非只改被拖条目——保证组内全部有序，之后新来的 nil 条目才能稳定排最前。
    func applyManualMove(from source: IndexSet, to destination: Int) {
        var arr = Array(self)
        arr.move(fromOffsets: source, toOffset: destination)
        for (i, item) in arr.enumerated() { item.sortOrder = i }
    }
}

// MARK: - 重复待办辅助（TodoRow 勾选与 TodoEditSheet 保存共用）

extension InboxItem {
    /// 重复待办「完成本次」时落的快照：一条普通的已完成本地待办，进现有「已完成」分组。
    /// 不带重复规则与条目级提醒——快照是历史记录，不再滚动、也不会被排通知
    /// （NotificationScheduler 只给 openTodos 排期，已完成态天然排除）。
    /// - Parameter due: 本次的截止时间（母条目滚动前的 todoDue）。
    func makeRepeatSnapshot(due: Date) -> InboxItem {
        // source 用 .manual：与手动添加待办一致的本地来源，不参与滴答同步
        let snap = InboxItem(kind: .todo, source: .manual, rawText: rawText)
        snap.todoTitle = todoTitle
        snap.todoNote = todoNote
        snap.todoPriority = todoPriority
        snap.todoDue = due
        snap.todoCompleted = true
        snap.todoRepeatRule = nil
        snap.todoReminderMinutes = nil
        snap.createdAt = Date()
        snap.needsReview = false
        return snap
    }
}

// MARK: - 收藏展示辅助（首页与收藏页共用）

extension InboxItem {
    /// 收藏条目的展示标题：抓到的标题 → 域名 → 正文首行
    var bookmarkDisplayTitle: String {
        if let t = bookmarkTitle, !t.isEmpty { return t }
        if let url = urlString.flatMap(URL.init(string:)) { return url.host() ?? "链接" }
        return rawText.components(separatedBy: .newlines).first ?? rawText
    }

    /// 收藏「加代办」的预填内容：标题 = 查看收藏：{标题缩写}，描述 = 完整标题 + 链接
    var bookmarkTodoPrefill: (title: String, note: String) {
        let full = bookmarkDisplayTitle
        let abbrev = full.count > 12 ? String(full.prefix(12)) + "…" : full
        var note = full
        if let s = urlString { note += "\n" + s }
        return ("查看收藏：\(abbrev)", note)
    }
}
