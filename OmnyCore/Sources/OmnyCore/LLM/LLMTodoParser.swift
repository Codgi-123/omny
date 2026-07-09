import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// LLM 接口协议：设置页可切换。
public enum LLMProtocol: String, Codable, Sendable, CaseIterable {
    /// Anthropic Messages API（x-api-key 头，structured outputs）
    case claude
    /// OpenAI Chat Completions 及其兼容端点（Bearer 头，json_object 模式）
    case openai
}

/// LLM 运行时配置：全部来自设置页（存 Keychain/UserDefaults），代码不写死。
public struct LLMConfig: Codable, Equatable, Sendable {
    public var apiProtocol: LLMProtocol
    /// 填服务域名即可（不带 /v1），如 https://api.anthropic.com、https://api.openai.com
    /// 或任何自建/中转地址；路径由协议决定（claude → /v1/messages，openai → /v1/chat/completions）
    public var baseURL: URL
    public var apiKey: String
    public var model: String

    public init(apiProtocol: LLMProtocol, baseURL: URL, apiKey: String, model: String) {
        self.apiProtocol = apiProtocol
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    public static func claude(apiKey: String, model: String = "claude-opus-4-8") -> LLMConfig {
        LLMConfig(apiProtocol: .claude, baseURL: URL(string: "https://api.anthropic.com")!,
                  apiKey: apiKey, model: model)
    }

    public static func openAICompatible(baseURL: URL, apiKey: String, model: String) -> LLMConfig {
        LLMConfig(apiProtocol: .openai, baseURL: baseURL, apiKey: apiKey, model: model)
    }

    var endpoint: URL {
        switch apiProtocol {
        case .claude: baseURL.appendingPathComponent("v1/messages")
        case .openai: baseURL.appendingPathComponent("v1/chat/completions")
        }
    }
}

public enum LLMParseError: Error, Equatable {
    case httpError(status: Int, body: String)
    case malformedResponse
}

/// LLM 待办提取器：截图 OCR 出的自由文本 → 结构化待办列表。
/// 实现 Parser 协议，在 ParserPipeline 里作为规则引擎的 fallback。
public struct LLMTodoParser: Parser {
    public var config: LLMConfig
    public var transport: any HTTPTransport

    public init(config: LLMConfig, transport: any HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    /// 两种协议共用。明确描述输出 JSON 形状：
    /// Claude 侧有 structured outputs 兜底，OpenAI 兼容端点靠它 + json_object 模式约束。
    static let systemPrompt = """
    你从 OCR 识别出的中文文本里提取待办事项。文本可能来自聊天记录、会议纪要、备忘的截图，\
    包含 OCR 噪声和无关内容。只提取明确要做的事情，一条一个；日期表述（明天、周五、7月10日）\
    换算成 ISO 8601 日期时间，无法确定则为 null。今天是 {TODAY}。
    只输出 JSON，不要任何其他文字，格式：\
    {"todos":[{"title":"待办内容，动词开头","due":"2026-07-10T15:00:00+08:00 或 null"}]}\
    没有待办时输出 {"todos":[]}。
    """

    struct ExtractedTodos: Decodable {
        struct Item: Decodable {
            let title: String
            let due: String?
        }
        let todos: [Item]
    }

    public func parse(_ text: String) async throws -> ParseResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let (data, response) = try await transport.send(makeRequest(text: trimmed, now: Date()))
        guard response.statusCode == 200 else {
            throw LLMParseError.httpError(status: response.statusCode,
                                          body: String(decoding: data, as: UTF8.self))
        }

        let jsonText = try extractContentText(from: data)
        let extracted = try JSONDecoder().decode(ExtractedTodos.self, from: Data(jsonText.utf8))
        guard !extracted.todos.isEmpty else { return nil }

        let todos = extracted.todos.map { item in
            TodoInfo(title: item.title, due: item.due.flatMap(Self.dateComponents(fromISO:)))
        }
        return ParseResult(payload: .todos(todos), confidence: 0.85, rawText: trimmed)
    }

    // MARK: 请求构造（按协议分派）

    func makeRequest(text: String, now: Date) -> URLRequest {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let system = Self.systemPrompt.replacingOccurrences(
            of: "{TODAY}", with: ISO8601DateFormatter().string(from: now))

        let body: [String: Any]
        switch config.apiProtocol {
        case .claude:
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": config.model,
                "max_tokens": 2048,
                "system": system,
                "messages": [["role": "user", "content": text]],
                "output_config": [
                    "format": ["type": "json_schema", "schema": Self.claudeOutputSchema],
                ],
            ]
        case .openai:
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": config.model,
                "max_tokens": 2048,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": text],
                ],
                // json_object 比 json_schema 兼容面广，各家中转/自建端点基本都支持
                "response_format": ["type": "json_object"],
            ]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Claude structured outputs 的 JSON Schema（响应保证合法且符合结构）
    static var claudeOutputSchema: [String: Any] { [
        "type": "object",
        "properties": [
            "todos": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "due": ["type": ["string", "null"]],
                    ],
                    "required": ["title", "due"],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
        ],
        "required": ["todos"],
        "additionalProperties": false,
    ] }

    // MARK: 响应解析

    func extractContentText(from data: Data) throws -> String {
        try config.apiProtocol.extractContentText(from: data)
    }

    static func dateComponents(fromISO string: String) -> DateComponents? {
        guard let date = ISO8601DateFormatter().date(from: string) else { return nil }
        return Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }
}
