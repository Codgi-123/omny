import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 截图 OCR 专用解析器：从"一屏多条多类 + 噪声"的脏文本里一次抽出所有条目。
///
/// 与短信入口的 `LLMStructuredParser`（整段归一类）不同，截图一屏常同时含
/// 快递、行程、待办等多类，且混着时间戳、"无更多文本"、界面元素、被截断的残句。
/// 本解析器用一个 LLM prompt 一次抽出 `{packages,trips,todos}` 三个数组，返回 `.mixed`。
/// 未配置 LLM / LLM 不可用时降级：按行切分逐行走规则（至少抠出快递/行程），
/// 规则也识别不出的行不产出（待办是语义任务，无 LLM 时抽不了，交由上层把原文兜进需处理）。
public struct ScreenParser: Parser {
    public var config: LLMConfig?
    public var transport: any HTTPTransport

    var client: LLMClient? {
        config.map { LLMClient(config: $0, transport: transport) }
    }

    /// config 为 nil 表示未配置 LLM，parse 走纯规则降级。
    public init(config: LLMConfig?, transport: any HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    static let systemPrompt = """
    你从手机截图 OCR 出的文本里提取待办、快递、行程、记账四类信息。文本来自任意 App 的截图\
    （备忘录、聊天、通知列表、支付成功页/账单详情等），夹杂大量噪声：时间戳（如"22:40""今天"）、\
    界面元素（"搜索""无更多文本""个备忘录""发起群收款"）、按钮文字、以及被截断的残句。\
    请只提取有实际意义的条目，忽略所有噪声；被截断残缺的条目尽量补全能确定的字段，\
    无法确定的字段填 null，绝不臆造。今天是 {TODAY}。
    输出 JSON，格式：
    {"todos":[{"title":"待办内容，动词开头","due":"ISO8601 或 null"}],\
    "packages":[{"carrier":"快递公司或 null","trackingNumber":"运单号或 null",\
    "trackingTail":"运单尾号或 null","pickupCode":"取件码或 null","station":"存放点或 null"}],\
    "trips":[{"kind":"train 或 flight","number":"车次/航班号","departure":"ISO8601 或 null",\
    "departurePlace":"出发地或 null","arrival":"ISO8601 或 null","arrivalPlace":"到达地或 null","seat":"座位或 null"}],\
    "expenses":[{"direction":"expense 或 income","amount":"金额数字字符串或 null",\
    "merchant":"商户/交易对方或 null","occurredAt":"交易时间 ISO8601 或 null",\
    "channel":"支付方式/银行/平台或 null","cardTail":"卡尾号或 null","txnID":"交易单号或 null"}]}
    记账字段说明（支付成功页/账单截图）：direction 支出填 expense、收入/退款/到账填 income\
    （金额带负号"-19.00"是支出，带正号是收入）；amount 只填数字（如"19.00"），不带货币符号/正负号/千分位逗号；\
    merchant 是收款商户名（如"美团""串串香"，取店名而非"商户全称"里的公司名）；\
    channel 是支付方式（如"成都银行储蓄卡""零钱""支付宝"）；cardTail 是支付卡尾号；\
    txnID 取"交易单号"（优先）而非"商户单号"。不要判断消费分类（餐饮/交通等），那由后续步骤处理。
    日期表述（明天、周五、7月10日）换算成 ISO8601；短信/OCR 常缺年份，缺年份就省略年份部分。\
    某一类没有就给空数组。只输出 JSON，不要任何其他文字。
    """

    struct Extracted: Decodable {
        struct Todo: Decodable { let title: String; let due: String? }
        struct Package: Decodable {
            let carrier: String?; let trackingNumber: String?; let trackingTail: String?
            let pickupCode: String?; let station: String?
        }
        struct Trip: Decodable {
            let kind: String?; let number: String?
            let departure: String?; let departurePlace: String?
            let arrival: String?; let arrivalPlace: String?; let seat: String?
        }
        struct Expense: Decodable {
            let direction: String?; let amount: String?; let merchant: String?
            let occurredAt: String?; let channel: String?; let cardTail: String?; let txnID: String?
        }
        let todos: [Todo]?
        let packages: [Package]?
        let trips: [Trip]?
        let expenses: [Expense]?
    }

    public func parse(_ text: String) async throws -> ParseResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let client else {
            // 无 LLM：纯规则降级
            return ruleFallback(trimmed)
        }

        // LLM 路径。任何环节失败（网络/端点/超时/响应格式）都回退到规则降级，
        // 保证配了 LLM 但 LLM 暂时不可用时，纯净快递/行程仍能被规则抠出落库，而不是全丢进需处理。
        let extracted: Extracted
        do {
            let system = Self.systemPrompt.replacingOccurrences(
                of: "{TODAY}", with: ISO8601DateFormatter().string(from: Date()))
            let jsonText = try await client.send(system: system, user: trimmed,
                                                 schema: Self.outputSchema)
            extracted = try JSONDecoder().decode(Extracted.self, from: Data(jsonText.utf8))
        } catch {
            return ruleFallback(trimmed)
        }

        var payloads: [ParsedPayload] = []

        // 快递：至少有一个可用字段才收
        for p in extracted.packages ?? [] {
            var info = PackageInfo(
                carrier: p.carrier?.nilIfEmpty, trackingNumber: p.trackingNumber?.nilIfEmpty,
                trackingTail: p.trackingTail?.nilIfEmpty, pickupCode: p.pickupCode?.nilIfEmpty,
                station: p.station?.nilIfEmpty)
            let hasAny = info.carrier != nil || info.trackingNumber != nil
                || info.trackingTail != nil || info.pickupCode != nil || info.station != nil
            guard hasAny else { continue }
            info.status = RuleParser.detectStatus(trimmed, info: info)
            payloads.append(.package(info))
        }

        // 行程：kind + number 是硬要求
        for t in extracted.trips ?? [] {
            guard let kind = TripInfo.Kind(rawValue: t.kind ?? ""),
                  let number = t.number?.nilIfEmpty else { continue }
            payloads.append(.trip(TripInfo(
                kind: kind, number: number,
                departure: t.departure.flatMap(LLMClient.dateComponents(fromISO:)),
                departurePlace: t.departurePlace?.nilIfEmpty,
                arrival: t.arrival.flatMap(LLMClient.dateComponents(fromISO:)),
                arrivalPlace: t.arrivalPlace?.nilIfEmpty, seat: t.seat?.nilIfEmpty)))
        }

        // 记账：金额是硬要求（抠不出金额的记账条目无意义，交由噪声忽略）
        for e in extracted.expenses ?? [] {
            guard let amount = e.amount?.nilIfEmpty.flatMap({ Decimal(string: $0) }) else { continue }
            let direction = ExpenseDirection(rawValue: e.direction ?? "") ?? .expense
            payloads.append(.expense(ExpenseInfo(
                direction: direction, amount: amount,
                merchant: e.merchant?.nilIfEmpty,
                occurredAt: e.occurredAt.flatMap(LLMClient.dateComponents(fromISO:)),
                channel: e.channel?.nilIfEmpty, cardTail: e.cardTail?.nilIfEmpty,
                txnID: e.txnID?.nilIfEmpty)))
        }

        // 待办
        let todos = (extracted.todos ?? []).compactMap { todo -> TodoInfo? in
            let title = todo.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return TodoInfo(title: title, due: todo.due.flatMap(LLMClient.dateComponents(fromISO:)))
        }
        if !todos.isEmpty { payloads.append(.todos(todos)) }

        // LLM 一条都没抽出来时，再用规则兜一次（LLM 可能漏掉规则能命中的快递/行程）
        if payloads.isEmpty {
            return ruleFallback(trimmed)
        }
        return packResult(payloads, rawText: trimmed, confidence: 0.85)
    }

