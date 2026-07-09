import Foundation
import OmnyCore

/// 运行时配置。v1 用 UserDefaults 存（含密钥，自用可接受；后续可迁 Keychain）。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    // MARK: 滴答应用身份（应用级常量，值在 Secrets.swift，不入库）

    static let didaClientID = Secrets.didaClientID
    static let didaClientSecret = Secrets.didaClientSecret
    static let didaRedirectURI = Secrets.didaRedirectURI

    // MARK: LLM 配置（协议 / Base URL / Key / 模型全部可改）

    @Published var llmProtocol: LLMProtocol {
        didSet { defaults.set(llmProtocol.rawValue, forKey: "llm.protocol") }
    }
    @Published var llmBaseURL: String {
        didSet { defaults.set(llmBaseURL, forKey: "llm.baseURL") }
    }
    @Published var llmAPIKey: String {
        didSet { defaults.set(llmAPIKey, forKey: "llm.apiKey") }
    }
    @Published var llmModel: String {
        didSet { defaults.set(llmModel, forKey: "llm.model") }
    }

    var llmConfig: LLMConfig? {
        guard !llmAPIKey.isEmpty, let url = URL(string: llmBaseURL) else { return nil }
        return LLMConfig(apiProtocol: llmProtocol, baseURL: url, apiKey: llmAPIKey, model: llmModel)
    }

    /// 解析管线：配了 LLM 就"分类靠正则、结构化靠 LLM"（快递/行程走 LLM 抽字段），
    /// 兜底仍用 LLMTodoParser 抽自由文本里的待办；没配 LLM 则纯规则降级。
    var parserPipeline: ParserPipeline {
        guard let llmConfig else {
            return ParserPipeline(primary: RuleParser())
        }
        return ParserPipeline(primary: LLMStructuredParser(config: llmConfig),
                              fallback: LLMTodoParser(config: llmConfig))
    }

    // MARK: 滴答清单绑定状态

    @Published var didaAccessToken: String? {
        didSet { defaults.set(didaAccessToken, forKey: "dida.accessToken") }
    }
    @Published var didaProjectID: String? {
        didSet { defaults.set(didaProjectID, forKey: "dida.projectID") }
    }
    @Published var didaProjectName: String? {
        didSet { defaults.set(didaProjectName, forKey: "dida.projectName") }
    }
    @Published var didaLastSync: Date? {
        didSet { defaults.set(didaLastSync, forKey: "dida.lastSync") }
    }

    var didaBound: Bool { didaAccessToken != nil && didaProjectID != nil }

    // MARK: 行程日历

    @Published var autoAddToCalendar: Bool {
        didSet { defaults.set(autoAddToCalendar, forKey: "trip.autoCalendar") }
    }

    private init() {
        llmProtocol = LLMProtocol(rawValue: defaults.string(forKey: "llm.protocol") ?? "") ?? .claude
        llmBaseURL = defaults.string(forKey: "llm.baseURL") ?? "https://api.anthropic.com"
        llmAPIKey = defaults.string(forKey: "llm.apiKey") ?? ""
        llmModel = defaults.string(forKey: "llm.model") ?? "claude-opus-4-8"
        didaAccessToken = defaults.string(forKey: "dida.accessToken")
        didaProjectID = defaults.string(forKey: "dida.projectID")
        didaProjectName = defaults.string(forKey: "dida.projectName")
        didaLastSync = defaults.object(forKey: "dida.lastSync") as? Date
        autoAddToCalendar = defaults.object(forKey: "trip.autoCalendar") as? Bool ?? true
    }
}
