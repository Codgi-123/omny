import Foundation
import SwiftData
import OmnyCore

enum ItemKind: String {
    case package, trip, todo, bookmark, unclassified
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
    var todoDue: Date?
    var todoCompleted: Bool = false
    var didaTaskID: String?
    var needsPush: Bool = false
    var deletedLocally: Bool = false

    // 收藏
    var urlString: String?
    var bookmarkTitle: String?

    init(kind: ItemKind, source: ItemSource, rawText: String) {
        self.kindRaw = kind.rawValue
        self.sourceRaw = source.rawValue
        self.rawText = rawText
    }

    var kind: ItemKind { ItemKind(rawValue: kindRaw) ?? .unclassified }
    var source: ItemSource { ItemSource(rawValue: sourceRaw) ?? .manual }

    var packageStatus: PackageStatus {
        get { PackageStatus(rawValue: packageStatusRaw) ?? .inTransit }
        set { packageStatusRaw = newValue.rawValue }
    }
}