    /// 无 LLM 降级：按行切，逐行走规则，收集能识别的快递/行程。
    private func ruleFallback(_ text: String) -> ParseResult? {
        let rule = RuleParser()
        var payloads: [ParsedPayload] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard trimmedLine.count >= 4 else { continue }  // 太短的行多是噪声
            guard let r = rule.parseSync(trimmedLine) else { continue }
            // 规则不产出待办；收藏在截图里不作为目标，只收快递/行程/记账
            switch r.payload {
            case .package, .trip, .expense: payloads.append(r.payload)
            default: break
            }
        }
        // 降级置信度偏低，让下游标 needsReview 供用户确认
        return packResult(payloads, rawText: text, confidence: 0.6)
    }

    /// 0 条→nil；1 条→单类结果；多条→mixed。
    private func packResult(_ payloads: [ParsedPayload], rawText: String,
                            confidence: Double) -> ParseResult? {
        switch payloads.count {
        case 0: return nil
        case 1: return ParseResult(payload: payloads[0], confidence: confidence, rawText: rawText)
        default: return ParseResult(payload: .mixed(payloads), confidence: confidence, rawText: rawText)
        }
    }

    /// Claude structured outputs 的输出 schema
    static var outputSchema: [String: Any] {
        let packageItem: [String: Any] = [
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
        ]
        let tripItem: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": ["type": ["string", "null"]],
                "number": ["type": ["string", "null"]],
                "departure": ["type": ["string", "null"]],
                "departurePlace": ["type": ["string", "null"]],
                "arrival": ["type": ["string", "null"]],
                "arrivalPlace": ["type": ["string", "null"]],
                "seat": ["type": ["string", "null"]],
            ],
            "required": ["kind", "number", "departure", "departurePlace", "arrival", "arrivalPlace", "seat"],
            "additionalProperties": false,
        ]
        let todoItem: [String: Any] = [
            "type": "object",
            "properties": [
                "title": ["type": "string"],
                "due": ["type": ["string", "null"]],
            ],
            "required": ["title", "due"],
            "additionalProperties": false,
        ]
        let expenseItem: [String: Any] = [
            "type": "object",
            "properties": [
                "direction": ["type": "string", "enum": ["expense", "income"]] as [String: Any],
                "amount": ["type": ["string", "null"]],
                "merchant": ["type": ["string", "null"]],
                "occurredAt": ["type": ["string", "null"]],
                "channel": ["type": ["string", "null"]],
                "cardTail": ["type": ["string", "null"]],
                "txnID": ["type": ["string", "null"]],
            ],
            "required": ["direction", "amount", "merchant", "occurredAt", "channel", "cardTail", "txnID"],
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": [
                "todos": ["type": "array", "items": todoItem] as [String: Any],
                "packages": ["type": "array", "items": packageItem] as [String: Any],
                "trips": ["type": "array", "items": tripItem] as [String: Any],
                "expenses": ["type": "array", "items": expenseItem] as [String: Any],
            ],
            "required": ["todos", "packages", "trips", "expenses"],
            "additionalProperties": false,
        ]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
