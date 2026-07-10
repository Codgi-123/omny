import Foundation

/// 条目类型：所有入口进来的信息最终都归为这四类之一。
public enum ItemType: String, Codable, Sendable, CaseIterable {
    case package
    case trip
    case todo
    case bookmark
}

// MARK: - 各类型的结构化载荷

/// 包裹状态，由短信内容推断。数值越大越靠后，
/// 同一单号收到多条短信时状态只向前推进、不回退。
public enum PackageStatus: Int, Codable, Sendable, Comparable {
    case inTransit = 0      // 已揽收/运输中
    case outForDelivery = 1 // 派送中
    case awaitingPickup = 2 // 已到驿站/柜机，待取 —— 核心状态
    case pickedUp = 3       // 已签收/已取出

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PackageInfo: Equatable, Sendable, Codable {
    /// 快递公司，如 "顺丰速运"，识别不出为 nil
    public var carrier: String?
    /// 运单号，同一包裹多条短信靠它合并
    public var trackingNumber: String?
    /// 运单尾号（驿站短信常只给尾号不给全单号），如 "6707"
    public var trackingTail: String?
    /// 取件码，如 "3-2-2011"、"16009"
    public var pickupCode: String?
    /// 存放点，如 "河畔小区菜鸟驿站"
    public var station: String?
    public var status: PackageStatus

    public init(carrier: String? = nil, trackingNumber: String? = nil,
                trackingTail: String? = nil, pickupCode: String? = nil,
                station: String? = nil, status: PackageStatus = .inTransit) {
        self.carrier = carrier
        self.trackingNumber = trackingNumber
        self.trackingTail = trackingTail
        self.pickupCode = pickupCode
        self.station = station
        self.status = status
    }
}

public struct TripInfo: Equatable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable {
        case train
        case flight
    }

    public var kind: Kind
    /// 车次/航班号，如 "G101"、"CA1831"
    public var number: String
    /// 出发日期时间（可能只有月日，或只有时分）
    public var departure: DateComponents?
    public var departurePlace: String?
    public var arrival: DateComponents?
    public var arrivalPlace: String?
    /// 座位，如 "7车12A号"
    public var seat: String?

    public init(kind: Kind, number: String,
                departure: DateComponents? = nil, departurePlace: String? = nil,
                arrival: DateComponents? = nil, arrivalPlace: String? = nil,
                seat: String? = nil) {
        self.kind = kind
        self.number = number
        self.departure = departure
        self.departurePlace = departurePlace
        self.arrival = arrival
        self.arrivalPlace = arrivalPlace
        self.seat = seat
    }
}

public struct TodoInfo: Equatable, Sendable, Codable {
    public var title: String
    public var due: DateComponents?

    public init(title: String, due: DateComponents? = nil) {
        self.title = title
        self.due = due
    }
}

public struct BookmarkInfo: Equatable, Sendable, Codable {
    public var url: URL
    public var title: String?

    public init(url: URL, title: String? = nil) {
        self.url = url
        self.title = title
    }
}

// MARK: - 解析结果

public enum ParsedPayload: Equatable, Sendable {
    case package(PackageInfo)
    case trip(TripInfo)
    /// 一段文本里可能识别出多条待办（截图 OCR 场景）
    case todos([TodoInfo])
    case bookmark(BookmarkInfo)
    /// 一屏多条多类（截图 OCR 场景）：一次识别里同时含快递/行程/待办等不同类型。
    /// 下游 Ingestor 递归展开逐条落库。不应再嵌套 .mixed。
    case mixed([ParsedPayload])

    public var itemType: ItemType {
        switch self {
        case .package: .package
        case .trip: .trip
        case .todos: .todo
        case .bookmark: .bookmark
        // mixed 无单一类型：取首个子载荷的类型（仅用于白名单粗筛等场景；
        // 真正落库靠 Ingestor 递归展开，不依赖这里）。空则回退 todo。
        case .mixed(let payloads): payloads.first?.itemType ?? .todo
        }
    }

    /// 展平成单类载荷列表：非 mixed 返回自身，mixed 返回其子载荷（一层，不递归嵌套）。
    /// 供 Ingestor 统一遍历落库。
    public var flattened: [ParsedPayload] {
        switch self {
        case .mixed(let payloads): payloads.flatMap { $0.flattened }
        default: [self]
        }
    }
}

public struct ParseResult: Equatable, Sendable {
    public var payload: ParsedPayload
    /// 0...1，规则命中核心字段给高分；管线用它决定是否落给 LLM 兜底
    public var confidence: Double
    public var rawText: String

    public init(payload: ParsedPayload, confidence: Double, rawText: String) {
        self.payload = payload
        self.confidence = confidence
        self.rawText = rawText
    }
}
