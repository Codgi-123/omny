import AppIntents
import Foundation
import OmnyCore

/// 快捷指令 Intent 之间传递的结构化条目实体。
///
/// 作用：让「解析文本 / 屏幕识别」输出解析结果、「确认记账」接收之，全程**不落库**——
/// 确认通过后才第一次入库（确认前用户在 App 里看不到未确认数据）。
/// 与 `ParsedPayload` 双向转换：解析出 payload → Entity（带走）；Entity → payload →
/// `Ingestor.ingestParsed` 入库（复用快递合并 / 记账去重，避免重复入库）。
///
/// App Intents 的参数类型受限（不支持 DateComponents），故时间字段用 `Date?`；
/// 转回 payload 时从 Date 拆成 DateComponents（`Ingestor.resolveDate` 已能宽容处理）。
/// 这些实体是流程内瞬态传递，不做持久查询，故 EntityQuery 返回空。
struct InboxItemEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "识别条目"
    static let defaultQuery = InboxItemEntityQuery()

    var id = UUID()

    /// 类型：package/trip/todo/bookmark/expense（对应 OmnyCore.ItemType）
    var typeRaw: String

    // 快递
    var carrier: String?
    var trackingNumber: String?
    var trackingTail: String?
    var pickupCode: String?
    var station: String?
    var packageStatusRaw: Int?

    // 行程
    var tripKindRaw: String?
    var tripNumber: String?
    var departAt: Date?
    var departPlace: String?
    var arriveAt: Date?
    var arrivePlace: String?
    var seat: String?

    // 待办
    var todoTitle: String?
    var todoDue: Date?

    // 收藏
    var urlString: String?
    var bookmarkTitle: String?

    // 记账
    var expenseDirectionRaw: String?
    var amount: Double?              // App Intents 不支持 Decimal，用 Double 承载，转换时还原
    var merchant: String?
    var categoryMajor: String?
    var categorySub: String?
    var occurredAt: Date?
    var channel: String?
    var cardTail: String?
    var txnID: String?

    var type: ItemType? { ItemType(rawValue: typeRaw) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(intentSummary)")
    }

    /// 人类可读摘要（快捷指令里展示每个实体用）
    var intentSummary: String {
        switch type {
        case .package:
            let code = pickupCode.map { "，取件码 \($0)" } ?? ""
            return "\(carrier ?? "快递")\(code)"
        case .trip: return "行程 \(tripNumber ?? "")"
        case .todo: return "待办 \(todoTitle ?? "")"
        case .bookmark: return "收藏 \(bookmarkTitle ?? urlString ?? "")"
        case .expense:
            let amt = amount.map { "\(ExpenseFormat.plain(Decimal($0)))元" } ?? ""
            let label = expenseDirectionRaw == ExpenseDirection.income.rawValue ? "收入" : "支出"
            return "\(label) \(amt)\(merchant.map { "（\($0)）" } ?? "")"
        case .none: return "未识别"
        }
    }
}

// MARK: - ParsedPayload 双向转换

extension InboxItemEntity {
    /// 从单类 payload 构造（调用方保证已 flattened、非 .mixed）。
    /// .todos 含多条时只取第一条——批量场景由调用方展开成多个 payload 分别构造。
    init?(payload: ParsedPayload) {
        switch payload {
        case .package(let info):
            self.init(typeRaw: ItemType.package.rawValue)
            carrier = info.carrier
            trackingNumber = info.trackingNumber
            trackingTail = info.trackingTail
            pickupCode = info.pickupCode
            station = info.station
            packageStatusRaw = info.status.rawValue
        case .trip(let info):
            self.init(typeRaw: ItemType.trip.rawValue)
            tripKindRaw = info.kind.rawValue
            tripNumber = info.number
            departAt = Self.date(info.departure)
            departPlace = info.departurePlace
            arriveAt = Self.date(info.arrival)
            arrivePlace = info.arrivalPlace
            seat = info.seat
        case .todos(let todos):
            guard let first = todos.first else { return nil }
            self.init(typeRaw: ItemType.todo.rawValue)
            todoTitle = first.title
            todoDue = Self.date(first.due)
        case .bookmark(let info):
            self.init(typeRaw: ItemType.bookmark.rawValue)
            urlString = info.url.absoluteString
            bookmarkTitle = info.title
        case .expense(let info):
            self.init(typeRaw: ItemType.expense.rawValue)
            expenseDirectionRaw = info.direction.rawValue
            amount = info.amount.map { NSDecimalNumber(decimal: $0).doubleValue }
            merchant = info.merchant
            categoryMajor = info.categoryMajor
            categorySub = info.categorySub
            occurredAt = Self.date(info.occurredAt)
            channel = info.channel
            cardTail = info.cardTail
            txnID = info.txnID
        case .mixed:
            return nil   // 调用方须先 flattened
        }
    }

