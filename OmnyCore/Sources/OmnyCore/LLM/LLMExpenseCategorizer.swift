import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 记账消费分类器：交易内容（金额/商户/原文）+ 两级分类池 → 命中的「大类/细分」。
/// 与 LLMTagClassifier 同构，但分类是两级结构。用扁平化 enum 把候选锁成
/// "餐饮/午餐" 这种带分隔符的合法组合，LLM 只能从中挑一个，本地按分隔符拆回两级——
/// 一次调用即锁死合法组合，杜绝"大类餐饮 + 细分打车"的非法搭配。
public struct LLMExpenseCategorizer: Sendable {
    public var config: LLMConfig
    public var transport: any HTTPTransport

    /// 大类与细分的分隔符。用斜杠；分类名里不应含斜杠。
    public static let separator = "/"

    var client: LLMClient { LLMClient(config: config, transport: transport) }

    public init(config: LLMConfig, transport: any HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    /// 两级分类池：大类 → 细分列表。拍平成 ["餐饮/早餐", "餐饮/午餐", ...] 供 enum 约束。
    public static func flatten(_ pool: [String: [String]]) -> [String] {
        pool.sorted { $0.key < $1.key }.flatMap { major, subs in
            subs.isEmpty ? [major] : subs.map { major + separator + $0 }
        }
    }

    static let systemPrompt = """
    你给用户的一笔消费/收入记账打分类。内容含金额、商户、原始短信文本。\
    从候选分类中选出最贴切的一个（格式为"大类/细分"）；只能从候选列表里选，不要发明新分类；\
    都不贴切时输出空字符串。候选分类：{CATS}。
    只输出 JSON，不要任何其他文字，格式：{"category":"大类/细分"}。
    """

    struct Classified: Decodable {
        let category: String
    }

    /// 返回命中的 (大类, 细分)。都不贴切或越界时返回 nil。
    /// 细分可能为 nil（候选池里某大类无细分时，扁平项就是纯大类）。
    public func classify(_ content: String, pool: [String: [String]])
        async throws -> (major: String, sub: String?)? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = Self.flatten(pool)
        guard !trimmed.isEmpty, !candidates.isEmpty else { return nil }

        let system = Self.systemPrompt
            .replacingOccurrences(of: "{CATS}", with: candidates.joined(separator: "、"))
        let jsonText = try await client.send(
            system: system, user: trimmed,
            schema: Self.outputSchema(candidates: candidates), maxTokens: 128)
        let extracted = try JSONDecoder().decode(Classified.self, from: Data(jsonText.utf8))

        // 防模型越界：必须是候选列表里的合法组合
        let picked = extracted.category
        guard candidates.contains(picked) else { return nil }
        let parts = picked.components(separatedBy: Self.separator)
        let major = parts.first ?? picked
        let sub = parts.count > 1 ? parts[1] : nil
        return (major, sub)
    }

    /// Claude structured outputs：用 enum 把 category 锁死在扁平化候选组合内
    static func outputSchema(candidates: [String]) -> [String: Any] { [
        "type": "object",
        "properties": [
            "category": ["type": "string", "enum": candidates] as [String: Any],
        ],
        "required": ["category"],
        "additionalProperties": false,
    ] }
}
