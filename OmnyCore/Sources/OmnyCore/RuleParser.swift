import Foundation

/// 规则解析引擎：面向模板化文本（短信通知为主），正则提取，零成本、离线、即时。
/// 覆盖不了的自由文本（截图待办等）返回 nil，由管线落给 LLM。
public struct RuleParser: Parser {

    public init() {}

    public func parse(_ text: String) async throws -> ParseResult? {
        parseSync(text)
    }

    public func parseSync(_ text: String) -> ParseResult? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        switch Self.classify(text) {
        case .package:
            let info = Self.extractPackage(text)
            let confidence = info.trackingNumber != nil || info.pickupCode != nil ? 0.9 : 0.6
            return ParseResult(payload: .package(info), confidence: confidence, rawText: text)
        case .trip:
            guard let info = Self.extractTrip(text) else { return nil }
            return ParseResult(payload: .trip(info), confidence: 0.9, rawText: text)
        case .bookmark:
            guard let info = Self.extractBookmark(text) else { return nil }
            return ParseResult(payload: .bookmark(info), confidence: 0.95, rawText: text)
        case .expense:
            guard let info = Self.extractExpense(text) else { return nil }
            // 抽出金额高置信，只有方向/尾号等零散字段则低置信 → 下游标 needsReview
            let confidence = info.amount != nil ? 0.9 : 0.6
            return ParseResult(payload: .expense(info), confidence: confidence, rawText: text)
        case .todo, nil:
            // 待办识别是语义任务，规则层不做，交给 LLM
            return nil
        }
    }

    // MARK: - 分类

    static let packageKeywords = ["快递", "快件", "包裹", "取件", "取货", "驿站", "运单", "派送", "签收", "丰巢", "代收"]
    static let tripKeywords = ["列车", "车次", "次列车", "航班", "起飞", "登机", "检票", "乘车", "开车前"]
    /// 记账交易动词：出现其一才可能是记账文本（配合金额特征双命中，降低误判）。
    /// 两类措辞并存：① 银行短信正式词（消费/入账/扣款…）；② 手输/语音的口语词（买/花/充值…）。
    /// 单字口语词（买/花）靠"必须同时命中金额特征"兜底——无金额的「买了个表真好看」不会误判。
    static let expenseVerbs = [
        // 银行短信正式措辞
        "消费", "支出", "支付", "付款", "收入", "入账", "到账", "转账", "交易", "扣款", "扣费", "还款",
        // 口语措辞（手动输入 / 语音转文字）
        "买", "花", "充值", "充了", "付了", "收到", "赚", "卖",
    ]

    static func classify(_ text: String) -> ItemType? {
        let packageScore = packageKeywords.count { text.contains($0) }
        let tripScore = tripKeywords.count { text.contains($0) }
        if tripScore > 0 && tripScore >= packageScore { return .trip }
        if packageScore > 0 { return .package }
        // 记账：要求「金额特征 + 交易动词」双命中。放在快递/行程之后（那些短信偶尔也带金额，
        // 但快递/行程关键词更强、更该优先），bookmark 之前。
        if hasAmount(text) && expenseVerbs.contains(where: text.contains) { return .expense }
        if text.contains("http://") || text.contains("https://") { return .bookmark }
        return nil
    }

    /// 是否含金额特征：￥/¥ 前缀、"数字元"、或带两位小数的金额（避免把纯序号/单号误判成金额）
    static func hasAmount(_ text: String) -> Bool {
        text.firstMatch(of: /[¥￥]\s*\d/) != nil
            || text.firstMatch(of: /\d(?:[\d,]*\d)?(?:\.\d{1,2})?\s*元/) != nil
            || text.firstMatch(of: /\d[\d,]*\.\d{2}(?![\d])/) != nil
    }

    // MARK: - 快递

    static let carriers: [(keyword: String, name: String)] = [
        ("顺丰", "顺丰速运"), ("京东", "京东物流"), ("圆通", "圆通速递"),
        ("中通", "中通快递"), ("申通", "申通快递"), ("韵达", "韵达快递"),
        ("极兔", "极兔速递"), ("德邦", "德邦快递"), ("EMS", "EMS"), ("邮政", "中国邮政"),
    ]

    /// 快递公司识别。发件方常是驿站/商家（【韵达超市】送申通件、【京东】发中通件），
    /// 所以优先找"紧跟着快递/速运/速递/物流"的公司名（"申通快递"），
    /// 找不到再退化为全文关键词。
    static func detectCarrier(_ text: String) -> String? {
        if let m = text.firstMatch(of: /(顺丰|京东|圆通|中通|申通|韵达|极兔|德邦|邮政|EMS)(?=快递|速运|速递|物流)/) {
            let keyword = String(m.output.1)
            return carriers.first { $0.keyword == keyword }?.name
        }
        return carriers.first { text.contains($0.keyword) }?.name
    }

    static func extractPackage(_ text: String) -> PackageInfo {
        var info = PackageInfo()
        info.carrier = detectCarrier(text)

        // 带公司前缀的单号格式优先，其次靠上下文词，最后是裸长数字
        if let m = text.firstMatch(of: /SF\d{12,15}/) {
            info.trackingNumber = String(m.output)
            info.carrier = info.carrier ?? "顺丰速运"
        } else if let m = text.firstMatch(of: /JD[A-Z0-9]{11,16}/) {
            info.trackingNumber = String(m.output)
            info.carrier = info.carrier ?? "京东物流"
        } else if let m = text.firstMatch(of: /YT\d{13,15}/) {
            info.trackingNumber = String(m.output)
            info.carrier = info.carrier ?? "圆通速递"
        } else if let m = text.firstMatch(of: /(?:运单号?|快递单号|单号)[:：]?\s*([A-Za-z0-9]{10,20})/) {
            info.trackingNumber = String(m.output.1)
        } else if let m = text.firstMatch(of: /(?:^|[^\d])(\d{12,15})(?!\d)/) {
            info.trackingNumber = String(m.output.1)
        }

        // 运单尾号：驿站短信常见"取运单尾号6707包裹"，无完整单号
        if let m = text.firstMatch(of: /尾号\s*(\d{3,6})/) {
            info.trackingTail = String(m.output.1)
        }

        // 取件码两种表述："取件码8-3-9012" 和 "凭54-1-6707到/取/领/免费取"
        if let m = text.firstMatch(of: /(?:取件码|取货码|提货码)[为是]?[:：]?\s*(\d{1,2}-\d{1,2}-\d{2,5}|\d{4,8})/) {
            info.pickupCode = String(m.output.1)
        } else if let m = text.firstMatch(of: /凭\s*(\d{1,2}-\d{1,2}-\d{2,5}|\d{4,8})\s*(?=[到取领免])/) {
            info.pickupCode = String(m.output.1)
        }

        // 存放点两种句式：
        // ①「已到/放在 + 地点后缀」——无强边界，靠后缀白名单圈定终点
        // ②「凭码到 X 取/领」——「到…取/领」本身是一对天然边界，不需后缀白名单，
        //   直接取中间内容（店名后缀是开放集合，白名单必漏，如"XX米业""XX农资"）
        if let m = text.firstMatch(of: /(?:已到|存放至|已?放至|已?放在|已投递至)([^，。,！!；;\s]{2,30}?(?:驿站|快递超市|快递柜|智能柜|门卫|物业|代收点|自提点|便利店|门市|超市|店|柜))/) {
            info.station = String(m.output.1)
        } else if let m = text.firstMatch(of: /凭[\d\-]+\s*到([^，。,！!；;\s]{2,30}?)[取领]/) {
            info.station = String(m.output.1)
        }

        info.status = detectStatus(text, info: info)
        return info
    }

    /// 从短信措辞推断包裹状态。判断顺序很重要：
    /// "已签收/已取出" 是终态最优先；有取件码/到站信息即为待取
    /// （到站短信常带 "已由快递员派送"，不能被派送中抢先命中）。
    static func detectStatus(_ text: String, info: PackageInfo) -> PackageStatus {
        if text.firstMatch(of: /已(?:签收|取出|被取走|取件|领取)/) != nil {
            return .pickedUp
        }
        if info.pickupCode != nil || info.station != nil
            || text.contains("已到") || text.contains("待取") || text.contains("取件码") {
            return .awaitingPickup
        }
        if text.contains("派送") || text.contains("派件") || text.contains("预计送达") {
            return .outForDelivery
        }
        return .inTransit
    }

    // MARK: - 行程

    static func extractTrip(_ text: String) -> TripInfo? {
        if let train = extractTrain(text) { return train }
        return extractFlight(text)
    }

    static func extractTrain(_ text: String) -> TripInfo? {
        guard let no = text.firstMatch(of: /(?:^|[^A-Z0-9])([GDCZTKYSL]\d{1,4})次/) else { return nil }
        var info = TripInfo(kind: .train, number: String(no.output.1))

        var departure = extractMonthDay(text) ?? DateComponents()
        if let m = text.firstMatch(of: /([\p{Han}]{2,8}?)站?(\d{1,2}):(\d{2})开/) {
            info.departurePlace = String(m.output.1)
            departure.hour = Int(m.output.2)
            departure.minute = Int(m.output.3)
        }
        if departure != DateComponents() { info.departure = departure }

        if let m = text.firstMatch(of: /(\d{1,2}车\d{1,3}[A-Fa-f]?号?)/) {
            info.seat = String(m.output.1)
        }
        // 检票口与席别：12306 通知短信常见（"检票口A6""二等座"），措辞可穷举，正则够用
        if let m = text.firstMatch(of: /检票口[:：]?\s*([A-Za-z]?\d{1,3}[A-Za-z]?)/) {
            info.ticketGate = String(m.output.1)
        }
        if let m = text.firstMatch(of: /(商务座|特等座|一等座|二等座|无座|硬座|软座|硬卧|软卧|动卧)/) {
            info.seatClass = String(m.output.1)
        }
        return info
    }

    /// 国内主要航司二字码。注意 JD(首都航空) 与京东运单前缀同形，
    /// 但航班号后仅 3-4 位数字、且要求命中行程关键词，不会混淆。
    static let airlineCodes: Set<String> = [
        "CA", "MU", "CZ", "HU", "3U", "MF", "ZH", "HO", "9C", "KN", "SC",
        "FM", "EU", "GS", "8L", "G5", "PN", "GJ", "DR", "DZ", "KY", "JD", "TV", "UQ",
    ]

    static func extractFlight(_ text: String) -> TripInfo? {
        guard let m = text.matches(of: /(?:^|[^A-Z0-9])([A-Z0-9]{2})(\d{3,4})(?!\d)/)
            .first(where: { airlineCodes.contains(String($0.output.1)) })
        else { return nil }

        var info = TripInfo(kind: .flight, number: String(m.output.1) + String(m.output.2))
        let monthDay = extractMonthDay(text)

        var departure = monthDay ?? DateComponents()
        if let d = text.firstMatch(of: /(\d{1,2}):(\d{2})从?([^，。,\s]{2,12}机场(?:T\d)?)起飞/) {
            departure.hour = Int(d.output.1)
            departure.minute = Int(d.output.2)
            info.departurePlace = String(d.output.3)
        } else if let d = text.firstMatch(of: /从?([^，。,\s]{2,12}机场(?:T\d)?)\s*(\d{1,2}):(\d{2})起飞/) {
            info.departurePlace = String(d.output.1)
            departure.hour = Int(d.output.2)
            departure.minute = Int(d.output.3)
        }
        if departure != DateComponents() { info.departure = departure }

        var arrival = DateComponents()
        if let a = text.firstMatch(of: /(\d{1,2}):(\d{2})到达([^，。,\s]{2,12}机场(?:T\d)?)/) {
            arrival.month = monthDay?.month
            arrival.day = monthDay?.day
            arrival.hour = Int(a.output.1)
            arrival.minute = Int(a.output.2)
            info.arrivalPlace = String(a.output.3)
        }
        if arrival != DateComponents() { info.arrival = arrival }

        return info
    }

    static func extractMonthDay(_ text: String) -> DateComponents? {
        guard let m = text.firstMatch(of: /(\d{1,2})月(\d{1,2})日/) else { return nil }
        var c = DateComponents()
        c.month = Int(m.output.1)
        c.day = Int(m.output.2)
        if let y = text.firstMatch(of: /(20\d{2})年/) { c.year = Int(y.output.1) }
        return c
    }

    // MARK: - 记账

    /// 收入措辞：命中其一判为收入，否则默认支出（消费文本支出居多）。
    /// 含银行短信正式词与口语词（收到/赚/卖），口语支出词（买/花）不在此列，故默认走支出。
    static let incomeKeywords = ["收入", "入账", "到账", "退款", "退回", "转入", "工资", "报销", "收到", "赚", "卖"]

    /// 无 LLM 时的记账降级：正则抠金额 + 卡尾号 + 方向。银行短信金额格式相对规整。
    /// 抽不出金额则返回 nil（交管线兜底/降级），不产"空账单"。
    static func extractExpense(_ text: String) -> ExpenseInfo? {
        var info = ExpenseInfo()
        info.amount = extractAmount(text)

        // 方向：命中收入词判收入，否则默认支出
        info.direction = incomeKeywords.contains(where: text.contains) ? .income : .expense

        // 卡尾号："尾号1234""尾号为1234"
        if let m = text.firstMatch(of: /尾号[为是]?\s*(\d{3,6})/) {
            info.cardTail = String(m.output.1)
        }
        info.occurredAt = extractMonthDay(text)

        // 金额抽不出、也没尾号 → 太弱，不产出
        guard info.amount != nil || info.cardTail != nil else { return nil }
        return info
    }

    /// 抠金额：优先 ￥/¥ 前缀，其次"数字元"，最后带两位小数的裸金额。支持千分位逗号。
    static func extractAmount(_ text: String) -> Decimal? {
        let patterns: [Regex<(Substring, Substring)>] = [
            /[¥￥]\s*([\d,]+(?:\.\d{1,2})?)/,
            /(?:人民币)?\s*([\d,]+(?:\.\d{1,2})?)\s*元/,
            /([\d,]+\.\d{2})(?![\d])/,
        ]
        for pattern in patterns {
            if let m = text.firstMatch(of: pattern) {
                let cleaned = String(m.output.1).replacingOccurrences(of: ",", with: "")
                if let value = Decimal(string: cleaned) { return value }
            }
        }
        return nil
    }

    // MARK: - 收藏

    /// 公开给 App 层直接用：分享/手动入口固定落成收藏，不走整条解析管线
    public static func extractBookmark(_ text: String) -> BookmarkInfo? {
        guard let m = text.firstMatch(of: /https?:\/\/[^\s，。＂"'<>）)]+/),
              let url = URL(string: String(m.output))
        else { return nil }
        // URL 之外的剩余文本作为初始标题（分享时常带一段描述）
        let title = text.replacingOccurrences(of: String(m.output), with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return BookmarkInfo(url: url, title: title.isEmpty ? nil : title)
    }
}
