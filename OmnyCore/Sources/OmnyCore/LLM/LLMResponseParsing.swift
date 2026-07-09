import Foundation

extension LLMProtocol {
    /// 从响应 envelope 里取出模型输出的文本（两种协议的响应结构不同），
    /// LLMTodoParser / LLMTagClassifier 共用。
    func extractContentText(from data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMParseError.malformedResponse
        }
        switch self {
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
}
