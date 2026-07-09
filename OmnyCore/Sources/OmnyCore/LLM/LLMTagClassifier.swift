import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// LLM tag 分类器：收藏内容（链接标题/描述或纯文本）+ 候选 tag → 命中的 tag。
/// 候选 tag 来自设置页的用户 tag 列表，模型只允许从中挑选，不发明新标签。
/// 与 LLMTodoParser 共用 LLMConfig / HTTPTransport，Claude 与 OpenAI 兼容协议均支持。
public struct LLMTagClassifier: Sendable {
    public var config: LLMConfig
    public var transport: any HTTPTransport
    /// 最多打几个标签，收藏场景 1~3 个足够
    public var maxTags: Int

    /// 请求构造/发送/响应解析的公共底座
    var client: LLMClient { LLMClient(config: config, transport: transport) }

    public init(config: LLMConfig, transport: any HTTPTransport = URLSessionTransport(),
                maxTags: Int = 3) {
        self.config = config
        self.transport = transport
        self.maxTags = maxTags
    }

    static let systemPrompt = """
    你给用户收藏的内容打标签。内容可能是一条链接（带标题或描述）或一段文本。\
    从候选标签中选出最贴切的，最多 {MAX} 个；只能从候选列表里选，不要发明新标签；\
    都不贴切时输出空数组。候选标签：{TAGS}。
    只输出 JSON，不要任何其他文字，格式：{"tags":["标签1","标签2"]}。
    """

    struct ClassifiedTags: Decodable {
        let tags: [String]
    }

    /// 返回命中的候选 tag（已按候选列表过滤、去重）。都不贴切时返回空数组。
    /// 结构化输出参数不被端点支持时的降级重试由 LLMClient 统一处理。
    public func classify(_ content: String, candidates: [String]) async throws -> [String] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !candidates.isEmpty else { return [] }

        let system = Self.systemPrompt
            .replacingOccurrences(of: "{MAX}", with: String(maxTags))
            .replacingOccurrences(of: "{TAGS}", with: candidates.joined(separator: "、"))
        let jsonText = try await client.send(
            system: system, user: trimmed,
            schema: Self.claudeOutputSchema(candidates: candidates, maxTags: maxTags),
            maxTokens: 256)
        let extracted = try JSONDecoder().decode(ClassifiedTags.self, from: Data(jsonText.utf8))

        // 防模型越界：过滤掉不在候选列表里的、重复的，截断到 maxTags
        var seen = Set<String>()
        return extracted.tags
            .filter { candidates.contains($0) && seen.insert($0).inserted }
            .prefix(maxTags)
            .map { $0 }
    }

    /// Claude structured outputs：用 enum 把可选值锁死在候选 tag 列表内
    static func claudeOutputSchema(candidates: [String], maxTags: Int) -> [String: Any] { [
        "type": "object",
        "properties": [
            "tags": [
                "type": "array",
                "maxItems": maxTags,
                "items": ["type": "string", "enum": candidates],
            ] as [String: Any],
        ],
        "required": ["tags"],
        "additionalProperties": false,
    ] }
}
