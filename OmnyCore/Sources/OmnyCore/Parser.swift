import Foundation

/// 解析器抽象：规则引擎和 LLM 解析器都实现它。
/// 返回 nil 表示"该解析器无法处理这段文本"。
public protocol Parser: Sendable {
    func parse(_ text: String) async throws -> ParseResult?
}

/// 规则优先、LLM 兜底的解析管线。
/// 规则解析置信度达标直接采用；否则（含规则完全没命中）交给 fallback。
/// fallback 未配置或也失败时返回规则结果（可能为 nil）。
public struct ParserPipeline: Parser {
    public var primary: any Parser
    public var fallback: (any Parser)?
    public var confidenceThreshold: Double

    public init(primary: any Parser, fallback: (any Parser)? = nil,
                confidenceThreshold: Double = 0.8) {
        self.primary = primary
        self.fallback = fallback
        self.confidenceThreshold = confidenceThreshold
    }

    public func parse(_ text: String) async throws -> ParseResult? {
        let primaryResult = try await primary.parse(text)
        if let primaryResult, primaryResult.confidence >= confidenceThreshold {
            return primaryResult
        }
        guard let fallback else { return primaryResult }
        do {
            if let fallbackResult = try await fallback.parse(text) {
                return fallbackResult
            }
        } catch {
            // LLM 不可用（断网、Key 未配置）时降级用规则结果，不让入口链路整体失败
            if let primaryResult { return primaryResult }
            throw error
        }
        return primaryResult
    }
}
