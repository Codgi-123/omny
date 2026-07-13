import Foundation

/// 截图 OCR 分流器（识屏管线第一层）：规则信号加权投票，判定截图的主体类别。
/// 免费、离线、零延迟；判不出（无信号/信号不足）返回 nil，交第二层 LLM 分类兜底。
///
/// 三种信号，全部对 OCR 的行序混乱、拆词、截断免疫：
/// - UI 指纹（权重 5）：App 开发者写死的页面标题/App 名，整行或行首匹配——
///   「独占一行」本身是版式证据；同样的字符串出现在长句里只算词袋。
/// - 行内锚点（权重 3）：取件码/金额/车次号等在 UI 上渲染为单个视觉 token 的短模式。
///   Vision OCR 按视觉行输出、不会从 token 中间切断，故逐行正则可靠；
///   跨行句式正则对行序错乱免疫性差，一律不用。
/// - 词袋关键词（权重 1）：contains 跑在去掉全部空白的紧凑全文上
///   （中文无空格，去空白即把 OCR 拆散的「取件\n码」拼回）。
///
/// 词表与权重用真实截图 OCR 语料校准（原型 scripts/screen_router_proto.swift，
/// 语料 scripts/samples/）。新增指纹/锚点时把对应截图的 OCR 文本脱敏后加进 ScreenRouterTests。
public enum ScreenRouter {

    public enum Category: String, CaseIterable, Sendable {
        case package, trip, expense, todo
    }

    /// 路由结论。category 为 nil 表示无信号/信号不足，交第二层 LLM 分类。
    /// scores 供测试断言与调试展示。
    public struct Decision: Sendable, Equatable {
        public let category: Category?
        public let scores: [Category: Int]
    }

    // MARK: - 权重与阈值（真实语料校准值，改动需过 ScreenRouterTests）

    static let fingerprintWeight = 5   // 指纹单独命中即可路由
    static let anchorWeight = 3        // 锚点需一个词袋词佐证才达标
    static let keywordWeight = 1       // 纯词袋需 4 个不同词
    static let routeThreshold = 4      // 达标线
    static let leadThreshold = 3       // 单类路由要求领先第二名的最小差距
    static let fingerprintSlack = 2    // 指纹行首匹配允许行尾多出的杂字符数

    // MARK: - 信号词表

    /// UI 指纹：按「哪个 App 的哪个页面」收集。
    static let fingerprints: [Category: [String]] = [
        .expense: ["支付成功", "付款成功", "交易成功", "转账成功", "收款成功",
                   "账单详情", "交易详情", "零钱明细", "收款到账通知", "微信支付", "支付宝", "云闪付",
                   "红包详情", "二维码收款", "已存入零钱", "已收钱"],
        .package: ["菜鸟驿站", "菜鸟", "丰巢", "妈妈驿站", "快递超市",
                   "待取包裹", "待取件", "取件通知", "包裹详情"],
        .trip: ["铁路12306", "12306", "航旅纵横", "登机牌", "行程详情", "车票详情", "检票口", "登机口",
                "分享房源", "联系房东"],
        .todo: ["备忘录", "提醒事项", "待办事项", "滴答清单", "待办"],
    ]

    struct Anchor {
        let name: String
        let pattern: String
    }

    static let anchors: [Category: [Anchor]] = [
        .package: [
            Anchor(name: "取件码词", pattern: "取件码|取货码|提货码"),
            // 前后禁数字/横线：防吃掉日期 2026-07-13 的一段
            Anchor(name: "取件码形状", pattern: "(?<![\\d-])\\d{1,2}-\\d{1,2}-\\d{2,5}(?![\\d-])"),
            Anchor(name: "带前缀运单号", pattern: "SF\\d{12,15}|JD[A-Z0-9]{11,16}|YT\\d{13,15}"),
        ],
        .trip: [
            // 12306 界面上车次号是独立大字 token，常不带「次」，不要求后缀
            Anchor(name: "车次号", pattern: "(?<![A-Z0-9])[GDCZTKYSL]\\d{1,4}(?!\\d)"),
            Anchor(name: "航班号", pattern: "(?<![A-Z0-9])(?:CA|MU|CZ|HU|3U|MF|ZH|HO|9C|KN|SC|FM|EU|GS|8L|G5|PN|GJ|DR|DZ|KY|JD|TV|UQ)\\d{3,4}(?!\\d)"),
            Anchor(name: "座位号", pattern: "\\d{1,2}车\\d{1,3}[A-F]?号"),
            // 酒店：晚数（「2晚」）与入住/离店时刻（「14:00后入住」）都是行内单 token，酒店页独有
            Anchor(name: "晚数", pattern: "(?<!\\d)\\d{1,2}晚(?!\\d)"),
            Anchor(name: "入住离店时刻", pattern: "\\d{1,2}:\\d{2}[前后]?(?:入住|离店|退房)"),
        ],
        .expense: [
            // 金额锚点全部要求两位小数：交易金额几乎总带两位小数，
            // 价格标签常是整数（「¥440起」「¥263」不命中）——旅行/购物页防误触发
            Anchor(name: "独行金额", pattern: "^[-+]?[¥￥]?\\s*\\d[\\d,]*\\.\\d{2}$"),
            Anchor(name: "币符金额", pattern: "[¥￥]\\s*\\d[\\d,]*\\.\\d{2}(?!\\d)"),
            Anchor(name: "带元金额", pattern: "\\d[\\d,]*\\.\\d{2}元"),
            // 交易身份锚点（见 route 内的身份门槛）：银行卡措辞与交易单号标签词，
            // 都是交易记录页独有、订单页不会有。刻意不收「订单号」——订单页也有。
            Anchor(name: "银行卡交易", pattern: "储蓄卡|信用卡|借记卡|银行卡"),
            Anchor(name: "交易单号词", pattern: "交易单号|商户单号|转账单号|收款单号|流水号"),
        ],
        .todo: [],  // 待办是语义任务，无可靠锚点，靠指纹或第二层
    ]