    /// 把一批 payload 展平构造成实体数组（.todos 展开成多条待办实体）。
    static func from(payloads: [ParsedPayload]) -> [InboxItemEntity] {
        payloads.flatMap { $0.flattened }.flatMap { payload -> [InboxItemEntity] in
            if case .todos(let todos) = payload {
                return todos.compactMap { InboxItemEntity(payload: .todos([$0])) }
            }
            return InboxItemEntity(payload: payload).map { [$0] } ?? []
        }
    }

    /// 还原成 payload 供 `Ingestor.ingestParsed` 入库。
    func toPayload() -> ParsedPayload? {
        switch type {
        case .package:
            return .package(PackageInfo(
                carrier: carrier, trackingNumber: trackingNumber, trackingTail: trackingTail,
                pickupCode: pickupCode, station: station,
                status: PackageStatus(rawValue: packageStatusRaw ?? 0) ?? .inTransit))
        case .trip:
            guard let number = tripNumber,
                  let kind = tripKindRaw.flatMap(TripInfo.Kind.init) else { return nil }
            return .trip(TripInfo(
                kind: kind, number: number,
                departure: Self.components(departAt), departurePlace: departPlace,
                arrival: Self.components(arriveAt), arrivalPlace: arrivePlace, seat: seat))
        case .todo:
            guard let title = todoTitle else { return nil }
            return .todos([TodoInfo(title: title, due: Self.components(todoDue))])
        case .bookmark:
            guard let urlString, let url = URL(string: urlString) else { return nil }
            return .bookmark(BookmarkInfo(url: url, title: bookmarkTitle))
        case .expense:
            return .expense(expenseInfo)
        case .none:
            return nil
        }
    }

    /// 记账实体 → ExpenseInfo（确认节点入库用）
    var expenseInfo: ExpenseInfo {
        ExpenseInfo(
            direction: ExpenseDirection(rawValue: expenseDirectionRaw ?? "") ?? .expense,
            amount: amount.map { Decimal($0) },
            merchant: merchant, categoryMajor: categoryMajor, categorySub: categorySub,
            occurredAt: Self.components(occurredAt), channel: channel,
            cardTail: cardTail, txnID: txnID)
    }

    var isExpense: Bool { type == .expense }

    // MARK: DateComponents ↔ Date 桥接

    /// DateComponents → Date（复用 Ingestor 的宽容补年逻辑，仅在 MainActor 外也安全的纯计算）
    private static func date(_ components: DateComponents?) -> Date? {
        guard var c = components else { return nil }
        let cal = Calendar.current
        if c.year == nil { c.year = cal.component(.year, from: .now) }
        return cal.date(from: c)
    }

    /// Date → DateComponents（拆到分，供还原 payload；Ingestor.resolveDate 会再补全）
    private static func components(_ date: Date?) -> DateComponents? {
        guard let date else { return nil }
        return Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date)
    }
}

// MARK: - EntityQuery（瞬态实体，无持久查询）

struct InboxItemEntityQuery: EntityQuery {
    func entities(for identifiers: [InboxItemEntity.ID]) async throws -> [InboxItemEntity] { [] }
    func suggestedEntities() async throws -> [InboxItemEntity] { [] }
}
