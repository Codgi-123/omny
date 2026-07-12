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
    /// 软删除时间：非 nil 表示已进回收站；各列表默认过滤掉；满 7 天由启动时清理彻底删除。
    var deletedAt: Date?
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
    var seat: String?
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
    /// 回收站保留天数
    static let trashRetentionDays = 7
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
