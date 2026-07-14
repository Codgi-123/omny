import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 截图 OCR 专用解析器：三层管线。
///
/// 1. **规则路由**（`ScreenRouter`，免费/离线/零延迟）：UI 指纹 + 行内锚点 + 词袋投票，
///    判定截图主体类别。多类达标取最高分（混合暂不做，一屏视为一类主体）。
/// 2. **LLM 分类兜底**：路由无信号时（主要是备忘录/聊天类自由文本），LLM 五选一
///    （package/trip/expense/todo/none），enum 语义靠 prompt + 下游校验双重约束。
/// 3. **分类专用抽取**：按类别发窄 prompt + 窄 schema（对比旧四类合一大 prompt，
///    模型每次只面对一类字段口径），抽取后硬校验防臆造。
///
/// 降级：未配 LLM、LLM 任一环节失败、抽取为空——都回退按行走规则
/// （`ruleFallback`，至少抠出纯净快递/行程/记账），规则也不产出则返回 nil，
/// 上层把原文兜进「需处理」。字段口径：快递只抽公司/取件码/存放点，
/// 记账只抽方向/金额/时间（截图入口的瘦身决定；单号类字段不再抽取）。
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

    public func parse(_ text: String) async throws -> ParseResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let client else {
            // 无 LLM：纯规则降级
            return ruleFallback(trimmed)
        }

        // 第一层：规则路由；无信号时第二层 LLM 分类兜底
        var category = ScreenRouter.route(trimmed).category
        if category == nil {
            category = await classify(trimmed, client: client)
        }
        // 两层都给不出类别（none/分类失败）→ 规则兜一次（多半 nil → 上层落需处理，原文不丢）
        guard let category else { return ruleFallback(trimmed) }

        // 第三层：分类专用抽取。失败/空结果回退规则，保证 LLM 暂不可用时纯净条目仍能落库
        let payloads = await extract(trimmed, category: category, client: client)
        guard !payloads.isEmpty else { return ruleFallback(trimmed) }
        return packResult(payloads, rawText: trimmed, confidence: 0.85)
    }

    // MARK: - 第二层：LLM 分类（五选一）

    static let classifyPrompt = """
    你给手机截图 OCR 出的文本分类。文本很混乱：行序错乱、夹杂时间戳、按钮文字、广告、被截断的残句，\
    请忽略噪声，整体判断这张截图的主体内容属于哪一类：
    - package：快递物流（取件通知、驿站、运单、快递柜）
    - trip：行程（火车/航班的车票班次页、订票页，以及酒店/民宿的预订或订单页）
    - expense：交易记录（支付/收款成功页、账单详情、红包收款、银行动账通知）。\
    注意：订票/订房/购物的订单页上出现的金额是订单价格，不算交易记录，应归入其主体类别
    - todo：待办/备忘（备忘录、提醒事项清单、聊天记录里的任务安排约定）
    - none：以上都不是（纯闲聊、无实际信息的界面、风景照上的文字等）
    若同时包含多类内容，选信息主体最突出的一类。\
    只输出 JSON，不要任何其他文字：{"category":"package|trip|expense|todo|none","reason":"不超过20字的判断依据"}
    """

    struct ClassifyVerdict: Decodable {
        let category: String
    }

    /// 分类失败或判 none 都返回 nil（Category(rawValue:) 对 "none"/越界值天然返回 nil）
    func classify(_ text: String, client: LLMClient) async -> ScreenRouter.Category? {
        do {
            let jsonText = try await client.send(system: Self.classifyPrompt, user: text,
                                                 schema: Self.classifySchema, maxTokens: 128)
            let verdict = try JSONDecoder().decode(ClassifyVerdict.self, from: Data(jsonText.utf8))
            return ScreenRouter.Category(rawValue: verdict.category)
        } catch {
            return nil
        }
    }

    static var classifySchema: [String: Any] { [
        "type": "object",
        "properties": [
            "category": ["type": "string",
                         "enum": ["package", "trip", "expense", "todo", "none"]] as [String: Any],
            "reason": ["type": "string"],
        ],
        "required": ["category", "reason"],
        "additionalProperties": false,
    ] }

    // MARK: - 第三层：分类专用抽取

    /// 共享的噪声说明，四个专用 prompt 拼装用
    static let noisePreamble = """
    文本来自手机截图的 OCR，行序错乱、夹杂时间戳、界面按钮文字、广告、被截断的残句。\
    只提取有实际意义的条目，忽略所有噪声；被截断的条目尽量补全能确定的字段，\
    无法确定的字段填 null，绝不臆造。
    """

    static let extractPrompts: [ScreenRouter.Category: String] = [
        .package: """
        你从手机截图 OCR 出的文本里提取快递物流信息。\(noisePreamble)
        输出 JSON：{"packages":[{"carrier":"快递公司或 null","pickupCode":"取件码或 null",\
        "station":"存放点（驿站/快递柜/门卫等）或 null"}]}
        同一屏可能有多个包裹（驿站通知列表），逐个输出。没有就给空数组。只输出 JSON，不要任何其他文字。
        """,
        .trip: """
        你从手机截图 OCR 出的文本里提取行程信息（火车、航班、酒店/民宿）。\(noisePreamble)今天是 {TODAY}。
        输出 JSON：{"trips":[{"kind":"train 或 flight 或 hotel","number":"车次/航班号，酒店填 null",\
        "departure":"出发时间 ISO8601 或 null","departurePlace":"出发地或 null",\
        "arrival":"到达时间 ISO8601 或 null","arrivalPlace":"到达地或 null","seat":"座位/舱位/房型或 null"}]}
        酒店/民宿（kind=hotel）的字段映射：departure=入住时间、arrival=离店时间、\
        departurePlace=酒店或民宿名称（含分店名或地址）。
        只提取用户自己的行程，忽略页面里推荐、广告、比价的班次和价格。\
        日期表述（明天、周五、7月10日）换算成 ISO8601，缺年份就省略年份部分。\
        没有就给空数组。只输出 JSON，不要任何其他文字。
        """,
        .todo: """
        你从手机截图 OCR 出的文本里提取待办事项（备忘录、提醒清单、聊天里的任务安排约定）。\(noisePreamble)今天是 {TODAY}。
        输出 JSON：{"todos":[{"title":"待办内容，动词开头的短句","due":"截止/提醒时间 ISO8601 或 null"}]}
        日期表述换算成 ISO8601，缺年份就省略年份部分。没有就给空数组。只输出 JSON，不要任何其他文字。
        """,
        .expense: """
        你从手机截图 OCR 出的文本里提取交易记录（支付/收款成功页、账单详情、红包、银行动账通知）。\(noisePreamble)今天是 {TODAY}。
        输出 JSON：{"expenses":[{"direction":"expense 或 income","amount":"金额数字字符串",\
        "occurredAt":"交易时间 ISO8601 或 null"}]}
        规则：direction 只能填 expense（支出）或 income（收入）。收入的判断信号：金额带正号（如"+89.00"）、\
        或页面含「已收钱」「已存入零钱」「二维码收款」「收款成功」「红包」「退款」「到账」等收款措辞；\
        金额带负号（如"-19.00"）或含「支付成功」「付款」「消费」「扣款」措辞是支出。\
        amount 只填数字（如"19.00"），不带货币符号/正负号/千分位逗号。不要判断消费分类。\
        日期表述换算成 ISO8601，缺年份就省略年份部分。没有就给空数组。只输出 JSON，不要任何其他文字。
        """,
    ]

    /// 各类抽取的解码容器：四个数组共用一个结构（专用 prompt 只会填自己那类，其余为 nil）
    struct Extracted: Decodable {
        struct Package: Decodable {
            let carrier: String?; let pickupCode: String?; let station: String?
        }
        struct Trip: Decodable {
            let kind: String?; let number: String?
            let departure: String?; let departurePlace: String?
            let arrival: String?; let arrivalPlace: String?; let seat: String?
        }
        struct Todo: Decodable { let title: String?; let due: String? }
        struct Expense: Decodable {
            let direction: String?; let amount: String?; let occurredAt: String?
        }
        let packages: [Package]?
        let trips: [Trip]?
        let todos: [Todo]?
        let expenses: [Expense]?
    }

    /// 专用抽取 + 硬校验 → 载荷列表。任何失败（网络/格式）返回空数组，由上层回退规则。
    func extract(_ text: String, category: ScreenRouter.Category,
                 client: LLMClient) async -> [ParsedPayload] {
        let system = Self.extractPrompts[category]!.replacingOccurrences(
            of: "{TODAY}", with: ISO8601DateFormatter().string(from: Date()))
        guard let jsonText = try? await client.send(system: system, user: text,
                                                    schema: Self.extractSchema(for: category)),
              let extracted = try? JSONDecoder().decode(Extracted.self, from: Data(jsonText.utf8))
        else { return [] }

        var payloads: [ParsedPayload] = []
        switch category {
        case .package:
            // 硬校验：至少一个可用字段才收；状态不信 LLM，仍用正则从原文措辞推断
            for p in extracted.packages ?? [] {
                var info = PackageInfo(carrier: p.carrier?.nilIfEmpty,
                                       pickupCode: p.pickupCode?.nilIfEmpty,
                                       station: p.station?.nilIfEmpty)
                guard info.carrier != nil || info.pickupCode != nil || info.station != nil else { continue }
                info.status = RuleParser.detectStatus(text, info: info)
                payloads.append(.package(info))
            }
        case .trip:
            for t in extracted.trips ?? [] {
                guard let kind = TripInfo.Kind(rawValue: t.kind ?? "") else { continue }
                let number = t.number?.nilIfEmpty
                // 硬校验：火车/航班必须有班次号；酒店必须有入住时间或地点其一
                switch kind {
                case .train, .flight:
                    guard number != nil else { continue }
                case .hotel:
                    guard t.departure?.nilIfEmpty != nil || t.departurePlace?.nilIfEmpty != nil else { continue }
                }
                payloads.append(.trip(TripInfo(
                    kind: kind, number: number ?? "",
                    departure: t.departure.flatMap(LLMClient.dateComponents(fromISO:)),
                    departurePlace: t.departurePlace?.nilIfEmpty,
                    arrival: t.arrival.flatMap(LLMClient.dateComponents(fromISO:)),
                    arrivalPlace: t.arrivalPlace?.nilIfEmpty, seat: t.seat?.nilIfEmpty)))
            }
        case .todo:
            let todos = (extracted.todos ?? []).compactMap { todo -> TodoInfo? in
                guard let title = todo.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty else { return nil }
                return TodoInfo(title: title, due: todo.due.flatMap(LLMClient.dateComponents(fromISO:)))
            }
            if !todos.isEmpty { payloads.append(.todos(todos)) }
        case .expense:
            // 硬校验：金额是硬要求（抠不出金额的记账无意义，当噪声丢）
            for e in extracted.expenses ?? [] {
                guard let amount = e.amount?.nilIfEmpty.flatMap({ Decimal(string: $0) }) else { continue }
                payloads.append(.expense(ExpenseInfo(
                    direction: Self.direction(from: e.direction), amount: amount,
                    occurredAt: e.occurredAt.flatMap(LLMClient.dateComponents(fromISO:)))))
            }
        }
        return payloads
    }

    /// 方向宽容解析：模型输出 "Income"/"收入" 等变体不被静默当成支出
    static func direction(from raw: String?) -> ExpenseDirection {
        switch raw?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "income", "收入", "收款": .income
        default: .expense
        }
    }

    // MARK: - 规则降级与打包

    /// 无 LLM / LLM 失败降级：按行切，逐行走规则，收集能识别的快递/行程/记账。
    /// 规则不产出待办（语义任务，无 LLM 抽不了，交由上层把原文兜进需处理）。
    func ruleFallback(_ text: String) -> ParseResult? {
        let rule = RuleParser()
        var payloads: [ParsedPayload] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard trimmedLine.count >= 4 else { continue }  // 太短的行多是噪声
            guard let r = rule.parseSync(trimmedLine) else { continue }
            // 收藏在截图里不作为目标，只收快递/行程/记账
            switch r.payload {
            case .package, .trip, .expense: payloads.append(r.payload)
            default: break
            }
        }
        // 降级置信度偏低，让下游标 needsReview 供用户确认
        return packResult(payloads, rawText: text, confidence: 0.6)
    }

    /// 0 条→nil；1 条→单类结果；多条→mixed（现仅规则降级可能产出多条）。
    private func packResult(_ payloads: [ParsedPayload], rawText: String,
                            confidence: Double) -> ParseResult? {
        switch payloads.count {
        case 0: return nil
        case 1: return ParseResult(payload: payloads[0], confidence: confidence, rawText: rawText)
        default: return ParseResult(payload: .mixed(payloads), confidence: confidence, rawText: rawText)
        }
    }

    // MARK: - Claude structured outputs 的输出 schema（按类别取窄 schema）

    static func extractSchema(for category: ScreenRouter.Category) -> [String: Any] {
        let nullableString: [String: Any] = ["type": ["string", "null"]]
        let item: [String: Any]
        let key: String
        switch category {
        case .package:
            key = "packages"
            item = [
                "type": "object",
                "properties": ["carrier": nullableString, "pickupCode": nullableString,
                               "station": nullableString],
                "required": ["carrier", "pickupCode", "station"],
                "additionalProperties": false,
            ]
        case .trip:
            key = "trips"
            item = [
                "type": "object",
                "properties": [
                    "kind": ["type": ["string", "null"],
                             "enum": ["train", "flight", "hotel", NSNull()]] as [String: Any],
                    "number": nullableString,
                    "departure": nullableString, "departurePlace": nullableString,
                    "arrival": nullableString, "arrivalPlace": nullableString,
                    "seat": nullableString,
                ],
                "required": ["kind", "number", "departure", "departurePlace",
                             "arrival", "arrivalPlace", "seat"],
                "additionalProperties": false,
            ]
        case .todo:
            key = "todos"
            item = [
                "type": "object",
                "properties": ["title": ["type": "string"], "due": nullableString],
                "required": ["title", "due"],
                "additionalProperties": false,
            ]
        case .expense:
            key = "expenses"
            item = [
                "type": "object",
                "properties": [
                    "direction": ["type": "string", "enum": ["expense", "income"]] as [String: Any],
                    "amount": nullableString,
                    "occurredAt": nullableString,
                ],
                "required": ["direction", "amount", "occurredAt"],
                "additionalProperties": false,
            ]
        }
        return [
            "type": "object",
            "properties": [key: ["type": "array", "items": item] as [String: Any]],
            "required": [key],
            "additionalProperties": false,
        ]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
