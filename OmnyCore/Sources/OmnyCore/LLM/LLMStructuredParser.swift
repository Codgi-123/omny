import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 分类靠正则、结构化靠 LLM 的解析器。
/// 先用 `RuleParser.classify` 判类型（关键词命中，零成本、可靠），
/// 再按类型分派：快递/行程走 LLM 抽结构化字段（正则对多变短信文本泛化差），
/// 收藏直接走正则（URL 提取无需 LLM），待办/未分类返回 nil 交给管线兜底。
public struct LLMStructuredParser: Parser {
    public var config: LLMConfig
    public var transport: any HTTPTransport

    /// 请求构造/发送/响应解析的公共底座
    var client: LLMClient { LLMClient(config: config, transport: transport) }

    public init(config: LLMConfig, transport: any HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    public func parse(_ text: String) async throws -> ParseResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        switch RuleParser.classify(trimmed) {
        case .package:
            return try await parsePackage(trimmed)
        case .trip:
            return try await parseTrip(trimmed)
        case .bookmark:
            // 收藏就是抠 URL，正则足够，不花 LLM
            guard let info = RuleParser.extractBookmark(trimmed) else { return nil }
            return ParseResult(payload: .bookmark(info), confidence: 0.95, rawText: trimmed)
        case .expense:
            return try await parseExpense(trimmed)
        case .todo, nil:
            // 待办/未分类交给管线的 fallback（LLMTodoParser）
            return nil
        }
    }

    // MARK: - 快递

    private func parsePackage(_ text: String) async throws -> ParseResult? {
        let jsonText = try await client.send(
            system: Self.packageSystemPrompt, user: text, schema: Self.packageSchema)
        let extracted = try JSONDecoder().decode(ExtractedPackage.self, from: Data(jsonText.utf8))

        var info = PackageInfo(
            carrier: extracted.carrier?.nilIfEmpty,
            trackingNumber: extracted.trackingNumber?.nilIfEmpty,
            trackingTail: extracted.trackingTail?.nilIfEmpty,
            pickupCode: extracted.pickupCode?.nilIfEmpty,
            station: extracted.station?.nilIfEmpty)

        // LLM 抽取失败(字段全空)时返回 nil，交给管线兜底/降级，不产出"空快递卡"。
        // 强标识字段(取件码/单号/尾号)有则高置信；只有弱字段(公司/驿站)则低置信 → 下游标 needsReview 让用户确认。
        let hasStrongField = info.pickupCode != nil || info.trackingNumber != nil || info.trackingTail != nil
        let hasAnyField = hasStrongField || info.carrier != nil || info.station != nil
        guard hasAnyField else { return nil }

        // 状态词可穷举，正则判得又准又稳，不交给 LLM
        info.status = RuleParser.detectStatus(text, info: info)
        let confidence = hasStrongField ? 0.9 : 0.6
        return ParseResult(payload: .package(info), confidence: confidence, rawText: text)
    }

    struct ExtractedPackage: Decodable {
        let carrier: String?
        let trackingNumber: String?
        let trackingTail: String?
        let pickupCode: String?
        let station: String?
    }

    static let packageSystemPrompt = """
    你从中文快递短信里抽取结构化字段。只输出 JSON，不要任何其他文字，格式：\
    {"carrier":"快递公司全称或 null","trackingNumber":"完整运单号或 null",\
    "trackingTail":"运单尾号(驿站短信常只给尾号)或 null","pickupCode":"取件码/取货码或 null",\
    "station":"存放点/驿站/柜机名称或 null"}。\
    字段含义：carrier 如"顺丰速运""京东物流"；trackingNumber 是完整运单号；\
    trackingTail 是仅有尾号时的那几位数字；pickupCode 如"3-2-2011""16009"；\
    station 如"河畔小区菜鸟驿站""丰巢快递柜"。识别不出的字段填 null，不要臆造。\
    不要判断包裹状态，那由本地规则处理。
    """

    /// Claude structured outputs 的快递 JSON Schema
    static var packageSchema: [String: Any] { [
        "type": "object",
        "properties": [
            "carrier": ["type": ["string", "null"]],
            "trackingNumber": ["type": ["string", "null"]],
            "trackingTail": ["type": ["string", "null"]],
            "pickupCode": ["type": ["string", "null"]],
            "station": ["type": ["string", "null"]],
        ],
        "required": ["carrier", "trackingNumber", "trackingTail", "pickupCode", "station"],
        "additionalProperties": false,
    ] }

    // MARK: - 行程

    private func parseTrip(_ text: String) async throws -> ParseResult? {
        let jsonText = try await client.send(
            system: Self.tripSystemPrompt, user: text, schema: Self.tripSchema)
        let extracted = try JSONDecoder().decode(ExtractedTrip.self, from: Data(jsonText.utf8))

        guard let kind = TripInfo.Kind(rawValue: extracted.kind ?? ""),
              let number = extracted.number?.nilIfEmpty
        else { return nil }

        let info = TripInfo(
            kind: kind,
            number: number,
            departure: extracted.departure.flatMap(LLMClient.dateComponents(fromISO:)),
            departurePlace: extracted.departurePlace?.nilIfEmpty,
            arrival: extracted.arrival.flatMap(LLMClient.dateComponents(fromISO:)),
            arrivalPlace: extracted.arrivalPlace?.nilIfEmpty,
            seat: extracted.seat?.nilIfEmpty,
            ticketGate: extracted.ticketGate?.nilIfEmpty,
            seatClass: extracted.seatClass?.nilIfEmpty)
        return ParseResult(payload: .trip(info), confidence: 0.9, rawText: text)
    }

