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
    /// 先带结构化输出参数请求（json_schema / json_object）；端点不支持该参数（400）时
    /// 自动降级重试一次纯提示词约束的请求——中转/自建端点对新参数的支持参差不齐。
    public func classify(_ content: String, candidates: [String]) async throws -> [String] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !candidates.isEmpty else { return [] }

        var (data, response) = try await transport.send(
            makeRequest(content: trimmed, candidates: candidates, structured: true))
        if response.statusCode == 400 {
            (data, response) = try await transport.send(
                makeRequest(content: trimmed, candidates: candidates, structured: false))
        }
        guard response.statusCode == 200 else {
            throw LLMParseError.httpError(status: response.statusCode,
                                          body: String(decoding: data, as: UTF8.self))
        }

        let jsonText = try config.apiProtocol.extractContentText(from: data)
        let extracted = try JSONDecoder().decode(
            ClassifiedTags.self, from: Data(Self.stripCodeFences(jsonText).utf8))

        // 防模型越界：过滤掉不在候选列表里的、重复的，截断到 maxTags
        var seen = Set<String>()
        return extracted.tags
            .filter { candidates.contains($0) && seen.insert($0).inserted }
            .prefix(maxTags)
            .map { $0 }
    }

    // MARK: 请求构造（按协议分派）

    /// structured = false 时不带结构化输出参数（json_schema / json_object），
    /// 只靠系统提示词约束输出格式——给不支持这些参数的端点用。
    func makeRequest(content: String, candidates: [String], structured: Bool = true) -> URLRequest {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let system = Self.systemPrompt
            .replacingOccurrences(of: "{MAX}", with: String(maxTags))
            .replacingOccurrences(of: "{TAGS}", with: candidates.joined(separator: "、"))

        var body: [String: Any]
        switch config.apiProtocol {
        case .claude:
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": config.model,
                "max_tokens": 256,
                "system": system,
                "messages": [["role": "user", "content": content]],
            ]
            if structured {
                body["output_config"] = [
                    "format": ["type": "json_schema",
                               "schema": Self.claudeOutputSchema(candidates: candidates,
                                                                 maxTags: maxTags)],
                ]
            }
        case .openai:
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": config.model,
                "max_tokens": 256,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": content],
                ],
            ]
            if structured {
                body["response_format"] = ["type": "json_object"]
            }
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 不带结构化输出约束时，模型可能把 JSON 包在 markdown 代码围栏里
    static func stripCodeFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            result = result
                .replacing(/^```[a-zA-Z]*\s*/, with: "")
                .replacing(/```\s*$/, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
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
