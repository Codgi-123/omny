import AppIntents
import Foundation
import OmnyCore

/// 快捷指令 Intent 之间传递的结构化条目实体。
///
/// 作用：让「解析文本 / 屏幕识别」输出解析结果、「确认记账」接收之，全程**不落库**——
/// 确认通过后才第一次入库（确认前用户在 App 里看不到未确认数据）。
///
/// **跨 Intent 传值机制（关键，踩过坑）**：AppEntity 在快捷指令两动作间传递时，只有 `@Property`
/// 标注的属性才会被系统序列化携带；裸 `var` 字段会全部丢失（曾导致「确认记账」收到空壳实体、
/// 弹窗反问「条目」、结果「没有记账」）。故把所有数据放进纯数据结构 `Payload`（Codable），
/// 编码成 JSON 存进**唯一的 `@Property var data`** 传递；接收方用 `payload` 从 data 解回。
/// 单个 String @Property 是 App Intents 最可靠的传递类型。
///
/// `Payload` 里时间用 `Date?`（App Intents/JSON 友好，不用 DateComponents）；金额用 `Double`
/// （不支持 Decimal），与 `ExpenseInfo` 转换时还原。
struct InboxItemEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "识别条目"
    static let defaultQuery = InboxItemEntityQuery()

    var id = UUID()

    /// 唯一被系统序列化传递的载体：`Payload` 的 JSON 编码。
    @Property(title: "数据")
    var data: String

    init(payload: Payload) {
        self.data = (try? JSONEncoder().encode(payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    /// 无参构造：系统实例化 AppEntity 时用（data 空，payload 解出空载荷）
    init() {
        self.data = "{}"
    }

    /// 从 `data`（JSON）解出数据结构。传递后只有 data 有值，靠它还原。
    var payload: Payload {
        guard let d = data.data(using: .utf8),
              let p = try? JSONDecoder().decode(Payload.self, from: d)
        else { return Payload(typeRaw: "") }
        return p
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(payload.intentSummary)")
    }
}

// MARK: - 纯数据载荷（Codable，承载全部字段，跨 Intent 靠它 JSON 传递）

extension InboxItemEntity {
    struct Payload: Codable, Sendable {
        /// 类型：package/trip/todo/bookmark/expense（对应 OmnyCore.ItemType）
        var typeRaw: String

        /// 解析来源的原始文本。确认阶段补分类要靠它喂 LLM（口语句子常无独立商户名，
        /// 只有原文能让 LLM 判出"餐饮/午餐"）。对齐 Ingestor.categorizeExpense 的做法。
        var rawText: String?

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
        var amount: Double?
        var merchant: String?
        var categoryMajor: String?
        var categorySub: String?
        var occurredAt: Date?
        var channel: String?
        var cardTail: String?
        var txnID: String?

        var type: ItemType? { ItemType(rawValue: typeRaw) }
        var isExpense: Bool { type == .expense }

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

        /// 记账载荷 → ExpenseInfo（确认节点入库用）
        var expenseInfo: ExpenseInfo {
            ExpenseInfo(
                direction: ExpenseDirection(rawValue: expenseDirectionRaw ?? "") ?? .expense,
                amount: amount.map { Decimal($0) },
                merchant: merchant, categoryMajor: categoryMajor, categorySub: categorySub,
                occurredAt: Payload.components(occurredAt), channel: channel,
                cardTail: cardTail, txnID: txnID)
        }

        /// 还原成 payload 供 `Ingestor.ingestParsed` 入库。
        func toParsedPayload() -> ParsedPayload? {
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
                    departure: Payload.components(departAt), departurePlace: departPlace,
                    arrival: Payload.components(arriveAt), arrivalPlace: arrivePlace, seat: seat))
            case .todo:
                guard let title = todoTitle else { return nil }
                return .todos([TodoInfo(title: title, due: Payload.components(todoDue))])
            case .bookmark:
                guard let urlString, let url = URL(string: urlString) else { return nil }
                return .bookmark(BookmarkInfo(url: url, title: bookmarkTitle))
            case .expense:
                return .expense(expenseInfo)
            case .none:
                return nil
            }
        }

        // MARK: DateComponents ↔ Date 桥接

        /// DateComponents → Date（宽容补年）
        static func date(_ components: DateComponents?) -> Date? {
            guard var c = components else { return nil }
            let cal = Calendar.current
            if c.year == nil { c.year = cal.component(.year, from: .now) }
            return cal.date(from: c)
        }

        /// Date → DateComponents（拆到分，供还原 payload；Ingestor.resolveDate 会再补全）
        static func components(_ date: Date?) -> DateComponents? {
            guard let date else { return nil }
            return Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: date)
        }
    }
}

// MARK: - ParsedPayload → 实体

extension InboxItemEntity {
    /// 从单类 payload 构造（调用方保证已 flattened、非 .mixed）。返回 nil 表示该 payload 不产出实体。
    /// `rawText` 是解析来源原文，随实体带走供确认阶段补分类。
    init?(parsed: ParsedPayload, rawText: String?) {
        guard var p = Payload(parsed: parsed) else { return nil }
        p.rawText = rawText
        self.init(payload: p)
    }

    /// 把一批 payload 展平构造成实体数组（.todos 展开成多条待办实体）。
    /// `rawText` 为解析来源原文，写入每个实体。
    static func from(payloads: [ParsedPayload], rawText: String? = nil) -> [InboxItemEntity] {
        payloads.flatMap { $0.flattened }.flatMap { payload -> [InboxItemEntity] in
            if case .todos(let todos) = payload {
                return todos.compactMap { InboxItemEntity(parsed: .todos([$0]), rawText: rawText) }
            }
            return InboxItemEntity(parsed: payload, rawText: rawText).map { [$0] } ?? []
        }
    }

    /// 便捷：实体的类型/是否记账/入库 payload（从内部 Payload 透出）
    var isExpense: Bool { payload.isExpense }
    var intentSummary: String { payload.intentSummary }
    func toPayload() -> ParsedPayload? { payload.toParsedPayload() }
    var expenseInfo: ExpenseInfo { payload.expenseInfo }
}

extension InboxItemEntity.Payload {
    /// 从单类 ParsedPayload 构造纯数据载荷（.todos 取第一条；.mixed 返回 nil）。
    init?(parsed: ParsedPayload) {
        switch parsed {
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
            return nil
        }
    }
}

// MARK: - EntityQuery（瞬态实体，无持久查询）

struct InboxItemEntityQuery: EntityQuery {
    func entities(for identifiers: [InboxItemEntity.ID]) async throws -> [InboxItemEntity] { [] }
    func suggestedEntities() async throws -> [InboxItemEntity] { [] }
}
