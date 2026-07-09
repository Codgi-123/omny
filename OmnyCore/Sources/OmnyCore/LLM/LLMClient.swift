import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// LLM 调用的公共底座：封装 config + transport，统一负责
/// 请求构造（按协议分派）、发送、状态码校验、响应正文抽取。
/// `LLMTodoParser`（抽待办）与 `LLMStructuredParser`（抽快递/行程）共用它，
/// 各自只提供自己的 system/user 提示词与 Claude 侧的 JSON Schema。
struct LLMClient {
    var config: LLMConfig
    var transport: any HTTPTransport

    init(config: LLMConfig, transport: any HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    /// 发一次请求并返回模型输出的正文文本（两种协议都归一成一个 JSON 字符串）。
    /// - Parameters:
    ///   - system: 系统提示词
    ///   - user: 用户输入文本
    ///   - schema: Claude structured outputs 的 JSON Schema；OpenAI 兼容端点忽略它、走 json_object 模式
    func send(system: String, user: String,
              schema: [String: Any]) async throws -> String {
        let request = makeRequest(system: system, user: user, schema: schema)
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw LLMParseError.httpError(status: response.statusCode,
                                          body: String(decoding: data, as: UTF8.self))
        }
        return try extractContentText(from: data)
    }

    // MARK: 请求构造（按协议分派）

    func makeRequest(system: String, user: String, schema: [String: Any]) -> URLRequest {
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any]
        switch config.apiProtocol {
        case .claude:
            request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": config.model,
                "max_tokens": 2048,
                "system": system,
                "messages": [["role": "user", "content": user]],
                "output_config": [
                    "format": ["type": "json_schema", "schema": schema],
                ],
            ]
        case .openai:
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            body = [
                "model": config.model,
                "max_tokens": 2048,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
                // json_object 比 json_schema 兼容面广，各家中转/自建端点基本都支持
                "response_format": ["type": "json_object"],
            ]
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    // MARK: 响应解析（按协议分派）

    func extractContentText(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMParseError.malformedResponse
        }
        switch config.apiProtocol {
        case .claude:
            guard let content = json["content"] as? [[String: Any]],
                  let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
            else { throw LLMParseError.malformedResponse }
            return text
        case .openai:
            guard let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let text = message["content"] as? String
            else { throw LLMParseError.malformedResponse }
            return text
        }
    }

    /// ISO 8601（及其常见变体）字符串 → DateComponents（年月日时分）。
    /// 短信/OCR 场景的日期归一入口，必须宽容：LLM 输出的时间形态多变——
    /// 可能带时区也可能不带（`...+08:00` / `...T08:30:00`）、可能缺年份
    /// （提示词允许 `07-10T08:30:00`，短信本就常不写年）。标准 `ISO8601DateFormatter`
    /// 对缺时区或缺年份一律返回 nil，会丢时间，故改为直接正则抽取各部件：
    /// 缺哪个部件就置 nil，天然契合 `DateComponents` 的可选语义与下游补年逻辑（`Ingestor.resolveDate`）。
    static func dateComponents(fromISO string: String) -> DateComponents? {
        let s = string.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        var c = DateComponents()
        // 年份可缺：(YYYY-)?MM-DD，日期段必须有
        guard let dateMatch = s.firstMatch(of: /(?:(\d{4})-)?(\d{1,2})-(\d{1,2})/) else { return nil }
        if let y = dateMatch.output.1 { c.year = Int(y) }
        c.month = Int(dateMatch.output.2)
        c.day = Int(dateMatch.output.3)

        // 时分可缺（如仅给日期）：T?HH:MM
        if let timeMatch = s.firstMatch(of: /[T\s](\d{1,2}):(\d{2})/) {
            c.hour = Int(timeMatch.output.1)
            c.minute = Int(timeMatch.output.2)
        }
        return c
    }
}