    struct ExtractedTrip: Decodable {
        let kind: String?
        let number: String?
        let departure: String?
        let departurePlace: String?
        let arrival: String?
        let arrivalPlace: String?
        let seat: String?
        let ticketGate: String?
        let seatClass: String?
    }

    static let tripSystemPrompt = """
    你从中文行程短信（火车票/机票通知）里抽取结构化字段。只输出 JSON，不要任何其他文字，格式：\
    {"kind":"train 或 flight","number":"车次或航班号","departure":"出发时间 ISO8601 或 null",\
    "departurePlace":"出发地/车站/机场或 null","arrival":"到达时间 ISO8601 或 null",\
    "arrivalPlace":"到达地或 null","seat":"座位或 null","ticketGate":"检票口/登机口或 null",\
    "seatClass":"席别/舱位或 null"}。\
    字段含义：kind 火车填 train、飞机填 flight；number 如"G101""CA1831"；\
    seat 如"7车12A号"；ticketGate 如"A6""B12"（只填口号，不带"检票口"字样）；\
    seatClass 如"二等座""一等座""商务座""经济舱"。\
    日期时间用 ISO8601 表示；短信常缺年份，缺年份就省略年份部分\
    （如"07-10T08:30:00"），不要臆造年份，下游会补。识别不出的字段填 null。
    """

    /// Claude structured outputs 的行程 JSON Schema
    static var tripSchema: [String: Any] { [
        "type": "object",
        "properties": [
            "kind": ["type": "string", "enum": ["train", "flight"]] as [String: Any],
            "number": ["type": "string"],
            "departure": ["type": ["string", "null"]],
            "departurePlace": ["type": ["string", "null"]],
            "arrival": ["type": ["string", "null"]],
            "arrivalPlace": ["type": ["string", "null"]],
            "seat": ["type": ["string", "null"]],
            "ticketGate": ["type": ["string", "null"]],
            "seatClass": ["type": ["string", "null"]],
        ],
        "required": ["kind", "number", "departure", "departurePlace",
                     "arrival", "arrivalPlace", "seat", "ticketGate", "seatClass"],
        "additionalProperties": false,
    ] }

    // MARK: - 记账

    private func parseExpense(_ text: String) async throws -> ParseResult? {
        let jsonText = try await client.send(
            system: Self.expenseSystemPrompt, user: text, schema: Self.expenseSchema)
        let extracted = try JSONDecoder().decode(ExtractedExpense.self, from: Data(jsonText.utf8))

        // 金额用字符串传，本地转 Decimal（避开 JSON 浮点精度）
        let amount = extracted.amount?.nilIfEmpty.flatMap { Decimal(string: $0) }
        let direction = ExpenseDirection(rawValue: extracted.direction ?? "") ?? .expense

        var info = ExpenseInfo(
            direction: direction,
            amount: amount,
            merchant: extracted.merchant?.nilIfEmpty,
            occurredAt: extracted.occurredAt.flatMap(LLMClient.dateComponents(fromISO:)),
            channel: extracted.channel?.nilIfEmpty,
            cardTail: extracted.cardTail?.nilIfEmpty)
        // 分类不由结构化 LLM 打，交给 LLMExpenseCategorizer 异步补，故这里留空
        info.categoryMajor = nil
        info.categorySub = nil

        // 金额抽不出、也没商户/尾号 → 太弱，返回 nil 交兜底/降级，不产"空账单卡"
        let hasStrongField = info.amount != nil
        let hasAnyField = hasStrongField || info.merchant != nil || info.cardTail != nil
        guard hasAnyField else { return nil }

        let confidence = hasStrongField ? 0.9 : 0.6
        return ParseResult(payload: .expense(info), confidence: confidence, rawText: text)
    }

    struct ExtractedExpense: Decodable {
        let direction: String?
        let amount: String?
        let merchant: String?
        let occurredAt: String?
        let channel: String?
        let cardTail: String?
    }

    static let expenseSystemPrompt = """
    你从中文银行/支付动账短信里抽取记账字段。只输出 JSON，不要任何其他文字，格式：\
    {"direction":"expense 或 income","amount":"金额数字字符串或 null",\
    "merchant":"商户/交易对方或 null","occurredAt":"交易时间 ISO8601 或 null",\
    "channel":"银行/支付平台或 null","cardTail":"卡尾号或 null"}。\
    字段含义：direction 支出填 expense、收入/入账/到账/退款填 income；\
    amount 只填数字（如 "128.50"），不带货币符号、不带千分位逗号；\
    merchant 如 "美团""星巴克""滴滴出行"；channel 如 "招商银行""支付宝""微信"；\
    cardTail 是卡号后几位数字。日期用 ISO8601；短信常缺年份，缺年份就省略年份部分，不要臆造。\
    不要判断消费分类（餐饮/交通等），那由后续步骤处理。识别不出的字段填 null。
    """

    /// Claude structured outputs 的记账 JSON Schema
    static var expenseSchema: [String: Any] { [
        "type": "object",
        "properties": [
            "direction": ["type": "string", "enum": ["expense", "income"]] as [String: Any],
            "amount": ["type": ["string", "null"]],
            "merchant": ["type": ["string", "null"]],
            "occurredAt": ["type": ["string", "null"]],
            "channel": ["type": ["string", "null"]],
            "cardTail": ["type": ["string", "null"]],
        ],
        "required": ["direction", "amount", "merchant", "occurredAt", "channel", "cardTail"],
        "additionalProperties": false,
    ] }
}

private extension String {
    /// 空串归一成 nil：LLM 偶尔把"识别不出"写成空串而非 null
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