    /// 命中即赋予记账「交易身份」的锚点名
    static let expenseIdentityAnchors: Set<String> = ["银行卡交易", "交易单号词"]

    /// 词袋：正文措辞。记账刻意不含单字与口语词（买/花/收到），截图正文里误命中率高。
    static let keywords: [Category: [String]] = [
        .package: ["快递", "快件", "包裹", "取件", "取货", "驿站", "运单", "派送", "签收", "丰巢", "代收"],
        .trip: ["列车", "车次", "次列车", "航班", "起飞", "登机", "检票", "乘车", "开车前", "航站楼",
                "车票", "购票", "12306", "无座", "动卧", "硬卧", "软卧", "商务座", "一等座", "二等座",
                "入住", "离店", "退房", "房源", "房东", "民宿", "酒店"],
        .expense: ["消费", "支出", "支付", "付款", "收入", "入账", "到账", "转账", "交易",
                   "扣款", "扣费", "还款", "充值", "退款"],
        .todo: [],
    ]

    // MARK: - 路由

    public static func route(_ text: String) -> Decision {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { normalize($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
        let compact = normalize(text.filter { !$0.isWhitespace })

        var scores: [Category: Int] = [:]
        var expenseIdentity = false

        for category in Category.allCases {
            var score = 0

            // ① UI 指纹：每行取最长命中的一个，跨行按指纹词去重。
            //    匹配前剥行首非字母数字字符——OCR 常把按钮/列表图标识别成「～」「◄」粘在行首。
            var seenFingerprints = Set<String>()
            for line in lines {
                let stripped = String(line.drop(while: { !$0.isLetter && !$0.isNumber }))
                let hit = (fingerprints[category] ?? [])
                    .filter { stripped == $0 || (stripped.hasPrefix($0) && stripped.count <= $0.count + fingerprintSlack) }
                    .max { $0.count < $1.count }
                if let hit, seenFingerprints.insert(hit).inserted {
                    score += fingerprintWeight
                    if category == .expense { expenseIdentity = true }
                }
            }

            // ② 行内锚点：逐行找，每个锚点最多计一次
            for anchor in anchors[category] ?? []
            where lines.contains(where: { matches(anchor.pattern, in: $0) }) {
                score += anchorWeight
                if category == .expense, expenseIdentityAnchors.contains(anchor.name) {
                    expenseIdentity = true
                }
            }

            // ③ 词袋：紧凑全文 contains，每词计一次
            score += (keywords[category] ?? []).count { compact.contains($0) } * keywordWeight
            scores[category] = score
        }

        // 记账身份门槛：金额和泛支付词在旅行/购物订单页上到处都是，但那是「订单价格」，
        // 不是一笔独立的交易记录。记账要成为路由类别，必须有「交易身份」信号——
        // 记账指纹（支付成功等页面标题）或身份锚点（银行卡措辞/交易单号标签词）。
        let strong = Category.allCases.filter {
            scores[$0]! >= routeThreshold && ($0 != .expense || expenseIdentity)
        }

        // 多类达标：混合暂不做，取最高分单类（通知中心混排会丢次要类，产品决定接受）
        if strong.count >= 2 {
            let winner = strong.max { scores[$0]! < scores[$1]! }!
            return Decision(category: winner, scores: scores)
        }
        // 恰一类达标：还需领先其余全部类别（含被身份门槛压下的记账）足够多，
        // 对手分数高说明证据矛盾，宁可交第二层不硬猜
        if let winner = strong.first {
            let runnerUp = Category.allCases.filter { $0 != winner }.map { scores[$0]! }.max() ?? 0
            if scores[winner]! - runnerUp >= leadThreshold {
                return Decision(category: winner, scores: scores)
            }
        }
        return Decision(category: nil, scores: scores)
    }

    // MARK: - 匹配底层

    /// 归一化：全角 ASCII→半角（！→!、（→(、０→0）、全角￥→¥、字母大写。
    /// 手写映射而非 applyingTransform——Linux Foundation 对 StringTransform 的支持不稳。
    static func normalize(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0xFF01...0xFF5E:
                scalars.append(Unicode.Scalar(scalar.value - 0xFEE0)!)
            case 0xFFE5:
                scalars.append("¥")
            case 0x3000:
                scalars.append(" ")
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars).uppercased()
    }

    /// 逐次编译正则（NSRegularExpression 非 Sendable，不做静态缓存；
    /// 路由每屏只跑一次、模式仅十余条，编译开销可忽略）
    static func matches(_ pattern: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }
}
